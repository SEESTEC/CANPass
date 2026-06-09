#!/usr/bin/env bash
# canpass-camera — alterna a câmera ativa do Orin entre e-CAM82 (MIPI/IMX485) e
# NileCAM81 (GMSL/AR0821) NO MESMO FLASH (L4T 35.2.1), sem reflash, trocando o
# DTB ativo (linha FDT do extlinux). Também faz preview local (nvarguscamerasrc →
# nv3dsink), com resolução/FPS escolhidos pelo usuário a partir das tabelas de
# "Maximum Frame Rate Supported" de cada câmera.
#
# CONTEXTO (ver doc/NileCAM81/COMPATIBILIDADE.md):
#   As duas câmeras usam o MESMO conector físico J509 e UM device tree por boot —
#   logo NÃO rodam juntas; o que dá é ALTERNAR uma por boot. Isso exige ter os dois
#   drivers instalados no flash 35.2.1. Hoje a e-CAM82 (eimx485) está instalada; a
#   NileCAM81 p/ 35.2.1 ainda PRECISA ser obtida da e-con (temos só 35.4.1/36.3.0).
#   Enquanto o DTB da NileCAM81 não estiver em /boot, 'switch nilecam81' aborta com
#   instrução — de propósito (não deixa o Orin sem boot válido).
#
# Uso:
#   canpass-camera status                 # mostra a câmera ativa (FDT atual)
#   canpass-camera switch ecam82|nilecam81  # troca o DTB ativo e oferece reboot
#   canpass-camera preview [ecam82|nilecam81]  # preview local (nv3dsink), menu de resolução
#   canpass-camera list                   # lista DTBs candidatos achados em /boot
#
# Variáveis de ambiente (override):
#   CANPASS_DTB_ECAM82      caminho do .dtb da e-CAM82 (senão é auto-detectado em /boot)
#   CANPASS_DTB_NILECAM81   caminho do .dtb da NileCAM81 (senão auto-detectado em /boot)
#   CANPASS_SENSOR_ID       sensor-id do nvarguscamerasrc no preview (padrão: 0)
#   CANPASS_EXTLINUX        caminho do extlinux.conf (padrão: /boot/extlinux/extlinux.conf)

set -uo pipefail

# ─── Cores / log ─────────────────────────────────────────────────────────────
# ANSI-C quoting ($'...') guarda o byte ESC real — necessário porque o banner usa
# heredoc (cat <<EOF) que NÃO interpreta escapes; com 'aspas simples' sairia literal.
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

EXTLINUX="${CANPASS_EXTLINUX:-/boot/extlinux/extlinux.conf}"
SENSOR_ID="${CANPASS_SENSOR_ID:-0}"

# ─── Tabelas de resolução × FPS máximo ───────────────────────────────────────
# Fonte: "Table 1: Maximum Frame Rate Supported" de cada câmera (Getting Started
# Manual). Formato: "LARGURAxALTURA@FPS  descrição".
#
# e-CAM82 → CONFIRMADO (Getting Started Manual Rev 1.4, Table 1). Este setup usa o
# pacote IMX485 de 4 LANES, então só as linhas 4-lane abaixo. (2-lane, p/ referência:
# 1920x1080@62 ; 3840x2160@39/33 10/12-bit.) O FPS é o máximo em saída 10-bit; em
# 12-bit o 4K cai p/ 50.
# NileCAM81 → ⚠ A CONFIRMAR (NileCAM81_CUOAGX_Getting_Started_Manual_Rev_1_9.pdf) —
# valores abaixo são estimativa; a câmera nem está instalada ainda (falta build 35.2.1).

_res_options_ecam82() {
    cat <<'EOF'
1920x1080@90  Full HD (4-lane, 90 fps 10/12-bit)
3840x2160@60  4K UHD  (4-lane, 60 fps 10-bit / 50 em 12-bit)
EOF
}

_res_options_nilecam81() {
    cat <<'EOF'
3840x2160@30  4K UHD
1920x1080@60  Full HD
1280x720@60   HD
EOF
}

# ─── Resolução de DTB ────────────────────────────────────────────────────────
# Acha o .dtb da câmera pedida: usa o override de ambiente se válido, senão
# procura em /boot por padrões de nome. Retorna o caminho absoluto em stdout.
_resolve_dtb() {
    local cam="$1" override="" found=""
    local -a pats=()
    case "$cam" in
        ecam82)    override="${CANPASS_DTB_ECAM82:-}";    pats=(imx485 e-cam82 ecam82) ;;
        nilecam81) override="${CANPASS_DTB_NILECAM81:-}"; pats=(nilecam ar0821 0821 max96712) ;;
        *) log_error "Câmera desconhecida: '$cam' (use ecam82 ou nilecam81)."; return 2 ;;
    esac

    if [[ -n "$override" ]]; then
        if [[ -e "$override" ]]; then echo "$override"; return 0; fi
        log_error "Override aponta para '${override}', que não existe."; return 1
    fi

    local p
    for p in "${pats[@]}"; do
        found=$(find /boot -maxdepth 3 -iname "*${p}*.dtb" 2>/dev/null | sort | head -1)
        [[ -n "$found" ]] && { echo "$found"; return 0; }
    done

    log_error "Nenhum DTB de '${cam}' encontrado em /boot (padrões: ${pats[*]})."
    if [[ "$cam" == nilecam81 ]]; then
        log_error "A NileCAM81 ainda não tem driver instalado p/ L4T 35.2.1."
        log_error "Obtenha o pacote da e-con (build 35.2.1 / JP5.1.0) e instale antes de alternar."
        log_error "Veja doc/NileCAM81/COMPATIBILIDADE.md (seção 4)."
    fi
    return 1
}

# Mapeia um caminho de DTB para o nome amigável da câmera (heurística por padrão).
_dtb_to_camera() {
    local dtb="${1,,}"
    case "$dtb" in
        *imx485*|*e-cam82*|*ecam82*)       echo "e-CAM82 (MIPI/IMX485)" ;;
        *nilecam*|*ar0821*|*0821*|*96712*) echo "NileCAM81 (GMSL/AR0821)" ;;
        *)                                 echo "desconhecida" ;;
    esac
}

# ─── status ──────────────────────────────────────────────────────────────────
cmd_status() {
    if [[ ! -f "$EXTLINUX" ]]; then
        log_error "extlinux.conf não encontrado em ${EXTLINUX}."
        log_warn  "Não parece um Jetson, ou o caminho difere — use CANPASS_EXTLINUX=..."
        return 1
    fi
    local cur
    cur=$(grep -m1 -E '^[[:space:]]*FDT[[:space:]]' "$EXTLINUX" | awk '{print $2}')
    if [[ -z "$cur" ]]; then
        log_warn "Nenhuma linha 'FDT' ativa em ${EXTLINUX} — o boot usa o DTB padrão do firmware."
    else
        log_info "FDT ativo:  ${cur}"
        log_ok    "Câmera ativa: $(_dtb_to_camera "$cur")"
    fi
    if [[ -e /dev/video0 ]]; then
        log_ok "/dev/video0 presente (câmera enumerada)."
    else
        log_warn "/dev/video0 ausente — a câmera ativa pode não estar conectada/probada."
    fi
}

# ─── list ────────────────────────────────────────────────────────────────────
cmd_list() {
    log_info "DTBs candidatos em /boot:"
    local cam
    for cam in ecam82 nilecam81; do
        local d
        if d=$(_resolve_dtb "$cam" 2>/dev/null); then
            echo -e "  ${GREEN}${cam}${NC}  →  ${d}"
        else
            echo -e "  ${YELLOW}${cam}${NC}  →  (não encontrado)"
        fi
    done
}

# ─── switch ──────────────────────────────────────────────────────────────────
cmd_switch() {
    local cam="${1:-}"
    [[ -z "$cam" ]] && { log_error "Informe a câmera: canpass-camera switch ecam82|nilecam81"; return 2; }

    if [[ ! -f "$EXTLINUX" ]]; then
        log_error "extlinux.conf não encontrado em ${EXTLINUX}. Abortando (não é Jetson?)."
        return 1
    fi

    local dtb
    dtb=$(_resolve_dtb "$cam") || return 1
    log_ok "DTB de ${cam}: ${dtb}"

    local cur
    cur=$(grep -m1 -E '^[[:space:]]*FDT[[:space:]]' "$EXTLINUX" | awk '{print $2}')
    if [[ "$cur" == "$dtb" ]]; then
        log_ok "A câmera '${cam}' já é a ativa (FDT já aponta para ${dtb}). Nada a fazer."
        return 0
    fi

    log_info "Alterando FDT:  ${cur:-<nenhum>}  →  ${dtb}"
    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo"

    # Backup antes de qualquer escrita — um extlinux quebrado = Orin sem boot.
    local bak="${EXTLINUX}.canpass.bak.$(date +%Y%m%d-%H%M%S)"
    $sudo cp "$EXTLINUX" "$bak" || { log_error "Falha ao fazer backup de ${EXTLINUX}."; return 1; }
    log_ok "Backup salvo em ${bak}."

    if grep -qE '^[[:space:]]*FDT[[:space:]]' "$EXTLINUX"; then
        # Substitui o caminho na(s) linha(s) FDT existente(s), preservando a indentação.
        $sudo sed -i -E "s|^([[:space:]]*FDT[[:space:]]+).*|\1${dtb}|" "$EXTLINUX"
    else
        # Não havia FDT — insere uma após a linha LINUX (kernel) do primeiro LABEL.
        $sudo sed -i -E "0,/^([[:space:]]*LINUX[[:space:]].*)$/s||\1\n      FDT ${dtb}|" "$EXTLINUX"
    fi

    # Confere que a edição "pegou".
    if grep -qE "^[[:space:]]*FDT[[:space:]]+${dtb//\//\\/}([[:space:]]|$)" "$EXTLINUX"; then
        log_ok "extlinux.conf atualizado para '${cam}'."
    else
        log_error "A edição não foi confirmada — restaurando o backup."
        $sudo cp "$bak" "$EXTLINUX"
        return 1
    fi

    echo
    log_warn "PASSOS FÍSICOS antes de reiniciar:"
    log_warn "  1) Desligue o Orin."
    log_warn "  2) Troque a base board no conector J509:"
    if [[ "$cam" == ecam82 ]]; then
        log_warn "     → base board MIPI da e-CAM82 (cabos IPEX)."
    else
        log_warn "     → placa desserializadora GMSL (e-CAM_CUOAGX_DESER_6H01R1) + coax FAKRA + 12V."
    fi
    log_warn "  3) Ligue de novo. O DTB selecionado entra em vigor no boot."
    echo
    read -rp "$(echo -e "${CYAN}Reiniciar agora? [s/N]:${NC} ")" ans
    if [[ "$ans" =~ ^[sSyY]$ ]]; then
        log_info "Reiniciando..."
        $sudo reboot
    else
        log_info "Reinicie manualmente quando trocar o hardware:  sudo reboot"
    fi
}

# ─── Banner informativo (Table 1 + Flicker + Auto-Exposure) ──────────────────
# Espelha doc/ecam82/README.md — mantenha os dois sincronizados. Os valores de AE
# vêm de 'gst-inspect-1.0 nvarguscamerasrc' e os de WDR/ganho de 'v4l2-ctl
# --list-ctrls' na e-CAM82 (IMX485) deste projeto.
_print_controls_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║   CANPass — Preview local e-CAM82_CUOAGX (IMX485 / Argus → nv3dsink)    ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    cat <<EOF
${BOLD}Table 1 — Maximum Frame Rate Supported (e-CAM82_CUOAGX, AGX Orin/Xavier)${NC}
  Lanes    Resolução      FPS 10-bit   FPS 12-bit
  4-lane   1920 x 1080        90           90        ← setup deste projeto
  4-lane   3840 x 2160        60           50        ← setup deste projeto
  2-lane   1920 x 1080        62           62
  2-lane   3840 x 2160        39           33

${BOLD}Flicker / anti-banding${NC}  (nvarguscamerasrc aeantibanding | env CANPASS_FLICKER)
  0 = Off     1 = Auto(padrão)     2 = 50 Hz     3 = 60 Hz

${BOLD}Auto-exposure & imagem${NC}  (env → propriedade nvarguscamerasrc | faixa)
  CANPASS_FLICKER       aeantibanding         0..3            (padrão 1=Auto)
  CANPASS_EXPOSURECOMP  exposurecompensation  -2.0 .. 2.0     (padrão 0)
  CANPASS_EXPTIME       exposuretimerange     "min max" ns    (ex "34000 33333333")
  CANPASS_GAINRANGE     gainrange             "min max"       (ex "1 16")
  CANPASS_ISPGAIN       ispdigitalgainrange   "min max"       (ex "1 8")
  CANPASS_AELOCK        aelock                true|false      (congela a exposição)
  CANPASS_AWBLOCK       awblock               true|false
  CANPASS_WBMODE        wbmode                0..9            (1=auto,5=daylight,9=manual)
  CANPASS_SATURATION    saturation            0.0 .. 2.0      (padrão 1)
  CANPASS_TNR_MODE      tnr-mode              0..2 (Off/Fast/HQ)
  CANPASS_TNR_STRENGTH  tnr-strength          -1.0 .. 1.0
  CANPASS_EE_MODE       ee-mode               0..2 (Off/Fast/HQ)
  CANPASS_EE_STRENGTH   ee-strength           -1.0 .. 1.0
  CANPASS_AEREGION      aeregion              "left top right bottom peso"
  CANPASS_SENSOR_MODE   sensor-mode           -1..4 (-1 = melhor match)

${BOLD}WDR / HDR e ganho via V4L2${NC}  (driver e-con — aplicado antes do Argus)
  CANPASS_HDR           hdr_enable            0|1             (v4l2-ctl em /dev/video${SENSOR_ID})
  (ref.) gain 0..300 (passo 3) · exposure 450..400000 µs · frame_rate 2.5..60 fps

  Dica "explosão de luz": estreite CANPASS_EXPTIME + CANPASS_GAINRANGE, ou
  CANPASS_AELOCK=true para travar. Detalhes: doc/ecam82/README.md
EOF
    echo
}

# ─── preview (local, nv3dsink) ───────────────────────────────────────────────
# Visualização local no estilo see_cam.sh (menu de resolução → nv3dsink), com
# banner informativo e parâmetros de AE/flicker/WDR ajustáveis por ambiente.
cmd_preview() {
    local cam="${1:-}"

    # Sem argumento: tenta inferir pela câmera ativa no extlinux.
    if [[ -z "$cam" ]]; then
        local cur lbl
        cur=$(grep -m1 -E '^[[:space:]]*FDT[[:space:]]' "$EXTLINUX" 2>/dev/null | awk '{print $2}')
        lbl=$(_dtb_to_camera "${cur:-}")
        case "$lbl" in
            e-CAM82*)  cam=ecam82 ;;
            NileCAM81*) cam=nilecam81 ;;
            *) cam=ecam82; log_warn "Câmera ativa indeterminada — assumindo e-CAM82." ;;
        esac
    fi

    local -a opts=()
    case "$cam" in
        ecam82)    mapfile -t opts < <(_res_options_ecam82) ;;
        nilecam81) mapfile -t opts < <(_res_options_nilecam81) ;;
        *) log_error "Câmera desconhecida: '$cam' (use ecam82 ou nilecam81)."; return 2 ;;
    esac

    _print_controls_banner

    echo -e "${BOLD}${CYAN}Resolução${NC} (Table 1) — câmera: ${cam}, sensor-id=${SENSOR_ID}"
    local i
    for i in "${!opts[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} ${opts[$i]}"
    done
    echo

    local choice sel=""
    while true; do
        read -rp "$(echo -e "${CYAN}Selecione [0–$(( ${#opts[@]} - 1 ))]:${NC} ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice < ${#opts[@]} )); then
            sel="${opts[$choice]}"; break
        fi
        log_warn "Opção inválida."
    done

    # "3840x2160@60  4K UHD" → w/h/fps
    local res="${sel%% *}" w h fps
    IFS='x@' read -r w h fps <<< "$res"
    log_info "Iniciando preview ${w}x${h} @ ${fps} fps (nv3dsink)."

    if [[ -z "${DISPLAY:-}" ]]; then
        export DISPLAY=:0
        log_warn "DISPLAY não definido — assumindo :0. Rode num terminal do desktop do Orin."
    fi

    local sudo=""; [[ $EUID -ne 0 ]] && sudo="sudo"

    # WDR/HDR é controle V4L2 (driver e-con) — aplicado antes de abrir o Argus.
    if [[ -n "${CANPASS_HDR:-}" ]] && command -v v4l2-ctl &>/dev/null; then
        log_info "WDR/HDR: hdr_enable=${CANPASS_HDR} em /dev/video${SENSOR_ID}."
        $sudo -n v4l2-ctl -d "/dev/video${SENSOR_ID}" -c hdr_enable="${CANPASS_HDR}" 2>/dev/null \
            || v4l2-ctl -d "/dev/video${SENSOR_ID}" -c hdr_enable="${CANPASS_HDR}" 2>/dev/null \
            || log_warn "Não foi possível setar hdr_enable (sem permissão ou controle ausente)."
    fi

    # Monta as propriedades do nvarguscamerasrc só com o que o usuário definiu.
    local -a props=( sensor-id="$SENSOR_ID" )
    [[ -n "${CANPASS_SENSOR_MODE:-}" ]]  && props+=( sensor-mode="$CANPASS_SENSOR_MODE" )
    [[ -n "${CANPASS_FLICKER:-}" ]]      && props+=( aeantibanding="$CANPASS_FLICKER" )
    [[ -n "${CANPASS_AELOCK:-}" ]]       && props+=( aelock="$CANPASS_AELOCK" )
    [[ -n "${CANPASS_AWBLOCK:-}" ]]      && props+=( awblock="$CANPASS_AWBLOCK" )
    [[ -n "${CANPASS_WBMODE:-}" ]]       && props+=( wbmode="$CANPASS_WBMODE" )
    [[ -n "${CANPASS_EXPOSURECOMP:-}" ]] && props+=( exposurecompensation="$CANPASS_EXPOSURECOMP" )
    [[ -n "${CANPASS_EXPTIME:-}" ]]      && props+=( exposuretimerange="$CANPASS_EXPTIME" )
    [[ -n "${CANPASS_GAINRANGE:-}" ]]    && props+=( gainrange="$CANPASS_GAINRANGE" )
    [[ -n "${CANPASS_ISPGAIN:-}" ]]      && props+=( ispdigitalgainrange="$CANPASS_ISPGAIN" )
    [[ -n "${CANPASS_SATURATION:-}" ]]   && props+=( saturation="$CANPASS_SATURATION" )
    [[ -n "${CANPASS_TNR_MODE:-}" ]]     && props+=( tnr-mode="$CANPASS_TNR_MODE" )
    [[ -n "${CANPASS_TNR_STRENGTH:-}" ]] && props+=( tnr-strength="$CANPASS_TNR_STRENGTH" )
    [[ -n "${CANPASS_EE_MODE:-}" ]]      && props+=( ee-mode="$CANPASS_EE_MODE" )
    [[ -n "${CANPASS_EE_STRENGTH:-}" ]]  && props+=( ee-strength="$CANPASS_EE_STRENGTH" )
    [[ -n "${CANPASS_AEREGION:-}" ]]     && props+=( aeregion="$CANPASS_AEREGION" )

    # Reinicia o daemon Argus (sessões CSI mal encerradas o deixam inválido).
    $sudo -n systemctl restart nvargus-daemon &>/dev/null && sleep 3

    log_info "Propriedades Argus: ${props[*]}"
    log_info "Janela abrindo no monitor do Orin — pressione Ctrl+C aqui para encerrar."
    gst-launch-1.0 nvarguscamerasrc "${props[@]}" ! \
        "video/x-raw(memory:NVMM),width=${w},height=${h},framerate=${fps}/1,format=NV12" ! \
        nv3dsink sync=false
}

# ─── Uso / dispatch ──────────────────────────────────────────────────────────
usage() {
    cat <<EOF
canpass-camera — alterna e faz preview da câmera do Orin (e-CAM82 ↔ NileCAM81)

  canpass-camera status                      câmera ativa (FDT atual)
  canpass-camera list                        DTBs candidatos em /boot
  canpass-camera switch ecam82|nilecam81     troca o DTB ativo e oferece reboot
  canpass-camera preview [ecam82|nilecam81]  preview local (nv3dsink) com menu de resolução

O 'preview' imprime um banner com Table 1, Flicker e os parâmetros de auto-exposure,
e aceita ajustes por ambiente (CANPASS_FLICKER, CANPASS_EXPTIME, CANPASS_AELOCK, ...).
Referência completa: doc/ecam82/README.md

As duas câmeras NÃO rodam juntas (conector J509 + DTB únicos): é alternar, um por boot.
Detalhes: doc/NileCAM81/COMPATIBILIDADE.md
EOF
}

main() {
    local cmd="${1:-status}"
    shift || true
    case "$cmd" in
        status)        cmd_status "$@" ;;
        list)          cmd_list "$@" ;;
        switch)        cmd_switch "$@" ;;
        preview)       cmd_preview "$@" ;;
        -h|--help|help) usage ;;
        *) log_error "Comando desconhecido: '$cmd'"; echo; usage; return 2 ;;
    esac
}

main "$@"
