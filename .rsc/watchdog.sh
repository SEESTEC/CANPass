#!/usr/bin/env bash
# watchdog.sh — Entrada do 'canpass':
#   0. imprime a referência completa de comandos/parâmetros (CANPASS_NO_HELP=1
#      oculta; 'canpass --help' imprime só ela e sai);
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

CAM_VIEW="/usr/bin/cam_view.sh"
RESTART_DELAY_SECS=3
PROMPT_TIMEOUT="${CANPASS_PROMPT_TIMEOUT:-30}"
CAN_CONSOLE_LOG="/tmp/canpass_can_console.log"
CAN_LOG_PID=""
CANTIME_PID=""   # monitor de offset 'Orin↔hora real' (PGN 65254) — não mexe no relógio
CAN_BIN=""   # caminho resolvido do canpass-can (p/ derrubar a iface no encerramento)

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
_interview_did_storage=0   # 1 = a entrevista interativa já escolheu o destino

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

# Probe de escrita NÃO-BLOQUEANTE. Um disco USB em falha (UAS reset / I/O error)
# deixa mkdir/touch presos em D-state — e isso TRAVAVA o watchdog inteiro no boot
# (visto em campo 2026-06-24: 'mkdir -p' no HD morto pendurado por minutos, NADA
# gravava, nem vídeo nem CAN). Roda o teste em subshell e o ABANDONA após
# CANPASS_FS_PROBE_SECS s → trata o disco como indisponível e cai no interno.
# Não usa 'timeout' direto porque ele também espera o filho em D-state; matar o
# subshell (interrompível) destrava o watchdog e segue (o mkdir órfão some quando
# o device finalmente dá erro de I/O).
_probe_writable() {
    local dir="$1" t="${CANPASS_FS_PROBE_SECS:-6}" p w=0
    ( mkdir -p "$dir" && : > "${dir}/.canpass_wtest" && rm -f "${dir}/.canpass_wtest" ) & p=$!
    while kill -0 "$p" 2>/dev/null; do
        sleep 1; w=$((w+1))
        (( w >= t )) && { kill -9 "$p" 2>/dev/null; return 1; }
    done
    wait "$p" 2>/dev/null
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
    # Padrão de CAMPO: o PRIMEIRO disco externo (índice 1), se houver — a eMMC do
    # Orin é pequena e viaja com a máquina. Sem externo, cai no interno (0). Vale
    # tanto p/ Enter quanto p/ timeout (boot desatendido).
    local default_choice=0
    (( n >= 1 )) && default_choice=1
    local default_label; default_label=$([[ "$default_choice" == 0 ]] && echo "interno" || echo "1º externo")
    local choice
    while true; do
        choice=$(_ask "Onde salvar? [0-${n}] (padrão ${default_choice} = ${default_label}):" "$default_choice")
        [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "$n" ]] && break
        log_warn "Opção inválida."
        (( _interview_timed_out )) && { choice=$default_choice; break; }
    done

    local dir="${opts_dir[$choice]}"
    if ! _probe_writable "$dir"; then
        log_warn "${dir} não respondeu/sem escrita (disco morto ou removido?) — usando interno: ${internal}"
        dir="$internal"
        mkdir -p "$dir"
    fi
    export CANPASS_REC_DIR="$dir"
    # Fallback p/ o cam_view: se um disco externo escolhido sumir durante a
    # gravação, ele migra p/ o interno sem parar (ver _rec_dir_now no cam_view).
    export CANPASS_REC_DIR_FALLBACK="$internal"
    log_ok "Gravações e logs CAN serão salvos em: ${dir}"
}

# Destino de gravação SEM entrevista (boot desatendido / CANPASS_NO_INTERVIEW=1).
# Escolhe o PRIMEIRO disco externo gravável; senão, o interno. Sempre define o
# fallback interno. Respeita um CANPASS_REC_DIR já exportado no ambiente.
_auto_storage() {
    local internal="${HOME}/canpass_rec"
    export CANPASS_REC_DIR_FALLBACK="$internal"

    if [[ -n "${CANPASS_REC_DIR:-}" ]]; then
        log_ok "Destino de gravação (definido no ambiente): ${CANPASS_REC_DIR}"
        return 0
    fi

    if [[ "${CANPASS_REC_EXTERNAL:-1}" == "1" ]]; then
        local mp _s _t _m cand first=""
        while IFS=$'\t' read -r mp _s _t _m; do
            [[ -n "$mp" ]] || continue
            cand="${mp%/}/canpass_rec"
            if _probe_writable "$cand"; then first="$cand"; break; fi
            log_warn "Disco externo ${mp} não respondeu à escrita em ${CANPASS_FS_PROBE_SECS:-6}s (UAS/I-O?) — ignorando."
        done < <(_list_external_mounts)
        if [[ -n "$first" ]]; then
            export CANPASS_REC_DIR="$first"
            log_ok "Destino de gravação: disco externo → ${first}"
            return 0
        fi
        log_warn "Nenhum disco externo gravável detectado — usando interno: ${internal}"
    fi
    export CANPASS_REC_DIR="$internal"
    mkdir -p "$internal" 2>/dev/null
}

# Define o destino de gravação valendo p/ AMBOS os caminhos. Se a entrevista
# interativa já escolheu (menu), não repergunta; caso contrário (boot
# desatendido / CANPASS_NO_INTERVIEW=1), resolve automático (1º disco externo).
_setup_storage() {
    (( _interview_did_storage )) && return 0
    _auto_storage
}

# Cria uma pasta de SESSÃO (canpass_dd-mm-aaaa_hh-mm-ss) dentro do destino escolhido
# e aponta CANPASS_REC_DIR p/ ela — vídeo + log CAN desta execução ficam juntos e
# separados das sessões anteriores (antes tudo caía solto em canpass_rec). Vale
# tanto p/ a entrevista quanto p/ o modo não-interativo (systemd). Exportado, é
# herdado pelo cam_view.sh e pelo canpass-can.
_setup_session_dir() {
    local base session stamp
    stamp="canpass_$(date +%d-%m-%Y_%H-%M-%S)"
    base="${CANPASS_REC_DIR:-${HOME}/canpass_rec}"
    session="${base%/}/${stamp}"
    if _probe_writable "$session"; then
        export CANPASS_REC_DIR="$session"
        log_ok "Sessão: arquivos desta execução em ${session}"
    elif [[ -n "${CANPASS_REC_DIR_FALLBACK:-}" ]]; then
        # base externa não respondeu — cai na sessão interna (não trava o boot).
        local fbs="${CANPASS_REC_DIR_FALLBACK%/}/${stamp}"
        mkdir -p "$fbs" 2>/dev/null
        export CANPASS_REC_DIR="$fbs"
        log_warn "Destino ${base} não respondeu — sessão no interno: ${fbs}"
    else
        log_warn "Não consegui criar a pasta de sessão em ${base} — salvando direto em ${base}."
        export CANPASS_REC_DIR="$base"
    fi
    # Mesma sessão (mesmo carimbo) no destino de fallback interno, p/ os arquivos
    # ficarem juntos caso o cam_view migre p/ o interno (disco externo removido).
    if [[ -n "${CANPASS_REC_DIR_FALLBACK:-}" ]]; then
        local fb="${CANPASS_REC_DIR_FALLBACK%/}/${stamp}"
        mkdir -p "$fb" 2>/dev/null && export CANPASS_REC_DIR_FALLBACK="$fb"
    fi
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

    # 1b. Posição do timestamp queimado na gravação (relógio do Orin HH:MM:SS.mmm)
    echo
    log_info "Timestamp na gravação (relógio HH:MM:SS.mmm queimado no vídeo):"
    echo -e "  ${GREEN}[1]${NC} Inferior esquerdo (padrão)"
    echo -e "  ${GREEN}[2]${NC} Inferior direito"
    echo -e "  ${GREEN}[3]${NC} Superior esquerdo"
    echo -e "  ${GREEN}[4]${NC} Superior direito"
    echo -e "  ${GREEN}[5]${NC} Sem timestamp"
    ans=$(_ask "Posição [1-5] (padrão 1):" "1")
    case "$ans" in
        2) export CANPASS_TS_POSITION="br" ;;
        3) export CANPASS_TS_POSITION="tl" ;;
        4) export CANPASS_TS_POSITION="tr" ;;
        5) export CANPASS_TS_POSITION="off" ;;
        *) export CANPASS_TS_POSITION="bl" ;;
    esac

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
    _interview_did_storage=1

    local ts_label
    case "$CANPASS_TS_POSITION" in
        br) ts_label="inf-dir" ;; tl) ts_label="sup-esq" ;;
        tr) ts_label="sup-dir" ;; off) ts_label="desligado" ;;
        *)  ts_label="inf-esq" ;;
    esac
    echo
    log_ok "Configuração: vídeo=$([[ "$CANPASS_REC_MODE" == continuous ]] && echo "contínua" || echo "movimento") · ts-gravação=${ts_label} · CAN ${CANPASS_CAN_BITRATE} bps · ts-log=$([[ "$CANPASS_CAN_LOG_HUMAN" == 1 ]] && echo "humano" || echo "epoch")$([[ "$CANPASS_CAN_LOG_ASCII" == 1 ]] && echo " +ascii") · destino: ${CANPASS_REC_DIR}"
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
    CAN_BIN="$bin"   # guarda p/ o _stop_can_logger derrubar a interface ao sair

    # Subir a interface CAN usa sudo (NOPASSWD p/ 'ip' configurado pelo install.sh).
    # NUNCA bloquear pedindo senha aqui: no boot via systemd há um tty1 ANEXADO mas
    # ninguém p/ digitar — um 'sudo -v' interativo PENDURA o serviço inteiro (visto
    # em campo: watchdog preso em 'sudo -v', nada gravava). Apenas verifica o
    # NOPASSWD com um comando whitelistado ('ip', inofensivo) e SEGUE: se faltar, o
    # canpass-can avisa/re-tenta; com a regra correta o log sobe sem senha.
    if [[ $EUID -ne 0 ]] && ! sudo -n ip -V >/dev/null 2>&1; then
        log_warn "Sem sudo NOPASSWD p/ 'ip' — o log CAN pode falhar ao subir a interface. Rode 'canpass update'."
    fi

    : > "$CAN_CONSOLE_LOG"
    "$bin" log "${CANPASS_CAN_BITRATE:-250000}" >>"$CAN_CONSOLE_LOG" 2>&1 &
    CAN_LOG_PID=$!
    log_ok "Log CAN contínuo iniciado (PID ${CAN_LOG_PID}) — can_*.log em ${CANPASS_CAN_LOGDIR:-${CANPASS_REC_DIR:-$HOME/canpass_rec}}"
    log_info "Console do log CAN: tail -f ${CAN_CONSOLE_LOG}"

    # Monitor de hora do CAN: se a máquina transmitir o PGN 65254 (Time/Date),
    # registra na pasta da sessão (clock_offset.csv) o par 'epoch do Orin ↔ hora
    # real' — NÃO mexe no relógio (preserva a sincronia vídeo↔CAN). Herda o mesmo
    # CANPASS_REC_DIR, então o sidecar fica junto do vídeo+can_*.log desta sessão.
    "$bin" cantime "${CANPASS_CAN_BITRATE:-250000}" >>"$CAN_CONSOLE_LOG" 2>&1 &
    CANTIME_PID=$!
    log_ok "Monitor de hora-CAN iniciado (PID ${CANTIME_PID}) — clock_offset.csv quando a máquina enviar PGN 65254."
}

_stop_can_logger() {
    if [[ -n "$CANTIME_PID" ]]; then
        kill "$CANTIME_PID" 2>/dev/null; wait "$CANTIME_PID" 2>/dev/null; CANTIME_PID=""
    fi
    [[ -n "$CAN_LOG_PID" ]] || return 0
    kill "$CAN_LOG_PID" 2>/dev/null
    wait "$CAN_LOG_PID" 2>/dev/null
    CAN_LOG_PID=""
    # Derruba a interface CAN — antes ela ficava UP após encerrar o canpass.
    # ('ip link set down' usa sudo NOPASSWD já configurado p/ o canpass-can.)
    if [[ -n "$CAN_BIN" ]]; then
        "$CAN_BIN" down >/dev/null 2>&1 && log_info "Log CAN encerrado e interface CAN derrubada." \
            || log_info "Log CAN encerrado."
    else
        log_info "Log CAN encerrado."
    fi
}

# ─── Referência completa de comandos (impressa em toda partida) ──────────────
# CANPASS_NO_HELP=1 pula. Também acessível via 'canpass --help' (imprime e sai).

_show_reference() {
    [[ "${CANPASS_NO_HELP:-0}" == "1" ]] && return 0
    echo -e "${BOLD}${CYAN}══════════════════ CANPass — referência de comandos e parâmetros ══════════════════${NC}"
    echo -e "
${BOLD}canpass${NC} — stream + gravação de vídeo + log CAN (este comando)
  canpass                  entrevista → stream RTSP/WebRTC/HLS + gravação + log CAN contínuo
  canpass --display        idem, + janela ffplay local do stream
  canpass --all            multi-câmera: 1 stream por camN + gravação por câmera (CSI/YUV
                           detectadas + entrevista p/ somar N câmeras IP no mesmo processo)
  canpass --all --display  idem, + uma janela ffplay por stream
  canpass --local          preview direto no monitor do Orin (sem rede/gravação/entrevista/CAN)
  canpass --local --all    mosaico local com todas as câmeras (nvcompositor)
  canpass update           atualiza TODO o projeto (git pull + scripts + sudoers + serviço)
  canpass --help           imprime esta referência e sai

${BOLD}canpass-camera${NC} — alterna e ajusta a câmera do Orin (e-CAM82 ↔ NileCAM81, uma por boot)
  canpass-camera status                      câmera ativa neste boot (FDT do extlinux)
  canpass-camera list                        DTBs candidatos em /boot
  canpass-camera switch ecam82|nilecam81     troca o DTB ativo e oferece reboot
  canpass-camera preview [ecam82|nilecam81]  preview c/ menu de resolução e fallback de sink
      (nv3dsink → xvimagesink → ximagesink · --local = monitor do Orin via SSH ·
       --nv3dsink | --xvimagesink | --ximagesink = força um sink)
  canpass-camera ctrls                       controles V4L2: atual vs padrão (* = alterado)
  canpass-camera update                      git pull no repo-fonte + recopia p/ /usr/bin

${BOLD}canpass-can${NC} — sniffer/log do CANable USB (gs_usb, J1939 250k; listen-only por padrão)
  canpass-can detect            lista interfaces CAN + driver; aponta a do CANable
  canpass-can dump [bitrate]    sobe + candump no terminal (-tA = data+hora)
  canpass-can log [bitrate]     sobe + grava can_*.log (o canpass já inicia isso sozinho)
  canpass-can ascii [bitrate]   sobe + candump -a (hex + coluna ASCII)
  canpass-can sniff [bitrate]   monitora bytes que MUDAM (29-bit — achar eixo/botão)
  canpass-can selftest [br]     loopback interno: prova o adaptador sem depender do bus
  canpass-can up|status|down    só sobe / contadores e estado / derruba a interface

${BOLD}Parâmetros configuráveis (variáveis de ambiente)${NC}
  Partida:   CANPASS_NO_INTERVIEW=1 (pula entrevista) · CANPASS_PROMPT_TIMEOUT (30 s/pergunta)
             CANPASS_NO_HELP=1 (oculta esta referência)
  Stream:    CANPASS_CSI_RES \"WxH@FPS\" (CSI/Argus 1920x1080@30 · YUV/NileCAM81 @60) · CANPASS_CSI_BITRATE (8000000)
             CANPASS_CSI_ENCODER auto|hw|sw · CANPASS_CSI_SENSORS \"0 1...\" (fallback s/ /dev/video)
             CANPASS_NO_CLOCK_BOOST=1 · CANPASS_MOSAIC_W/CANPASS_MOSAIC_H (mosaico --local --all)
             CANPASS_IP_ENCODE=1 (reencoda IP em x264; padrão republica -c copy, sem reencode)
             CANPASS_IP_URLS \"rtsp://a rtsp://b\" (soma câmeras IP ao --all sem entrevista; boot/campo)
  Gravação:  CANPASS_REC_MODE continuous|motion · CANPASS_REC_DIR (~/canpass_rec)
             CANPASS_REC_EXTERNAL=1 (padrão: grava no 1º disco externo) · CANPASS_REC_DIR_FALLBACK (interno)
             CANPASS_MIN_FREE_MB (8192 = 8 GB) — abaixo disso o vídeo E o log CAN PAUSAM (protege o Orin)
             CANPASS_CONT_CRF (21) · CANPASS_CONT_SEGMENT_SECS (600)
             MOTION_THRESHOLD (0.02) · MOTION_COOLDOWN_SECS (30) · CANPASS_MOTION_CRF (18)
             CANPASS_REC_TIMESTAMP=1 (relógio HH:MM:SS.mmm queimado) · CANPASS_TS_FONTSIZE (h/22)
             CANPASS_TS_POSITION bl|br|tl|tr|off (canto do timestamp; padrão bl=inf-esq)
  CAN:       CANPASS_CAN_IF (força iface) · CANPASS_CAN_BITRATE (250000) · CANPASS_CAN_ACTIVE=1
             CANPASS_CAN_LOGDIR · CANPASS_CAN_LOG_HUMAN=1 · CANPASS_CAN_LOG_ASCII=1
             CANPASS_CAN_STALL_SECS (6)
  Câmera:    CANPASS_DTB_ECAM82 · CANPASS_DTB_NILECAM81 · CANPASS_SENSOR_ID (0) · CANPASS_EXTLINUX

${BOLD}Controles de imagem${NC} (valem p/ 'canpass-camera preview' e p/ o stream; nomes por câmera)
  e-CAM82 (Argus):  CANPASS_FLICKER 0..3 · CANPASS_EXPOSURECOMP -2..2 · CANPASS_EXPTIME \"min max\" ns
                    CANPASS_GAINRANGE · CANPASS_ISPGAIN · CANPASS_AELOCK · CANPASS_AWBLOCK
                    CANPASS_WBMODE 0..9 · CANPASS_SATURATION 0..2 · CANPASS_TNR_MODE/_STRENGTH
                    CANPASS_EE_MODE/_STRENGTH · CANPASS_AEREGION · CANPASS_SENSOR_MODE · CANPASS_HDR 0|1
  NileCAM81 (V4L2): CANPASS_HDR 0|1|2 · CANPASS_EXPAUTO 0|1|2 · CANPASS_EXPTIME 1..10000
                    CANPASS_EXPOSURECOMP 8000..1000000 · CANPASS_ROI_SIZE/_POS · CANPASS_GAIN 1..100
                    CANPASS_WBAUTO 0|1 · CANPASS_WBTEMP 1000..10000 · CANPASS_BRIGHTNESS -15..15
                    CANPASS_CONTRAST 0..10 · CANPASS_SATURATION 0..60 · CANPASS_GAMMA 40..500
                    CANPASS_SHARPNESS 0..7 · CANPASS_DENOISE 0..15 · CANPASS_HFLIP/_VFLIP 0|1
                    CANPASS_FPS 3..60 · CANPASS_FRAMESYNC 0..3 · CANPASS_TRIGGER 0|1 · CANPASS_EFFECT 0..4
  Câmera IP (HTTP):  aplicados via API do fabricante na entrevista (precisa de curl) · porta CANPASS_IPCAM_HTTP_PORT (80)
    Hikvision:       CANPASS_HIK_BRIGHTNESS/_CONTRAST/_SATURATION/_HUE/_SHARPNESS 0..100 · _WDR off|0..100
    Intelbras:       CANPASS_INTELBRAS_BRIGHTNESS/_CONTRAST/_SATURATION/_HUE/_SHARPNESS 0..100 · _WDR off|on · _EXTRA (cru)
    Vivotek:         CANPASS_VIVOTEK_BRIGHTNESS/_CONTRAST/_SATURATION/_SHARPNESS 0..100 · _WDR off|on · _EXTRA (cru)

  Ajuda detalhada:  canpass-camera --help · canpass-can --help · canpass-camera ctrls
  Documentação:     doc/e-CAM82/README.md · doc/NileCAM81/README.md · doc/CAN/README.md
${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════════${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# 'canpass update': atualização COMPLETA do projeto no Orin — git pull no
# repo-fonte + install.sh --update (scripts, sudoers, alias e serviço systemd;
# sem apt/driver). Repo-fonte: CANPASS_SRC ou o registrado pelo install.sh.
if [[ "${1:-}" == "update" || "${1:-}" == "--update" ]]; then
    src="${CANPASS_SRC:-$(cat /usr/local/share/canpass/src_dir 2>/dev/null)}"
    if [[ -z "$src" || ! -d "$src" ]]; then
        log_error "Repo-fonte não encontrado."
        log_error "Aponte com:  CANPASS_SRC=/caminho/do/clone canpass update"
        exit 1
    fi
    log_info "Repo-fonte: ${src}"
    if [[ -d "$src/.git" ]]; then
        log_info "git pull..."
        git -C "$src" pull --ff-only \
            || { log_error "git pull falhou (mudanças locais? rede?). Resolva e tente de novo."; exit 1; }
    else
        log_warn "${src} não é um clone git — pulando o git pull, apenas reaplicando a instalação."
    fi
    if [[ ! -f "$src/install.sh" ]]; then
        log_error "install.sh não encontrado em ${src}."
        exit 1
    fi
    sudo bash "$src/install.sh" --update
    exit $?
fi

# --help: só a referência, sem subir nada
for _a in "$@"; do
    [[ "$_a" == "-h" || "$_a" == "--help" ]] && { _show_reference; exit 0; }
done

trap '_stop_can_logger' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_show_reference

# --local = preview manual de diagnóstico: sem entrevista e sem log CAN
_preview=0
for _a in "$@"; do [[ "$_a" == "--local" ]] && _preview=1; done

if (( ! _preview )); then
    _setup_interview
    _setup_storage       # destino externo c/ fallback interno (vale c/ ou sem entrevista)
    _setup_session_dir
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
