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
#   canpass-can status            estado e contadores (erro/RX/TX) da interface
#   canpass-can down              derruba a interface
#
# LISTEN-ONLY é o padrão: sniffing seguro de barramento de veículo — o CANable não
# transmite, não dá ACK e não injeta frames de erro, então NÃO perturba a rede da
# máquina nem vai a bus-off. Para modo ativo (permitir cansend), use CANPASS_CAN_ACTIVE=1.
#
# Variáveis:
#   CANPASS_CAN_IF       força a interface (ex.: can2), pulando a auto-detecção
#   CANPASS_CAN_BITRATE  bitrate padrão (senão 250000 — J1939)
#   CANPASS_CAN_ACTIVE   =1 sobe SEM listen-only (permite enviar; cuidado em veículo)

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

# Sobe a interface (ip link) — só os comandos, sem logs (pra ser reusável).
_bring_up() {
    local ifc="$1" br="$2"
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo"
    local -a mode=(listen-only on)
    [[ "${CANPASS_CAN_ACTIVE:-0}" == "1" ]] && mode=(listen-only off)
    $sudo ip link set "$ifc" down 2>/dev/null
    $sudo ip link set "$ifc" type can bitrate "$br" "${mode[@]}" || return 1
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

cmd_dump() {
    local br="${1:-$DEFAULT_BITRATE}" ifc
    ifc=$(_find_canable) || { log_error "CANable (gs_usb) não encontrado. Rode 'canpass-can detect'."; return 1; }
    log_info "Subindo ${ifc} @ ${br} bps ($(_mode_label)) e abrindo candump..."
    _bring_up "$ifc" "$br" || { log_error "Falha ao subir ${ifc} (bitrate ${br})."; return 1; }
    log_ok "${ifc} UP. candump — Ctrl+C encerra. (J1939/Caterpillar = IDs de 29 bits)"
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    candump -ta "$ifc"
}

# Mostra o payload também como TEXTO (ASCII). Usa o '-a' nativo do candump (hex +
# coluna ASCII, byte não-imprimível vira '.'). Útil p/ frames que carregam string
# (VIN, IDs de software, nomes) — em dados binários de sinal vira ponto/lixo (normal).
cmd_ascii() {
    local br="${1:-$DEFAULT_BITRATE}" ifc
    ifc=$(_find_canable) || { log_error "CANable (gs_usb) não encontrado. Rode 'canpass-can detect'."; return 1; }
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    log_info "Subindo ${ifc} @ ${br} bps ($(_mode_label)) e decodificando payload como ASCII..."
    _bring_up "$ifc" "$br" || { log_error "Falha ao subir ${ifc} (bitrate ${br})."; return 1; }
    log_ok "${ifc} UP. Hex + coluna ASCII ('.'=não-imprimível). Ctrl+C encerra."
    candump -a "$ifc"
}

# Monitor de bytes que mudam — funciona com IDs ESTENDIDOS (29-bit / J1939), ao
# contrário do 'cansniffer' (can-utils 2020 ignora 29-bit silenciosamente). Imprime
# uma linha só quando algum byte de um ID muda, destacando o byte em vermelho — ideal
# para achar qual ID/byte é cada eixo do joystick.
cmd_sniff() {
    local br="${1:-$DEFAULT_BITRATE}" ifc
    ifc=$(_find_canable) || { log_error "CANable (gs_usb) não encontrado. Rode 'canpass-can detect'."; return 1; }
    command -v candump >/dev/null || { log_error "candump ausente — instale: sudo apt-get install can-utils"; return 1; }
    log_info "Subindo ${ifc} @ ${br} bps ($(_mode_label)) e monitorando bytes que mudam..."
    _bring_up "$ifc" "$br" || { log_error "Falha ao subir ${ifc} (bitrate ${br})."; return 1; }
    log_ok "${ifc} UP. Mostra só frames cujo byte MUDOU (vermelho). Mexa UM eixo por vez. Ctrl+C encerra."
    echo "    ID        b0 b1 b2 b3 b4 b5 b6 b7"
    # candump padrão: $1=iface $2=ID $3=[len] $4..=bytes
    candump "$ifc" | awk '
        {
            id=$2; out=""; chg=0
            for (i=4; i<=NF; i++) {
                k = id SUBSEP (i-4)
                if ((k in prev) && prev[k] != $i) { out = out sprintf(" \033[1;31m%s\033[0m", $i); chg=1 }
                else                              { out = out sprintf(" %s", $i) }
                prev[k] = $i
            }
            if (chg) { printf "  %-9s%s\n", id, out; fflush() }
        }'
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
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo"
    $sudo ip link set "$ifc" down && log_ok "${ifc} DOWN."
}

usage() {
    cat <<EOF
canpass-can — sniffer do CANable (USB/gs_usb) no Orin, resolvendo a interface pelo driver

  canpass-can detect          lista CANs + driver; aponta a do CANable (ignora mttcan nativo)
  canpass-can dump  [bitrate] sobe (listen-only) + candump   ·  padrão ${DEFAULT_BITRATE} (J1939)
  canpass-can ascii [bitrate] sobe + candump -a (hex + coluna ASCII — frames de texto)
  canpass-can sniff [bitrate] sobe + monitora bytes que MUDAM (29-bit/J1939 — achar eixo do joystick)
  canpass-can up    [bitrate] só sobe a interface
  canpass-can status          estado e contadores (diagnóstico de bitrate)
  canpass-can down            derruba a interface

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
        ascii|text)     cmd_ascii "$@" ;;
        sniff)          cmd_sniff "$@" ;;
        status)         cmd_status "$@" ;;
        down)           cmd_down "$@" ;;
        -h|--help|help) usage ;;
        *) log_error "Comando desconhecido: '$cmd'"; echo; usage; return 2 ;;
    esac
}

main "$@"
