#!/usr/bin/env bash
# watchdog.sh — Entrada do 'canpass':
#   1. entrevista de configuração (modo de gravação de vídeo, CAN, armazenamento);
#   2. inicia o log CAN contínuo (canpass-can log) em segundo plano — roda
#      enquanto o canpass estiver vivo, independente de reinícios do cam_view;
#   3. supervisiona o cam_view.sh e o reinicia em caso de falha inesperada.
# Encerramento explícito pelo usuário (Ctrl+C / SIGTERM) não dispara reinício.
#
# Sem resposta em CANPASS_PROMPT_TIMEOUT s (padrão 30) por pergunta, a entrevista
# segue com os PADRÕES — assim o serviço systemd no boot não fica preso esperando
# alguém no tty1. CANPASS_NO_INTERVIEW=1 pula a entrevista (usa env/padrões).

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }

CAM_VIEW="/usr/bin/cam_view.sh"
RESTART_DELAY_SECS=3
PROMPT_TIMEOUT="${CANPASS_PROMPT_TIMEOUT:-30}"
CAN_CONSOLE_LOG="/tmp/canpass_can_console.log"
CAN_LOG_PID=""

# Códigos que indicam encerramento intencional pelo usuário
INTENTIONAL_EXIT_CODES=(0 130 143)

is_intentional_exit() {
    local exit_code="$1"
    for code in "${INTENTIONAL_EXIT_CODES[@]}"; do
        [[ $exit_code -eq $code ]] && return 0
    done
    return 1
}

# ─── Entrevista de configuração ──────────────────────────────────────────────

_interview_timed_out=0

# Pergunta com timeout: $1 = prompt · $2 = resposta padrão (Enter/timeout/sem tty).
# Após o primeiro timeout, as perguntas seguintes assumem o padrão direto —
# ninguém está no terminal, não adianta esperar de novo a cada pergunta.
_ask() {
    local prompt="$1" def="$2" ans
    if (( _interview_timed_out )) || [[ ! -t 0 ]]; then echo "$def"; return; fi
    if ! read -t "$PROMPT_TIMEOUT" -rp "$(echo -e "${CYAN}${prompt}${NC} ")" ans; then
        echo >&2
        log_warn "Sem resposta em ${PROMPT_TIMEOUT}s — seguindo com os padrões." >&2
        _interview_timed_out=1
        echo "$def"; return
    fi
    echo "${ans:-$def}"
}

# Lista partições montadas de dispositivos EXTERNOS (HDD/SSD/pendrive USB, SD,
# NVMe extra…), uma por linha: "mountpoint<TAB>size<TAB>tran<TAB>model".
# Fora da lista: raiz, /boot*, swap e a eMMC interna do Orin (mmcblk0).
_list_external_mounts() {
    command -v lsblk &>/dev/null || return 0
    local line NAME TYPE SIZE MOUNTPOINT MODEL PKNAME TRAN tran model
    while IFS= read -r line; do
        NAME="" TYPE="" SIZE="" MOUNTPOINT="" MODEL="" PKNAME="" TRAN=""
        eval "$line"
        [[ "$TYPE" == "part" || "$TYPE" == "disk" ]] || continue
        [[ -n "$MOUNTPOINT" ]] || continue
        case "$MOUNTPOINT" in /|/boot*|\[SWAP\]) continue ;; esac
        [[ "$NAME" == *mmcblk0* ]] && continue
        tran="$TRAN"; model="$MODEL"
        if [[ -n "$PKNAME" ]]; then
            [[ -z "$tran" ]]  && tran=$(lsblk -dno TRAN "$PKNAME" 2>/dev/null)
            [[ -z "$model" ]] && model=$(lsblk -dno MODEL "$PKNAME" 2>/dev/null)
        fi
        model="${model%"${model##*[![:space:]]}"}"   # tira espaços à direita
        printf '%s\t%s\t%s\t%s\n' "$MOUNTPOINT" "$SIZE" "$tran" "$model"
    done < <(lsblk -P -p -o NAME,PKNAME,TYPE,SIZE,MOUNTPOINT,TRAN,MODEL 2>/dev/null)
}

# Mostra interno + externos detectados, deixa escolher e valida escrita.
# Exporta CANPASS_REC_DIR — vídeo E log CAN vão para lá (canpass-can usa
# CANPASS_REC_DIR como fallback de CANPASS_CAN_LOGDIR).
_choose_storage() {
    local internal="${CANPASS_REC_DIR:-${HOME}/canpass_rec}"
    local -a opts_dir=("$internal")
    local -a opts_label=("Interno  — ${internal}")
    local mp size tran model extra
    while IFS=$'\t' read -r mp size tran model; do
        [[ -n "$mp" ]] || continue
        extra="${size}${tran:+ · $tran}${model:+ · $model}"
        opts_dir+=("${mp%/}/canpass_rec")
        opts_label+=("Externo  — ${mp}  (${extra})")
    done < <(_list_external_mounts)

    log_info "Armazenamento (gravações de vídeo + logs CAN):"
    local i
    for i in "${!opts_dir[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} ${opts_label[$i]}"
    done
    (( ${#opts_dir[@]} == 1 )) && log_info "(nenhum dispositivo externo montado foi detectado)"

    local n=$(( ${#opts_dir[@]} - 1 ))
    local choice
    while true; do
        choice=$(_ask "Onde salvar? [0-${n}] (padrão 0):" "0")
        [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "$n" ]] && break
        log_warn "Opção inválida."
        (( _interview_timed_out )) && { choice=0; break; }
    done

    local dir="${opts_dir[$choice]}"
    if ! mkdir -p "$dir" 2>/dev/null || ! touch "${dir}/.canpass_wtest" 2>/dev/null; then
        log_warn "Sem permissão de escrita em ${dir} — usando interno: ${internal}"
        dir="$internal"
        mkdir -p "$dir"
    else
        rm -f "${dir}/.canpass_wtest"
    fi
    export CANPASS_REC_DIR="$dir"
    log_ok "Gravações e logs CAN serão salvos em: ${dir}"
}

_setup_interview() {
    [[ "${CANPASS_NO_INTERVIEW:-0}" == "1" ]] && return 0

    echo -e "${BOLD}${CYAN}"
    echo    "╔══════════════════════════════════════╗"
    echo    "║       CANPass — Configuração         ║"
    echo    "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    # 1. Modo de gravação de vídeo
    log_info "Gravação de vídeo:"
    echo -e "  ${GREEN}[1]${NC} Contínua      — grava SEMPRE; recomprime em H.264 (x264 CRF ${CANPASS_CONT_CRF:-21}):"
    echo    "                       arquivos bem menores com perda visual mínima"
    echo -e "  ${GREEN}[2]${NC} Por movimento — grava só quando há movimento; cópia EXATA do stream,"
    echo    "                       sem reencode (máxima qualidade possível)"
    local ans
    ans=$(_ask "Modo [1/2] (padrão 1):" "1")
    [[ "$ans" == "2" ]] && export CANPASS_REC_MODE="motion" || export CANPASS_REC_MODE="continuous"

    # 2. Bitrate do CAN
    echo
    ans=$(_ask "Bitrate do CAN em bps [padrão 250000 — J1939/Caterpillar]:" "250000")
    if [[ ! "$ans" =~ ^[0-9]+$ ]]; then
        log_warn "Bitrate inválido ('${ans}') — usando 250000."
        ans=250000
    fi
    export CANPASS_CAN_BITRATE="$ans"

    # 3. Formato do timestamp do log CAN
    echo
    log_info "Timestamp do log CAN:"
    echo -e "  ${GREEN}[1]${NC} Epoch  — original do candump; replayável com canplayer e casa com o vídeo"
    echo -e "  ${GREEN}[2]${NC} Humano — data+hora legível (NÃO replayável)"
    ans=$(_ask "Formato [1/2] (padrão 1):" "1")
    [[ "$ans" == "2" ]] && export CANPASS_CAN_LOG_HUMAN=1 || export CANPASS_CAN_LOG_HUMAN=0

    # 4. Conteúdo do log CAN
    echo
    log_info "Conteúdo do log CAN:"
    echo -e "  ${GREEN}[1]${NC} Normal      — leitura padrão do candump (ID + dados em hex)"
    echo -e "  ${GREEN}[2]${NC} Hex + ASCII — adiciona coluna de texto ('.'=não-imprimível);"
    echo    "                   com timestamp epoch o log deixa de ser replayável"
    ans=$(_ask "Conteúdo [1/2] (padrão 1):" "1")
    [[ "$ans" == "2" ]] && export CANPASS_CAN_LOG_ASCII=1 || export CANPASS_CAN_LOG_ASCII=0

    # 5. Armazenamento (interno + dispositivos externos montados)
    echo
    _choose_storage

    echo
    log_ok "Configuração: vídeo=$([[ "$CANPASS_REC_MODE" == continuous ]] && echo "contínua" || echo "movimento") · CAN ${CANPASS_CAN_BITRATE} bps · ts=$([[ "$CANPASS_CAN_LOG_HUMAN" == 1 ]] && echo "humano" || echo "epoch")$([[ "$CANPASS_CAN_LOG_ASCII" == 1 ]] && echo " +ascii") · destino: ${CANPASS_REC_DIR}"
    echo
}

# ─── Log CAN contínuo em segundo plano ───────────────────────────────────────
# canpass-can log já é SUPERVISIONADO por dentro (re-detecta o CANable, recicla
# a interface se o RX travar), então aqui basta um start/stop amarrado à vida
# do watchdog. Console do processo vai para CAN_CONSOLE_LOG (os frames vão para
# o arquivo can_*.log no destino escolhido).

_start_can_logger() {
    local bin
    bin=$(command -v canpass-can || true)
    if [[ -z "$bin" ]]; then
        # ambiente de desenvolvimento: script ao lado do watchdog
        local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        [[ -x "${here}/canpass-can.sh" ]] && bin="${here}/canpass-can.sh"
    fi
    if [[ -z "$bin" ]]; then
        log_warn "canpass-can não encontrado — log CAN desativado (rode o install.sh)."
        return 0
    fi

    # Subir a interface usa sudo; valida a credencial AGORA para o processo em
    # background não morrer pedindo senha (o install.sh cria regra NOPASSWD p/ ip).
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        if [[ -t 0 ]]; then
            log_info "O log CAN precisa de sudo para subir a interface — informe a senha se pedida."
            sudo -v || log_warn "Sem sudo — o log CAN pode falhar ao subir a interface."
        else
            log_warn "Sem sudo NOPASSWD — o log CAN pode falhar ao subir a interface."
        fi
    fi

    : > "$CAN_CONSOLE_LOG"
    "$bin" log "${CANPASS_CAN_BITRATE:-250000}" >>"$CAN_CONSOLE_LOG" 2>&1 &
    CAN_LOG_PID=$!
    log_ok "Log CAN contínuo iniciado (PID ${CAN_LOG_PID}) — can_*.log em ${CANPASS_CAN_LOGDIR:-${CANPASS_REC_DIR:-$HOME/canpass_rec}}"
    log_info "Console do log CAN: tail -f ${CAN_CONSOLE_LOG}"
}

_stop_can_logger() {
    [[ -n "$CAN_LOG_PID" ]] || return 0
    kill "$CAN_LOG_PID" 2>/dev/null
    wait "$CAN_LOG_PID" 2>/dev/null
    log_info "Log CAN encerrado."
    CAN_LOG_PID=""
}

# ─── Limpeza do diretório de instalação temporário ───────────────────────────

_cleanup_install_dir() {
    local src_file="/tmp/.canpass_src_dir"
    [[ -f "$src_file" ]] || return
    local src_dir
    src_dir=$(cat "$src_file")
    rm -f "$src_file"
    [[ -d "$src_dir" ]] || return
    rm -rf "$src_dir"
    log_info "Repositório de instalação removido: ${src_dir}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

trap '_stop_can_logger' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_cleanup_install_dir

# --local = preview manual de diagnóstico: sem entrevista e sem log CAN
_preview=0
for _a in "$@"; do [[ "$_a" == "--local" ]] && _preview=1; done

if (( ! _preview )); then
    _setup_interview
    _start_can_logger
fi

log_info "Watchdog iniciado — supervisionando ${CAM_VIEW}"

while true; do
    "$CAM_VIEW" "$@"
    exit_code=$?

    if is_intentional_exit "$exit_code"; then
        log_info "Encerramento intencional (código ${exit_code}) — watchdog finalizado."
        exit 0
    fi

    log_warn "cam_view.sh encerrou inesperadamente (código ${exit_code}) — reiniciando em ${RESTART_DELAY_SECS}s..."
    sleep "$RESTART_DELAY_SECS"
done
