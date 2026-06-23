#!/usr/bin/env bash
# canpass-can — sniffer SocketCAN para o adaptador USB CANable (driver gs_usb) no Orin.
#
# Resolve a interface pelo DRIVER (gs_usb), ignorando os CAN nativos do Tegra (mttcan).
# Assim nunca erra a interface mesmo que o nome (can2/can3…) mude ao reenumerar o USB —
# o que acontece, p.ex., depois de um surto de erro por bitrate errado.
#
# Uso:
#   canpass-can detect            lista interfaces CAN + driver; aponta a do CANable
#   canpass-can up [bitrate]      sobe a interface do CANable (listen-only) — padrão 250000
#   canpass-can dump [bitrate]    up + candump (Ctrl+C encerra). J1939/Caterpillar: IDs 29-bit
#   canpass-can selftest [bitrate] loopback interno: prova o adaptador sem depender do bus
#   canpass-can status            estado e contadores (erro/RX/TX) da interface
#   canpass-can down              derruba a interface
#
# dump/ascii/sniff/log rodam SUPERVISIONADOS (watchdog de fluxo): re-detectam o
# CANable se a interface cair/reenumerar e reciclam down/up se o RX travar.
#
# LISTEN-ONLY é o padrão: sniffing seguro de barramento de veículo — o CANable não
# transmite, não dá ACK e não injeta frames de erro, então NÃO perturba a rede da
# máquina nem vai a bus-off. Para modo ativo (permitir cansend), use CANPASS_CAN_ACTIVE=1.
#
# Variáveis:
#   CANPASS_CAN_IF         força a interface (ex.: can2), pulando a auto-detecção
#   CANPASS_CAN_BITRATE    bitrate padrão (senão 250000 — J1939)
#   CANPASS_CAN_ACTIVE     =1 sobe SEM listen-only (permite enviar; cuidado em veículo)
#   CANPASS_CAN_LOG_HUMAN  =1 'log' com data+hora legível em vez de epoch (não replayável)
#   CANPASS_CAN_LOG_ASCII  =1 'log' com coluna ASCII (candump -a; não replayável)

set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

DEFAULT_BITRATE="${CANPASS_CAN_BITRATE:-250000}"

# Driver bindado numa interface de rede (ex.: gs_usb, mttcan).
_iface_driver() {
    basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null
}

# Acha a interface do CANable (driver gs_usb). Override: CANPASS_CAN_IF.
_find_canable() {
    if [[ -n "${CANPASS_CAN_IF:-}" ]]; then
        [[ -e "/sys/class/net/${CANPASS_CAN_IF}" ]] && { echo "$CANPASS_CAN_IF"; return 0; }
        log_error "CANPASS_CAN_IF=${CANPASS_CAN_IF} não existe."; return 1
    fi
    local n
    for n in /sys/class/net/can*; do
        [[ -e "$n" ]] || continue
        n=$(basename "$n")
        [[ "$(_iface_driver "$n")" == gs_usb ]] && { echo "$n"; return 0; }
    done
    return 1
}

# Desliga o autosuspend de USB do adaptador (causa comum de "parou de receber"):
# sobe a hierarquia /sys a partir da net device até achar um power/control USB e grava 'on'.
_disable_usb_autosuspend() {
    local ifc="$1" d sudo=""
    [[ $EUID -ne 0 ]] && sudo="sudo -n"   # -n: nunca pendurar pedindo senha (tty1 do systemd)
    d=$(readlink -f "/sys/class/net/$ifc/device" 2>/dev/null) || return 0
    while [[ "$d" == /sys/* && "$d" != "/sys" ]]; do
        if [[ -f "$d/power/control" ]]; then
            echo on | $sudo tee "$d/power/control" >/dev/null 2>&1
            return 0
        fi
        d=$(dirname "$d")
    done
}

# Sobe a interface (ip link) — só os comandos, sem logs (pra ser reusável).
# restart-ms 100: auto-recupera de bus-off. Também desliga o autosuspend do USB.
_bring_up() {
    local ifc="$1" br="$2"
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo -n"   # -n: nunca pendurar pedindo senha (tty1 do systemd)
    local -a mode=(listen-only on)
    [[ "${CANPASS_CAN_ACTIVE:-0}" == "1" ]] && mode=(listen-only off)
    _disable_usb_autosuspend "$ifc"
    $sudo ip link set "$ifc" down 2>/dev/null
    $sudo ip link set "$ifc" type can bitrate "$br" restart-ms 100 "${mode[@]}" || return 1
    $sudo ip link set "$ifc" up || return 1
}

_mode_label() { [[ "${CANPASS_CAN_ACTIVE:-0}" == "1" ]] && echo "ATIVO (transmite!)" || echo "listen-only"; }

cmd_detect() {
    local found="" any=""
    log_info "Interfaces CAN:"
    local n drv tag
    for n in /sys/class/net/can*; do
        [[ -e "$n" ]] || break
        any=1; n=$(basename "$n"); drv=$(_iface_driver "$n")
        if [[ "$drv" == gs_usb ]]; then tag="${GREEN}← CANable (USB)${NC}"; found="$n"
        elif [[ "$drv" == mttcan ]]; then tag="${YELLOW}(CAN nativo do Orin — ignorar)${NC}"
        else tag=""; fi
        echo -e "  ${BOLD}${n}${NC}  driver=${drv:-?}  ${tag}"
    done
    [[ -n "$any" ]] || log_warn "Nenhuma interface can* encontrada."
    echo
    if [[ -n "$found" ]]; then
        log_ok "CANable = ${found}"
        lsusb 2>/dev/null | grep -iE '1d50:606f|1209:2323' >/dev/null && log_ok "Presente no USB." || true
    else
        log_error "CANable (gs_usb) não encontrado."
        log_error "Replugue o adaptador. Cheque:  lsusb | grep 1d50:606f  ·  dmesg | grep -i gs_usb"
        return 1
    fi
}

cmd_up() {
    local br="${1:-$DEFAULT_BITRATE}" ifc
    ifc=$(_find_canable) || { log_error "CANable (gs_usb) não encontrado. Rode 'canpass-can detect'."; return 1; }
    log_info "Subindo ${ifc} @ ${br} bps ($(_mode_label))..."
    _bring_up "$ifc" "$br" || { log_error "Falha ao configurar/subir ${ifc} (bitrate ${br})."; return 1; }
    log_ok "${ifc} UP @ ${br} bps · $(_mode_label)."
}

# ─── Loop supervisionado (compartilhado por dump/ascii/sniff/log) ────────────
# Diretório do log CAN AGORA, com fallback + guarda de espaço — espelha o
# _rec_dir_now do cam_view p/ vídeo + log CAN ficarem JUNTOS na mesma pasta de
# sessão e seguirem o MESMO disco. Preferido: CANPASS_CAN_LOGDIR ou CANPASS_REC_DIR
# (pasta de sessão no destino); fallback: CANPASS_REC_DIR_FALLBACK (interno).
# Sem nenhum destino com a margem livre (CANPASS_MIN_FREE_MB, padrão 8192 = 8 GB)
# ecoa VAZIO → o log PAUSA (não enche o disco do Orin). Avisos vão p/ stderr.
_can_logdir_now() {
    local min_mb="${CANPASS_MIN_FREE_MB:-8192}"
    local pref="${CANPASS_CAN_LOGDIR:-${CANPASS_REC_DIR:-$HOME/canpass_rec}}"
    local fb="${CANPASS_REC_DIR_FALLBACK:-$HOME/canpass_rec}"
    local d free_mb
    for d in "$pref" "$fb"; do
        [[ -n "$d" ]] || continue
        mkdir -p "$d" 2>/dev/null || continue
        [[ -w "$d" ]] || continue
        free_mb=$(df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}')
        [[ "$free_mb" =~ ^[0-9]+$ ]] || continue
        (( free_mb >= min_mb )) && { echo "$d"; return 0; }
    done
    echo ""   # vazio = sem espaço → pausa
}

# Mantém um candump vivo contra os 3 modos de falha já vistos em campo:
#   • candump morre (interface caiu/reenumerou)   → re-detecta pelo driver e religa
#   • CANable some do USB (replug)                → aguarda reaparecer
#   • rx_packets parado por CANPASS_CAN_STALL_SECS s (RX travado do gs_usb) → down/up
# $1 = bitrate · $2 = destino da saída:
#        '-'      = terminal
#        'dir:'   = modo LOG dinâmico — resolve a pasta a cada (re)início via
#                   _can_logdir_now (fallback + guarda de espaço) e reabre um
#                   can_<ts>.log novo quando o disco muda; PAUSA se faltar espaço
#        <arquivo> = caminho fixo (append)
# $3.. = args do candump (sem a interface). Não retorna — Ctrl+C/TERM encerra.
_supervised_candump() {
    local br="$1" out="$2"; shift 2
    local -a dargs=("$@")
    # stdbuf -oL: força line-buffering no candump — sem isso a escrita em pipe/
    # arquivo usa buffer de bloco (~4 KB) e os frames apareceriam com atraso.
    local SB=""; command -v stdbuf >/dev/null && SB="stdbuf -oL"
    local stall="${CANPASS_CAN_STALL_SECS:-6}"   # s sem frame novo antes de reciclar

    local dynamic=0 logdir="" prev_logdir="" nospace=0
    [[ "$out" == "dir:" ]] && dynamic=1

    local cdpid=""
    _sup_cleanup() {
        [[ -n "$cdpid" ]] && kill "$cdpid" 2>/dev/null
        echo; [[ -n "$out" && "$out" != "-" && "$out" != "dir:" && -f "$out" ]] && log_info "Captura encerrada: ${out}"
        exit 0
    }
    trap _sup_cleanup INT TERM

    # consec = reciclagens seguidas sem nenhum frame — modula o ruído dos avisos:
    # avisa na 1ª, depois só a cada 10 (bus mudo geraria um aviso a cada ~7 s).
    local ifc rxfile last cur stale tick consec=0 dest
    while true; do
        # Modo LOG dinâmico: resolve a pasta de destino AGORA (segue o vídeo);
        # sem espaço → pausa (não inicia candump).
        if (( dynamic )); then
            logdir="$(_can_logdir_now)"
            if [[ -z "$logdir" ]]; then
                (( nospace == 0 )) && log_warn "Sem armazenamento com a margem de ${CANPASS_MIN_FREE_MB:-8192}MB livres — log CAN PAUSADO até liberar/repor disco."
                nospace=1; sleep 10; continue
            fi
            (( nospace == 1 )) && { log_ok "Espaço liberado — retomando o log CAN em ${logdir}."; nospace=0; consec=0; }
            # Abre um arquivo NOVO só quando a pasta MUDA (disco externo↔interno) ou
            # ainda não há arquivo. Sem isto, cada reciclagem por bus mudo (~7s) criava
            # um can_<ts>.log novo de 0 byte → centenas de arquivos vazios em campo.
            if [[ "$logdir" != "$prev_logdir" || "$out" == "dir:" ]]; then
                out="${logdir}/can_$(date +%Y%m%d_%H%M%S).log"
                prev_logdir="$logdir"
            fi
        fi
        if ! ifc=$(_find_canable); then
            log_warn "CANable ausente (replug?). Aguardando reaparecer..."
            sleep 2; continue
        fi
        _bring_up "$ifc" "$br" || { log_warn "Falha ao subir ${ifc}; nova tentativa em 2s..."; sleep 2; continue; }
        rxfile="/sys/class/net/${ifc}/statistics/rx_packets"
        if [[ "$out" == "-" ]]; then
            $SB candump "${dargs[@]}" "$ifc" &
        else
            $SB candump "${dargs[@]}" "$ifc" >> "$out" &
        fi
        cdpid=$!
        if (( consec == 0 )); then
            dest=""; [[ "$out" != "-" && ! -p "$out" ]] && dest=" → ${out##*/}"
            log_ok "Capturando ${ifc} @ ${br} ($(_mode_label))${dest}"
        fi

        last=$(cat "$rxfile" 2>/dev/null || echo 0); stale=0; tick=0
        while kill -0 "$cdpid" 2>/dev/null; do
            sleep 1
            cur=$(cat "$rxfile" 2>/dev/null || echo "$last")
            if [[ "$cur" == "$last" ]]; then
                stale=$((stale+1))
            else
                (( consec > 0 )) && log_ok "RX voltou ($(date +%H:%M:%S) — ${cur} frames)."
                stale=0; consec=0; last="$cur"
            fi
            tick=$((tick+1))
            # tique de vida só nos modos cuja saída não é o terminal (log/sniff) —
            # no dump/ascii os próprios frames mostram que está vivo.
            [[ "$out" != "-" ]] && (( tick % 15 == 0 )) && log_info "vivo $(date +%H:%M:%S) — ${last} frames recebidos"
            # Modo dinâmico: se a pasta de destino mudou (disco externo sumiu/voltou)
            # ou ficou sem espaço, encerra este candump p/ reabrir no destino certo.
            if (( dynamic )) && (( tick % 10 == 0 )); then
                local nd; nd="$(_can_logdir_now)"
                if [[ "$nd" != "$logdir" ]]; then
                    log_warn "Destino do log CAN mudou (${logdir:-∅} → ${nd:-∅}) — reabrindo o log."
                    kill "$cdpid" 2>/dev/null; cdpid=""; break
                fi
            fi
            if (( stale >= stall )); then
                consec=$((consec+1))
                if (( consec == 1 )); then
                    log_warn "Sem frame há ${stale}s — reciclando ${ifc} (RX travado? bus quieto?)."
                elif (( consec % 10 == 0 )); then
                    log_warn "Bus segue mudo há ~$(( consec * (stall + 1) ))s — chave da máquina ligada? Fiação? (reciclando)"
                fi
                kill "$cdpid" 2>/dev/null; cdpid=""
                break
            fi
        done
        if [[ -n "$cdpid" ]]; then
            wait "$cdpid" 2>/dev/null
            log_warn "candump saiu (interface caiu/reenumerou?). Re-detectando..."
            cdpid=""
        fi
        # Backoff quando o bus está só MUDO: cada reciclagem sem frame fazia um ciclo
        # down/up (3 sudo) a cada ~7s — em bancada/chave desligada isso inundava o
        # journal e os logs de sudo por horas, sem ganho. Com várias reciclagens
        # seguidas vazias (consec), espaça a próxima tentativa até ~30s. RX de volta
        # zera 'consec' (acima) → reconecta na hora; reenumeração (consec 0) idem.
        if (( consec > 1 )); then
            local backoff=$(( consec * 3 )); (( backoff > 30 )) && backoff=30
            sleep "$backoff"
        else
            sleep 1
        fi
    done
}

cmd_dump() {
    local br="${1:-$DEFAULT_BITRATE}"
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    log_info "Dump no terminal @ ${br} bps ($(_mode_label)) — watchdog de fluxo ativo."
    log_info "-tA = data+hora real · J1939/Caterpillar = IDs de 29 bits · Ctrl+C encerra."
    _supervised_candump "$br" - -tA
}

# Mostra o payload também como TEXTO (ASCII). Usa o '-a' nativo do candump (hex +
# coluna ASCII, byte não-imprimível vira '.'). Útil p/ frames que carregam string
# (VIN, IDs de software, nomes) — em dados binários de sinal vira ponto/lixo (normal).
cmd_ascii() {
    local br="${1:-$DEFAULT_BITRATE}"
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    log_info "ASCII no terminal @ ${br} bps ($(_mode_label)) — watchdog de fluxo ativo."
    log_info "Data+hora (-tA) + hex + ASCII ('.'=não-imprimível). Ctrl+C encerra."
    _supervised_candump "$br" - -tA -a
}

# Grava a CAN em arquivo de log com timestamp EPOCH (formato candump -L: replayável
# com canplayer). O epoch é o mesmo relógio do vídeo → permite casar imagem ↔ frame CAN
# depois. Diretório padrão = mesmo das gravações (CANPASS_REC_DIR), p/ vídeo+CAN juntos.
cmd_log() {
    local br="${1:-$DEFAULT_BITRATE}"
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }

    # Formato: epoch (-L, replayável por canplayer) por padrão; legível (-tA, data+hora)
    # com CANPASS_CAN_LOG_HUMAN=1. CANPASS_CAN_LOG_ASCII=1 acrescenta a coluna de
    # texto do candump (-a). O ÚNICO formato replayável é o epoch puro (-L) — tanto
    # o legível quanto o ASCII usam o layout normal do candump, que o canplayer não lê.
    local human="${CANPASS_CAN_LOG_HUMAN:-0}" ascii="${CANPASS_CAN_LOG_ASCII:-0}"
    local -a dargs; local note
    if [[ "$human" == "1" && "$ascii" == "1" ]]; then
        dargs=(-tA -a); note="data+hora legível + ASCII (NÃO replayável por canplayer)"
    elif [[ "$human" == "1" ]]; then
        dargs=(-tA);    note="data+hora legível (NÃO replayável por canplayer)"
    elif [[ "$ascii" == "1" ]]; then
        dargs=(-ta -a); note="epoch + ASCII (NÃO replayável — p/ replay use o modo normal)"
    else
        dargs=(-L);     note="epoch, replayável:  canplayer -I can_<ts>.log"
    fi

    # Destino DINÂMICO: pasta de sessão da gravação (vídeo + CAN juntos), com
    # fallback p/ o interno se o disco externo sumir e PAUSA se faltar espaço
    # (margem CANPASS_MIN_FREE_MB, padrão 8 GB) — resolvido a cada (re)início.
    log_ok "Log CAN → pasta de sessão da gravação (vídeo + CAN juntos)."
    log_info "Formato: ${note}"
    log_info "Fallback p/ interno se o disco externo sumir · PAUSA se livre < ${CANPASS_MIN_FREE_MB:-8192}MB."
    log_info "Watchdog de FLUXO: recicla a interface se ficar ${CANPASS_CAN_STALL_SECS:-6}s sem frame."
    log_info "Ctrl+C encerra."

    _supervised_candump "$br" "dir:" "${dargs[@]}"
}

# Monitor de bytes que mudam — funciona com IDs ESTENDIDOS (29-bit / J1939), ao
# contrário do 'cansniffer' (can-utils 2020 ignora 29-bit silenciosamente). Imprime
# uma linha só quando algum byte de um ID muda, destacando o byte em vermelho — ideal
# para achar qual ID/byte é cada eixo do joystick.
cmd_sniff() {
    local br="${1:-$DEFAULT_BITRATE}"
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    log_info "Monitor de bytes que MUDAM @ ${br} bps ($(_mode_label)) — watchdog de fluxo ativo."
    log_ok "Mostra só frames cujo byte MUDOU (vermelho). Mexa UM eixo por vez. Ctrl+C encerra."
    echo "    ID        b0 b1 b2 b3 b4 b5 b6 b7"

    # candump → FIFO → awk: o awk fica FORA do loop supervisionado, lendo do FIFO.
    # O fd 9 (read-write) impede o EOF quando o candump é reciclado pelo watchdog,
    # então o estado 'prev' (último byte visto por ID) sobrevive às reciclagens.
    local fifo
    fifo=$(mktemp -u /tmp/canpass_sniff.XXXXXX) && mkfifo "$fifo" \
        || { log_error "Falha ao criar FIFO em /tmp."; return 1; }
    exec 9<>"$fifo"
    # candump padrão: $1=iface $2=ID $3=[len] $4..=bytes
    awk '
        {
            id=$2; out=""; chg=0
            for (i=4; i<=NF; i++) {
                k = id SUBSEP (i-4)
                if ((k in prev) && prev[k] != $i) { out = out sprintf(" \033[1;31m%s\033[0m", $i); chg=1 }
                else                              { out = out sprintf(" %s", $i) }
                prev[k] = $i
            }
            if (chg) { printf "  %-9s%s\n", id, out; fflush() }
        }' <"$fifo" &
    local awkpid=$!
    trap 'kill "$awkpid" 2>/dev/null; exec 9>&-; rm -f "$fifo"' EXIT

    _supervised_candump "$br" "$fifo"
}

# ─── selftest (loopback interno) ─────────────────────────────────────────────
# Prova o caminho controlador→driver gs_usb→USB sem depender do barramento: sobe
# em LOOPBACK (o controlador ecoa o próprio frame), envia 1 frame e espera ele
# voltar. PASS = adaptador OK (se o dump segue vazio no veículo, o problema é
# fiação/transceiver/bus quieto). FAIL = adaptador travado/morto (replug, troca).
cmd_selftest() {
    local br="${1:-$DEFAULT_BITRATE}" ifc
    ifc=$(_find_canable) || { log_error "CANable (gs_usb) não encontrado. Rode 'canpass-can detect'."; return 1; }
    command -v candump >/dev/null && command -v cansend >/dev/null \
        || { log_error "can-utils incompleto — instale: sudo apt-get install can-utils"; return 1; }
    command -v timeout >/dev/null || { log_error "'timeout' (coreutils) ausente."; return 1; }
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo -n"   # -n: nunca pendurar pedindo senha (tty1 do systemd)

    log_warn "O teste usa modo LOOPBACK (não listen-only) e envia 1 frame de teste."
    log_warn "Por segurança, DESCONECTE o adaptador do barramento do veículo antes."
    local ans
    read -rp "$(echo -e "${CYAN}Adaptador desconectado do veículo? [s/N]:${NC} ")" ans
    [[ "$ans" =~ ^[sSyY]$ ]] || { log_info "Abortado."; return 1; }

    log_info "Subindo ${ifc} @ ${br} bps em loopback interno..."
    _disable_usb_autosuspend "$ifc"
    $sudo ip link set "$ifc" down 2>/dev/null
    $sudo ip link set "$ifc" type can bitrate "$br" restart-ms 100 loopback on listen-only off \
        || { log_error "Falha ao configurar loopback em ${ifc}."; return 1; }
    $sudo ip link set "$ifc" up || { log_error "Falha ao subir ${ifc}."; return 1; }

    # candump espera 1 frame (timeout 3 s); cansend dispara. O eco só acontece se o
    # adaptador realmente processar o TX — é isso que separa 'travado' de 'OK'.
    local tmp got dpid
    tmp=$(mktemp)
    timeout 3 candump -n 1 "$ifc" >"$tmp" 2>/dev/null &
    dpid=$!
    sleep 0.5
    cansend "$ifc" 5A5#DEADBEEF 2>/dev/null || log_warn "cansend retornou erro (TX pode ter falhado)."
    wait "$dpid" 2>/dev/null
    got=$(<"$tmp"); rm -f "$tmp"

    $sudo ip link set "$ifc" down 2>/dev/null   # nunca deixar a iface em loopback

    if [[ -n "$got" ]]; then
        log_ok "PASS — frame ecoou: $(echo $got)"
        log_ok "Controlador, driver gs_usb e caminho USB estão OK."
        log_info "Se o 'dump' segue vazio no veículo: chave ligada? CAN_H/CAN_L nos pinos certos"
        log_info "(Deutsch 9p da CAT: F/G; D/E são CAT Data Link, não CAN)? Transceiver queimado?"
        log_info "Interface ficou DOWN — 'canpass-can dump' religa em listen-only."
    else
        log_error "FAIL — o frame não voltou (adaptador travado ou defeituoso)."
        log_error "Replugue o USB (power-cycle real — down/up não reseta o firmware) e repita."
        log_error "Persistindo, teste outro CANable."
        return 1
    fi
}

cmd_status() {
    local ifc
    ifc=$(_find_canable) || { log_error "CANable não encontrado."; return 1; }
    log_info "Estado/contadores de ${ifc} (bitrate certo = ERROR-ACTIVE, erros parados, RX subindo):"
    ip -details -statistics link show "$ifc"
}

cmd_down() {
    local ifc
    ifc=$(_find_canable) || { log_error "CANable não encontrado."; return 1; }
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo -n"   # -n: nunca pendurar pedindo senha (tty1 do systemd)
    $sudo ip link set "$ifc" down && log_ok "${ifc} DOWN."
}

usage() {
    cat <<EOF
canpass-can — sniffer do CANable (USB/gs_usb) no Orin, resolvendo a interface pelo driver

  canpass-can detect          lista CANs + driver; aponta a do CANable (ignora mttcan nativo)
  canpass-can dump  [bitrate] sobe (listen-only) + candump   ·  padrão ${DEFAULT_BITRATE} (J1939)
  canpass-can log   [bitrate] sobe + grava em arquivo (epoch, replayável; p/ sync c/ vídeo)
  canpass-can ascii [bitrate] sobe + candump -a (hex + coluna ASCII — frames de texto)
  canpass-can sniff [bitrate] sobe + monitora bytes que MUDAM (29-bit/J1939 — achar eixo do joystick)
  canpass-can selftest [br]   LOOPBACK interno: prova o adaptador sem depender do barramento
  canpass-can up    [bitrate] só sobe a interface
  canpass-can status          estado e contadores (diagnóstico de bitrate)
  canpass-can down            derruba a interface

dump/ascii/sniff/log são SUPERVISIONADOS: re-detectam o CANable se a interface cair e
reciclam down/up após ${CANPASS_CAN_STALL_SECS:-6}s sem frame (RX travado do gs_usb).
Listen-only é o padrão (seguro p/ barramento de veículo). Modo ativo: CANPASS_CAN_ACTIVE=1.
Caterpillar usa J1939 (250 kbit/s, IDs de 29 bits). Ex.:  canpass-can dump 250000
EOF
}

main() {
    local cmd="${1:-detect}"; shift || true
    case "$cmd" in
        detect)         cmd_detect "$@" ;;
        up)             cmd_up "$@" ;;
        dump)           cmd_dump "$@" ;;
        log|record)     cmd_log "$@" ;;
        ascii|text)     cmd_ascii "$@" ;;
        sniff)          cmd_sniff "$@" ;;
        selftest|test)  cmd_selftest "$@" ;;
        status)         cmd_status "$@" ;;
        down)           cmd_down "$@" ;;
        -h|--help|help) usage ;;
        *) log_error "Comando desconhecido: '$cmd'"; echo; usage; return 2 ;;
    esac
}

main "$@"
