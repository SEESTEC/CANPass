#!/usr/bin/env bash
# cam_view.sh — Detecta câmeras V4L2, exibe localmente via ffplay e transmite via RTSP.
# Testado em Ubuntu 22.04 LTS.

set -uo pipefail

# ─── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

# Mata um PID e TODA a sua descendência. Os loops de stream rodam `gst | ffmpeg`
# como FILHOS de um subshell — matar só o subshell (kill $loop_pid) deixava o
# gst/ffmpeg vivos segurando /dev/video* (câmera "não encerrava" no Ctrl+C).
# Recorre nos filhos primeiro (TERM), depois o próprio; um SIGKILL de garantia
# pega quem ignorou o TERM. $1 = PID raiz · $2 = sinal (padrão TERM).
_kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    [[ -n "$pid" ]] || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_tree "$child" "$sig"
    done
    kill -"$sig" "$pid" 2>/dev/null || true
}

# ─── Recuperação da NileCAM81 travada (MCU em -121 / EREMOTEIO) ──────────────
# A NileCAM81 tem um MCU on-board (driver ar0821, I²C-sobre-GMSL). Stream-config
# falho repetido (ex.: o antigo loop de reconexão de 2 s martelando o S_FMT)
# TRAVA o MCU: o ioctl S_FMT passa a retornar EIO/-121 e a câmera só volta com
# reboot OU recarregando o módulo. Esta função tenta o caminho sem-reboot:
# recarrega o ar0821 (que reissua o CHIP reset da desserializadora + re-proba o
# sensor). Rate-limited por lockfile (no --all, vários loops não recarregam
# juntos). Precisa de NOPASSWD p/ 'modprobe ar0821' (configurado pelo install.sh);
# sem isso, só recomenda reboot. Desligue com CANPASS_NO_CAM_RECOVER=1.
_cam_recover_ar0821() {
    local vnode="$1"
    [[ "${CANPASS_NO_CAM_RECOVER:-0}" == "1" ]] && return 1
    lsmod 2>/dev/null | grep -q '^ar0821' || return 1   # só faz sentido p/ a NileCAM81
    local lock="/tmp/canpass_cam_recover.lock" now last
    now=$(date +%s); last=$(cat "$lock" 2>/dev/null || echo 0)
    (( now - last < 60 )) && return 1                    # outro loop já tentou há <60s
    echo "$now" > "$lock"
    log_warn "[cam${vnode}] Câmera travada (-121 = MCU da NileCAM81 sem responder no I²C) — recarregando ar0821..."
    if sudo -n modprobe -r ar0821 2>/dev/null && sudo -n modprobe ar0821 2>/dev/null; then
        local t=0; until [[ -e "/dev/video${vnode}" ]] || (( t >= 12 )); do sleep 1; ((t++)); done
        if [[ -e "/dev/video${vnode}" ]]; then
            log_ok "[cam${vnode}] Módulo ar0821 recarregado — /dev/video${vnode} de volta."
            return 0
        fi
        log_warn "[cam${vnode}] ar0821 recarregado mas /dev/video${vnode} não voltou — REBOOT recomendado."
        return 1
    fi
    log_warn "[cam${vnode}] Não consegui recarregar ar0821 (sem NOPASSWD? rode 'canpass update') — REBOOT é o reset garantido do MCU."
    return 1
}

# ─── FIELD: reboot automático quando a câmera do projeto não enumera ──────────
# Build de CAMPO (CAT D11T teleoperado — desliga geral e acesso físico difícil).
# A NileCAM81 é GMSL e fica presa ao boot via device tree: se o link não subiu na
# partida (MCU travado, 12 V/coax intermitente após o power-cycle do veículo), o
# /dev/video* não aparece e NÃO há hot-plug. Aqui, ao detectar que a câmera do
# projeto está ATIVA no boot mas não enumerou, tentamos re-probar o GMSL e, se
# persistir, REINICIAMOS o Orin — o reset garantido do link.
#
# Proteção contra loop de reboot (essencial num alvo remoto): teto de N reboots
# numa janela de tempo; estourado o teto, DESISTE e segue rodando (preserva
# SSH/NoMachine p/ diagnóstico — cabo solto não vira reboot eterno). O contador
# é persistido em disco (sobrevive ao reboot) e ZERA assim que a câmera volta.
# Operador pode cancelar um reboot em curso: `touch /tmp/canpass_no_reboot`.
#
# Ajustáveis: CANPASS_REBOOT_ON_NO_CAM=0 desliga · CANPASS_MAX_REBOOTS (5) ·
# CANPASS_REBOOT_WINDOW_SECS (1800) · CANPASS_REBOOT_GRACE_SECS (60) ·
# CANPASS_STATE_DIR (~/.canpass).
_field_reboot_state_dir() { echo "${CANPASS_STATE_DIR:-${HOME}/.canpass}"; }

# Dispara o reboot de campo respeitando teto/janela/carência. $1 = nome da câmera.
_field_do_reboot() {
    local active="$1"
    local state_dir; state_dir="$(_field_reboot_state_dir)"
    local cnt_file="${state_dir}/reboot_count"
    mkdir -p "$state_dir" 2>/dev/null
    local max="${CANPASS_MAX_REBOOTS:-5}"
    local window="${CANPASS_REBOOT_WINDOW_SECS:-1800}"
    local grace="${CANPASS_REBOOT_GRACE_SECS:-60}"
    local now count last
    now=$(date +%s); count=0; last=0
    if [[ -f "$cnt_file" ]]; then
        read -r count last < "$cnt_file" 2>/dev/null
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        [[ "$last"  =~ ^[0-9]+$ ]] || last=0
    fi
    # Fora da janela → recomeça a contagem (falha isolada não consome o orçamento antigo).
    (( now - last > window )) && count=0

    if (( count >= max )); then
        log_error "FIELD: ${count} reboots em ${window}s sem recuperar a ${active%% *} — DESISTINDO do reboot p/ manter o acesso remoto (SSH/NoMachine). Verifique coax FAKRA / 12 V / base board. Nova tentativa após a janela expirar."
        return 0
    fi
    if [[ -f /tmp/canpass_no_reboot ]]; then
        log_warn "FIELD: /tmp/canpass_no_reboot presente — reboot CANCELADO por operador."
        return 0
    fi

    log_error "FIELD: câmera não recuperada — REBOOT ${count}/${max} em ${grace}s. Cancele com 'touch /tmp/canpass_no_reboot' ou Ctrl+C."
    local t="$grace"
    while (( t > 0 )); do
        if [[ -f /tmp/canpass_no_reboot ]]; then
            log_warn "FIELD: reboot cancelado por /tmp/canpass_no_reboot."
            return 0
        fi
        sleep 1; ((t--))
    done

    # Só consome o orçamento ao efetivar o reboot (cancelamento não conta).
    echo "$((count+1)) ${now}" > "$cnt_file"
    log_error "FIELD: reiniciando o Orin agora (reboot $((count+1))/${max})."
    sync
    sudo -n systemctl reboot 2>/dev/null || sudo -n reboot 2>/dev/null \
        || sudo -n /sbin/reboot 2>/dev/null \
        || log_error "FIELD: 'reboot' falhou (sem NOPASSWD? rode 'canpass update')."
    sleep 30   # dá tempo do shutdown disparar antes de qualquer continuação
}

# Decide recuperação quando a câmera do projeto está ativa no boot mas sumiu.
# $@ = câmeras detectadas. Retorna: 0 = nada a fazer (câmera presente / desligado);
# 2 = re-probou o GMSL ou abortou o reboot → o chamador deve re-detectar.
_recover_or_reboot_no_cam() {
    [[ "${CANPASS_REBOOT_ON_NO_CAM:-1}" == "1" ]] || return 0
    local active; active="$(_active_csi_camera)"
    [[ -n "$active" ]] || return 0           # sem câmera de projeto no boot (não-Jetson / sem DTB)

    local cam found=0
    for cam in "$@"; do
        [[ "$cam" == csi:* || "$cam" == yuv:* ]] && { found=1; break; }
    done

    local cnt_file; cnt_file="$(_field_reboot_state_dir)/reboot_count"
    if (( found )); then
        if [[ -f "$cnt_file" ]]; then
            rm -f "$cnt_file"
            log_ok "FIELD: ${active%% *} enumerou — contador de reboot zerado."
        fi
        return 0
    fi

    log_warn "FIELD: câmera do projeto (${active}) está ATIVA no boot, mas NÃO enumerou em /dev/video*."

    # 1) Tenta re-probar o link GMSL sem reboot (barato comparado a reiniciar).
    if [[ "${CANPASS_NO_CAM_RECOVER:-0}" != "1" ]] && lsmod 2>/dev/null | grep -Eq '^ar0821|^max96712'; then
        log_warn "FIELD: re-probando o link GMSL (modprobe -r/modprobe ar0821) antes de considerar reboot..."
        if sudo -n modprobe -r ar0821 2>/dev/null && sudo -n modprobe ar0821 2>/dev/null; then
            local t=0; until compgen -G "/dev/video*" >/dev/null || (( t >= 12 )); do sleep 1; ((t++)); done
            if compgen -G "/dev/video*" >/dev/null; then
                log_ok "FIELD: GMSL re-probado — /dev/video* de volta sem reboot."
            else
                log_warn "FIELD: re-probe do ar0821 não trouxe a câmera — partindo p/ reboot."
                _field_do_reboot "$active"
            fi
            return 2   # caller re-detecta de qualquer forma
        fi
        log_warn "FIELD: re-probe falhou (sem NOPASSWD p/ modprobe?)."
    fi

    # 2) Reboot (com teto/janela/carência).
    _field_do_reboot "$active"
    return 2   # só chega aqui se o reboot foi abortado/esgotado → caller re-detecta
}

# ─── Timestamp queimado na gravação (overlay drawtext) ───────────────────────
# Carimba a hora do relógio do sistema em HH:MM:SS.mmm (mesmo formato legível do
# canpass-can log, sem a data), texto branco. Como queimar texto exige modificar
# pixels, a gravação que o usa é REENCODADA (a contínua já reencoda; a por
# movimento passa a reencodar — antes era cópia exata).
#   CANPASS_TS_POSITION  canto: bl=inf-esq (padrão) · br=inf-dir · tl=sup-esq ·
#                        tr=sup-dir · off=sem timestamp (a entrevista define isto)
#   CANPASS_REC_TIMESTAMP=0  também desliga (a por movimento volta a -c copy)
#   CANPASS_TS_FONTSIZE  tamanho da fonte (expr ffmpeg; padrão h/22 = escala c/ a altura)
_TS_FONT_CACHED=""
_ts_fontfile() {
    [[ -n "$_TS_FONT_CACHED" ]] && { echo "$_TS_FONT_CACHED"; return 0; }
    local f
    for f in \
        /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
        /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
        /usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf \
        /usr/share/fonts/truetype/freefont/FreeMono.ttf; do
        [[ -f "$f" ]] && { _TS_FONT_CACHED="$f"; echo "$f"; return 0; }
    done
    f=$(find /usr/share/fonts -name '*.ttf' 2>/dev/null | head -1)
    [[ -n "$f" ]] && { _TS_FONT_CACHED="$f"; echo "$f"; return 0; }
    return 1
}

# Imprime no stdout o filtro -vf do drawtext (ou vazio se desligado/sem fonte).
# %{localtime\:%T} = HH:MM:SS do relógio do sistema; .%{eif...} = milissegundos
# do tempo do stream (PTS real, que já é fiel ao tempo — ver _yuv_stream_loop).
# A posição (canto) vem de CANPASS_TS_POSITION; margem fixa de 14 px da borda.
# Rótulo legível do canto atual do timestamp (p/ os logs de gravação).
_ts_position_label() {
    case "${CANPASS_TS_POSITION:-bl}" in
        br) echo "inferior-direito" ;; tl) echo "superior-esquerdo" ;;
        tr) echo "superior-direito" ;; *)  echo "inferior-esquerdo" ;;
    esac
}

_timestamp_vf() {
    local pos="${CANPASS_TS_POSITION:-bl}"
    [[ "${CANPASS_REC_TIMESTAMP:-1}" == "1" ]] || pos="off"
    [[ "$pos" == "off" ]] && return 0
    local font
    font=$(_ts_fontfile) || return 0
    local fontsize="${CANPASS_TS_FONTSIZE:-h/22}"
    local m=14 x y   # w/h = frame; text_w/text_h = caixa do texto (vars do drawtext)
    case "$pos" in
        tl) x="$m";          y="$m" ;;
        tr) x="w-text_w-$m"; y="$m" ;;
        br) x="w-text_w-$m"; y="h-text_h-$m" ;;
        bl|*) x="$m";        y="h-text_h-$m" ;;
    esac
    printf "drawtext=fontfile=%s:fontcolor=white:fontsize=%s:x=%s:y=%s:box=1:boxcolor=black@0.4:boxborderw=6:text='%%{localtime\\:%%T}.%%{eif\\:mod(t\\,1)*1000\\:d\\:3}'" \
        "$font" "$fontsize" "$x" "$y"
}

# ─── Constantes ──────────────────────────────────────────────────────────────
CONTAINER_NAME="mediamtx"
RTSP_URL="rtsp://localhost:8554/stream"
HLS_PATH="/stream"                             # MediaMTX serve HLS em http://<ip>:8888<HLS_PATH>
MOTION_THRESHOLD="${MOTION_THRESHOLD:-0.02}"   # fração de pixels alterados que caracteriza movimento (0.0–1.0)
MOTION_COOLDOWN_SECS="${MOTION_COOLDOWN_SECS:-30}"  # segundos sem movimento antes de encerrar gravação
_TEMP_IP_ADDR=""   # IP temporário adicionado ao Jetson para alcançar câmera IP
_TEMP_IP_IFACE=""  # Interface onde o IP temporário foi adicionado

# ─── 1. Detecção de câmeras CSI (Jetson/Tegra) ───────────────────────────────
# Câmeras CSI passam pelo ISP e pelo daemon Argus da NVIDIA e só capturam via
# GStreamer (nvarguscamerasrc) — 'ffmpeg -f v4l2' falha nelas (erro "Cannot find
# a proper format" / core dump). Dependendo do driver, elas podem aparecer como
# /dev/video* (caso da e-CAM82/eimx485, que expõe /dev/videoN com driver
# 'tegra-video') OU apenas via /dev/media*. Ambos os casos exigem o caminho CSI:
#   • /dev/videoN com driver tegra-video → csi:N  (sensor-id = N, conforme o guia
#     GStreamer da e-con: "<n> = número do video node").
#   • fallback por CANPASS_CSI_SENSORS quando nenhum /dev/video existe.

# Verdadeiro se a plataforma tem o pipeline Argus (nvarguscamerasrc) disponível.
_has_argus() {
    grep -aqE "nvidia" /proc/device-tree/compatible 2>/dev/null || return 1
    command -v gst-launch-1.0 &>/dev/null || return 1
    gst-inspect-1.0 nvarguscamerasrc &>/dev/null 2>&1
}

# Verdadeiro se /dev/videoN é uma câmera CSI da Tegra (ISP/Argus), não uma webcam
# UVC: driver 'tegra-video' ou bus 'platform:...'. Decide se o nó precisa do
# caminho nvarguscamerasrc em vez do V4L2.
_is_tegra_csi_device() {
    local dev="$1"
    command -v v4l2-ctl &>/dev/null || return 1
    local info driver bus
    info=$(v4l2-ctl --device="$dev" --info 2>/dev/null)
    driver=$(awk -F': ' '/Driver name/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<< "$info")
    bus=$(awk -F': ' '/Bus info/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}' <<< "$info")
    [[ "$driver" == "tegra-video" || "$bus" == platform:* ]]
}

# Verdadeiro se a câmera CSI entrega YUV pronto (UYVY/YUYV/NV16) — ISP ONBOARD,
# caso da NileCAM81 (AR0821). Essas câmeras NÃO passam pelo Argus ('No cameras
# available' no nvarguscamerasrc); capturam por V4L2 direto. As RAW (e-CAM82/
# IMX485) listam só formatos Bayer e seguem pelo Argus.
_is_yuv_direct_device() {
    local dev="$1"
    v4l2-ctl --device="$dev" --list-formats 2>/dev/null | grep -qE "'(UYVY|YUYV|NV16)'"
}

_probe_csi_cameras() {
    _has_argus || return
    # Não abre sessões nvarguscamerasrc aqui — cada probe esgota o daemon e impede
    # o stream subsequente ("No cameras available"). Lista os IDs de CANPASS_CSI_SENSORS
    # (padrão: 0) sem validação; o stream vai confirmar a disponibilidade real.
    local ids="${CANPASS_CSI_SENSORS:-0}"
    local id
    for id in $ids; do
        echo "csi:${id}"
    done
}

# Maximiza os clocks do Jetson (power model, jetson_clocks e, se presente, o script
# max-isp-vi-clks.sh da e-con) para obter o frame rate máximo nas câmeras CSI —
# recomendado pelo guia GStreamer da e-con. Usa sudo -n (regras NOPASSWD do
# install.sh); qualquer falha é não-fatal. Defina CANPASS_NO_CLOCK_BOOST=1 p/ pular.
_boost_jetson_clocks() {
    [[ "${CANPASS_NO_CLOCK_BOOST:-0}" == "1" ]] && return 0
    _has_argus || return 0

    # À prova de travamento: nvpmodel pode PERGUNTAR confirmação no terminal e,
    # com stdout/stderr suprimidos, isso vira um travamento silencioso. Por isso:
    #   • nvpmodel: auto-confirma via 'printf y' (e o pipe garante EOF se não pedir);
    #   • jetson_clocks / script de ISP: stdin de /dev/null (não bloqueiam);
    #   • timeout em todos como rede de segurança final — o boost é opcional e
    #     NUNCA deve segurar o stream.
    if command -v nvpmodel &>/dev/null; then
        if printf 'y\n' | timeout 20 sudo -n nvpmodel -m 0 &>/dev/null; then
            log_ok "Power model em modo máximo (nvpmodel -m 0)."
        else
            log_warn "nvpmodel não aplicado (sem NOPASSWD ou exigiu confirmação) — seguindo."
        fi
    fi

    if command -v jetson_clocks &>/dev/null; then
        timeout 30 sudo -n jetson_clocks </dev/null &>/dev/null \
            && log_ok "Clocks máximos aplicados (jetson_clocks)." \
            || log_warn "jetson_clocks não aplicado — seguindo."
    fi

    # Script de clocks de ISP/VI da e-con, instalado no home do usuário.
    local user_home isp_script
    user_home=$(eval echo "~${SUDO_USER:-$USER}")
    isp_script="${user_home}/max-isp-vi-clks.sh"
    if [[ -x "$isp_script" ]]; then
        timeout 30 sudo -n "$isp_script" </dev/null &>/dev/null \
            && log_ok "Clocks de ISP/VI maximizados (max-isp-vi-clks.sh)." \
            || true
    fi
}

# ─── 2. Verifica sub-rede e configura IP temporário no Jetson se necessário ───
# Câmeras IP saem de fábrica em 192.168.1.x/24. Se nenhuma interface do Jetson
# estiver nessa faixa, o usuário pode atribuir um IP temporário aqui para
# alcançar a câmera sem alterar a configuração permanente da rede.

_check_and_configure_subnet() {
    local cam_ip="$1"
    local cam_prefix
    cam_prefix=$(cut -d. -f1-3 <<< "$cam_ip")

    # Já existe alguma interface na mesma faixa /24?
    if ip -4 addr show 2>/dev/null | grep -q "inet ${cam_prefix}\."; then
        return 0
    fi

    echo
    log_warn "Nenhuma interface de rede está na faixa ${cam_prefix}.0/24 (câmera: ${cam_ip})."
    log_info  "Para comunicar com a câmera, o Jetson precisa de um IP na mesma faixa."
    echo -e "  ${CYAN}Deseja configurar um IP temporário agora? [s/N]:${NC} \c"
    local ans
    read -r ans
    [[ "$ans" =~ ^[sS]$ ]] || return 0

    # Lista interfaces disponíveis (exceto loopback)
    local -a ifaces
    mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    echo
    local i iface cur_ip
    for i in "${!ifaces[@]}"; do
        iface="${ifaces[$i]}"
        cur_ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}')
        echo -e "  ${GREEN}[$i]${NC} ${iface}  ${cur_ip:-(sem IP atribuído)}"
    done
    echo

    local iface_choice
    while true; do
        read -rp "$(echo -e "${CYAN}  Interface para configurar [0–$((${#ifaces[@]}-1))]:${NC} ")" iface_choice
        [[ "$iface_choice" =~ ^[0-9]+$ && "$iface_choice" -lt "${#ifaces[@]}" ]] && break
        log_warn "  Opção inválida."
    done
    local chosen_iface="${ifaces[$iface_choice]}"

    local jetson_ip
    read -rp "$(echo -e "${CYAN}  IP do Jetson na faixa ${cam_prefix}.x (ex: ${cam_prefix}.200):${NC} ")" jetson_ip
    [[ -z "$jetson_ip" ]] && { log_warn "  Nenhum IP informado — continuando sem reconfigurar."; return 0; }

    log_info "Adicionando ${jetson_ip}/24 em ${chosen_iface}..."
    if sudo -n ip addr add "${jetson_ip}/24" dev "${chosen_iface}" 2>/dev/null; then
        log_ok "IP ${jetson_ip}/24 configurado em ${chosen_iface}. Será removido ao encerrar o canpass."
        _TEMP_IP_ADDR="${jetson_ip}/24"
        _TEMP_IP_IFACE="${chosen_iface}"
    else
        log_warn "Falha ao configurar IP (já existe ou permissão insuficiente). Continuando..."
    fi
}

# ─── 3. Coleta dados de câmera IP e monta URL RTSP ───────────────────────────

# Percent-encode (RFC 3986) p/ usuário/senha na URL RTSP — sem isto uma senha com
# '@', ':', '/' ou '#' quebrava o parse (ex.: 'p@ss' virava userinfo ambíguo). Só
# preserva os unreserved [A-Za-z0-9._~-]; o resto vira %XX. LC_ALL=C = byte a byte
# (UTF-8 correto). O ffmpeg decodifica o percent-encoding ao abrir o RTSP.
_urlencode() {
    local LC_ALL=C s="$1" out="" i c
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# ─── Controles de imagem da câmera IP (brilho/WDR/etc. via HTTP API) ─────────
# Análogo aos controles V4L2/Argus das e-con, mas a câmera é REMOTA: os ajustes
# vão pela API HTTP do fabricante (curl), não pelo RTSP (o RTSP só transporta o
# stream). BEST-EFFORT: cada chamada que falhar avisa e SEGUE — parâmetros e
# faixas variam por modelo/firmware; a fonte da verdade é a própria câmera:
#   Hikvision: GET /ISAPI/Image/channels/1/capabilities
#   Intelbras/Dahua: /cgi-bin/configManager.cgi?action=getConfig&name=VideoColor
#   Vivotek: /cgi-bin/admin/getparam.cgi?image_c0
# Reutiliza IP/usuário/senha da entrevista; porta HTTP da API = CANPASS_IPCAM_HTTP_PORT
# (padrão 80). Faixa típica dos níveis = 0..100. Envs por fabricante:
#   CANPASS_HIK_*       BRIGHTNESS CONTRAST SATURATION HUE SHARPNESS (0..100) · WDR (off|0..100)
#   CANPASS_INTELBRAS_* BRIGHTNESS CONTRAST SATURATION HUE SHARPNESS (0..100) · WDR (off|on) · EXTRA (cru)
#   CANPASS_VIVOTEK_*   BRIGHTNESS CONTRAST SATURATION SHARPNESS (0..100) · WDR (off|on) · EXTRA (cru)
_ic_ip="" _ic_user="" _ic_pass="" _ic_hp="80" _ic_ch="1"
_ic_ok()   { log_ok   "  $*"; }
_ic_fail() { log_warn "  $*"; }

# Hikvision — ISAPI PUT (XML). $1=recurso (color/sharpness/WDR) · $2=corpo XML.
_ic_hik_put() {
    local code
    code=$(curl -sS -g --anyauth -u "${_ic_user}:${_ic_pass}" --max-time 6 \
        -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/xml' \
        --data "$2" "http://${_ic_ip}:${_ic_hp}/ISAPI/Image/channels/${_ic_ch}/$1" 2>/dev/null)
    [[ "$code" =~ ^2 ]] && _ic_ok "Hikvision /$1 OK." || _ic_fail "Hikvision /$1 falhou (HTTP ${code:-sem resposta} — modelo/faixa? veja .../capabilities)."
}
_ic_apply_hik() {
    local ns='version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"' body=""
    [[ -n "${CANPASS_HIK_BRIGHTNESS:-}" ]] && body+="<brightnessLevel>${CANPASS_HIK_BRIGHTNESS}</brightnessLevel>"
    [[ -n "${CANPASS_HIK_CONTRAST:-}"   ]] && body+="<contrastLevel>${CANPASS_HIK_CONTRAST}</contrastLevel>"
    [[ -n "${CANPASS_HIK_SATURATION:-}" ]] && body+="<saturationLevel>${CANPASS_HIK_SATURATION}</saturationLevel>"
    [[ -n "${CANPASS_HIK_HUE:-}"        ]] && body+="<hueLevel>${CANPASS_HIK_HUE}</hueLevel>"
    [[ -n "$body" ]] && _ic_hik_put color "<Color ${ns}>${body}</Color>"
    [[ -n "${CANPASS_HIK_SHARPNESS:-}"  ]] && _ic_hik_put sharpness "<Sharpness ${ns}><SharpnessLevel>${CANPASS_HIK_SHARPNESS}</SharpnessLevel></Sharpness>"
    if [[ -n "${CANPASS_HIK_WDR:-}" ]]; then
        local w="${CANPASS_HIK_WDR}" mode lvl=""
        case "${w,,}" in
            off|close|false|no|0) mode=close ;;
            on|open|true|yes)     mode=open ;;
            *) mode=open; [[ "$w" =~ ^[0-9]+$ ]] && lvl="$w" ;;
        esac
        local wb="<mode>${mode}</mode>"; [[ -n "$lvl" ]] && wb+="<WDRLevel>${lvl}</WDRLevel>"
        _ic_hik_put WDR "<WDR ${ns}>${wb}</WDR>"
    fi
}

# Intelbras/Dahua — configManager.cgi setConfig. $1 = query começando com '&'.
_ic_dahua_set() {
    local code resp err=0; resp=$(mktemp /tmp/canpass_ipcam.XXXXXX)
    code=$(curl -sS -g --anyauth -u "${_ic_user}:${_ic_pass}" --max-time 6 \
        -o "$resp" -w '%{http_code}' \
        "http://${_ic_ip}:${_ic_hp}/cgi-bin/configManager.cgi?action=setConfig$1" 2>/dev/null)
    [[ "$code" =~ ^2 ]] || err=1
    grep -qi 'error' "$resp" 2>/dev/null && err=1
    rm -f "$resp"
    (( err == 0 )) && _ic_ok "Intelbras/Dahua: ajustes aplicados." \
        || _ic_fail "Intelbras/Dahua falhou (HTTP ${code:-sem resposta} — modelo/parâmetro? veja getConfig)."
}
_ic_apply_dahua() {
    local q=""
    [[ -n "${CANPASS_INTELBRAS_BRIGHTNESS:-}" ]] && q+="&VideoColor[0][0].Brightness=${CANPASS_INTELBRAS_BRIGHTNESS}"
    [[ -n "${CANPASS_INTELBRAS_CONTRAST:-}"   ]] && q+="&VideoColor[0][0].Contrast=${CANPASS_INTELBRAS_CONTRAST}"
    [[ -n "${CANPASS_INTELBRAS_SATURATION:-}" ]] && q+="&VideoColor[0][0].Saturation=${CANPASS_INTELBRAS_SATURATION}"
    [[ -n "${CANPASS_INTELBRAS_HUE:-}"        ]] && q+="&VideoColor[0][0].Hue=${CANPASS_INTELBRAS_HUE}"
    [[ -n "${CANPASS_INTELBRAS_SHARPNESS:-}"  ]] && q+="&VideoColor[0][0].Sharpness=${CANPASS_INTELBRAS_SHARPNESS}"
    if [[ -n "${CANPASS_INTELBRAS_WDR:-}" ]]; then
        case "${CANPASS_INTELBRAS_WDR,,}" in
            off|close|false|no|0) q+="&VideoInOptions[0].BacklightMode=Off" ;;
            *)                    q+="&VideoInOptions[0].BacklightMode=WDR" ;;
        esac
    fi
    [[ -n "${CANPASS_INTELBRAS_EXTRA:-}" ]] && q+="&${CANPASS_INTELBRAS_EXTRA}"
    [[ -n "$q" ]] && _ic_dahua_set "$q"
}

# Vivotek — setparam.cgi. $1 = query 'a=b&c=d'.
_ic_vivotek_set() {
    local code
    code=$(curl -sS -g --anyauth -u "${_ic_user}:${_ic_pass}" --max-time 6 \
        -o /dev/null -w '%{http_code}' \
        "http://${_ic_ip}:${_ic_hp}/cgi-bin/admin/setparam.cgi?$1" 2>/dev/null)
    [[ "$code" =~ ^2 ]] && _ic_ok "Vivotek: ajustes aplicados." || _ic_fail "Vivotek falhou (HTTP ${code:-sem resposta} — firmware/parâmetro? veja getparam)."
}
_ic_apply_vivotek() {
    local q=""
    [[ -n "${CANPASS_VIVOTEK_BRIGHTNESS:-}" ]] && q+="&image_c0_brightness=${CANPASS_VIVOTEK_BRIGHTNESS}"
    [[ -n "${CANPASS_VIVOTEK_CONTRAST:-}"   ]] && q+="&image_c0_contrast=${CANPASS_VIVOTEK_CONTRAST}"
    [[ -n "${CANPASS_VIVOTEK_SATURATION:-}" ]] && q+="&image_c0_saturation=${CANPASS_VIVOTEK_SATURATION}"
    [[ -n "${CANPASS_VIVOTEK_SHARPNESS:-}"  ]] && q+="&image_c0_sharpness=${CANPASS_VIVOTEK_SHARPNESS}"
    if [[ -n "${CANPASS_VIVOTEK_WDR:-}" ]]; then
        case "${CANPASS_VIVOTEK_WDR,,}" in
            off|false|no|0) q+="&exposure_c0_enablewdrpro=0" ;;
            *)              q+="&exposure_c0_enablewdrpro=1" ;;
        esac
    fi
    [[ -n "${CANPASS_VIVOTEK_EXTRA:-}" ]] && q+="&${CANPASS_VIVOTEK_EXTRA}"
    [[ -n "$q" ]] && _ic_vivotek_set "${q#&}"
}

# Dispara os controles do fabricante se ALGUMA env do grupo estiver definida.
# $1=modelo(1 Intelbras·2 Hik·3 Vivotek·4 manual) $2=ip $3=user $4=pass.
_apply_ipcam_controls() {
    local model="$1"
    _ic_ip="$2"; _ic_user="$3"; _ic_pass="$4"
    _ic_hp="${CANPASS_IPCAM_HTTP_PORT:-80}"; _ic_ch="${CANPASS_HIK_CHANNEL:-1}"
    local prefix
    case "$model" in 1) prefix=INTELBRAS ;; 2) prefix=HIK ;; 3) prefix=VIVOTEK ;; *) return 0 ;; esac
    local any=0 k name
    for k in BRIGHTNESS CONTRAST SATURATION HUE SHARPNESS WDR EXTRA; do
        name="CANPASS_${prefix}_${k}"; [[ -n "${!name:-}" ]] && any=1
    done
    (( any )) || return 0
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "  Controles de imagem definidos, mas 'curl' ausente — pulando (apt-get install curl)."
        return 0
    fi
    log_info "  Aplicando controles de imagem (${prefix}) via HTTP API (porta ${_ic_hp})..."
    case "$model" in 1) _ic_apply_dahua ;; 2) _ic_apply_hik ;; 3) _ic_apply_vivotek ;; esac
}

# Pergunta o MODELO e monta o caminho RTSP conforme o fabricante. Todos os prompts
# vão p/ stderr (>&2) — o stdout carrega só "ip:<url>" capturado pelo chamador.
# Caminhos por fabricante (verificados):
#   Intelbras (Dahua OEM): /cam/realmonitor?channel=<N>&subtype=<0 main|1 sub>
#   Hikvision:             /Streaming/Channels/<canal><stream 01 main|02 sub>  (ex.: 101)
#   Vivotek (media2):      /media2/stream.sdp?profile=<token>                  (ex.: profile1)
_prompt_ip_camera() {
    local model ip port path user pass url channel stream subtype profile ans
    echo >&2
    echo -e "${CYAN}  Modelo da câmera IP:${NC}" >&2
    echo -e "    ${GREEN}[1]${NC} Intelbras (Dahua OEM)" >&2
    echo -e "    ${GREEN}[2]${NC} Hikvision" >&2
    echo -e "    ${GREEN}[3]${NC} Vivotek" >&2
    echo -e "    ${GREEN}[4]${NC} Outra / caminho manual" >&2
    read -rp "$(echo -e "${CYAN}  Modelo [1-4] (padrão 1):${NC} ")" model
    model="${model:-1}"

    read -rp "$(echo -e "${CYAN}  IP da câmera:${NC} ")" ip
    [[ -z "$ip" ]] && return 1
    _check_and_configure_subnet "$ip" >&2

    read -rp "$(echo -e "${CYAN}  Porta RTSP [554]:${NC} ")" port
    port="${port:-554}"

    case "$model" in
        2)  # Hikvision
            read -rp "$(echo -e "${CYAN}  Canal [1]:${NC} ")" channel
            channel="${channel:-1}"
            echo -e "${CYAN}  Stream: ${NC}[1] Principal (main)  [2] Secundário (sub)" >&2
            read -rp "$(echo -e "${CYAN}  Stream [1/2] (padrão 1):${NC} ")" ans
            [[ "$ans" == "2" ]] && stream="02" || stream="01"
            path="/Streaming/Channels/${channel}${stream}"
            ;;
        3)  # Vivotek (media2)
            read -rp "$(echo -e "${CYAN}  Profile/token [profile1]:${NC} ")" profile
            profile="${profile:-profile1}"
            path="/media2/stream.sdp?profile=${profile}"
            ;;
        4)  # Manual
            read -rp "$(echo -e "${CYAN}  Caminho do stream [/]:${NC} ")" path
            path="${path:-/}"
            [[ "$path" != /* ]] && path="/${path}"
            ;;
        *)  # Intelbras (Dahua OEM) — padrão
            read -rp "$(echo -e "${CYAN}  Canal [1]:${NC} ")" channel
            channel="${channel:-1}"
            echo -e "${CYAN}  Stream: ${NC}[1] Principal  [2] Secundário" >&2
            read -rp "$(echo -e "${CYAN}  Stream [1/2] (padrão 1):${NC} ")" ans
            [[ "$ans" == "2" ]] && subtype=1 || subtype=0
            path="/cam/realmonitor?channel=${channel}&subtype=${subtype}"
            ;;
    esac

    read -rp "$(echo -e "${CYAN}  Usuário (Enter para nenhum):${NC} ")" user

    if [[ -n "$user" ]]; then
        read -rsp "$(echo -e "${CYAN}  Senha:${NC} ")" pass
        echo >&2
        url="rtsp://$(_urlencode "$user"):$(_urlencode "$pass")@${ip}:${port}${path}"
    else
        url="rtsp://${ip}:${port}${path}"
    fi

    # Controles de imagem (brilho/WDR/etc.) via HTTP API, se houver envs do grupo.
    # Saída p/ stderr — o stdout carrega só "ip:<url>".
    _apply_ipcam_controls "$model" "$ip" "${user:-}" "${pass:-}" >&2

    echo "ip:${url}"
}

# Entrevista para N câmeras IP (modo --all): pergunta a quantidade e roda
# _prompt_ip_camera em loop, somando ao conjunto multi-câmera. Emite uma linha
# "ip:<url>" por câmera no stdout; todos os prompts/mensagens vão p/ stderr
# (o chamador captura só o stdout via mapfile).
_prompt_ip_cameras_multi() {
    local n i url
    echo >&2
    read -rp "$(echo -e "${CYAN}Adicionar câmeras IP ao modo --all? Quantas (Enter=0):${NC} ")" n
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    for (( i=1; i<=n; i++ )); do
        echo -e "${CYAN}  ── Câmera IP ${i}/${n} ──${NC}" >&2
        url=$(_prompt_ip_camera) || { log_warn "Câmera IP ${i} não configurada — pulando." >&2; continue; }
        [[ -n "$url" ]] && echo "$url"
    done
}

# ─── 3. Inicia container MediaMTX (servidor RTSP/WebRTC) ─────────────────────

ensure_mediamtx() {
    local docker_test
    docker_test=$(docker ps 2>&1)
    if echo "$docker_test" | grep -q "permission denied"; then
        log_error "Sem permissão para acessar o Docker daemon."
        log_info  "Adicione seu usuário ao grupo docker e reinicie o terminal:"
        log_info  "  sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    fi

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        # Verifica se está rodando com --network host; reinicia se não estiver
        local net_mode
        net_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$net_mode" == "host" ]]; then
            log_ok "Container '${CONTAINER_NAME}' já está em execução."
            return 0
        fi
        log_warn "Container '${CONTAINER_NAME}' em modo de rede '${net_mode}' — reiniciando com --network host..."
        docker stop "$CONTAINER_NAME" &>/dev/null
        sleep 1
    fi

    log_info "Iniciando container MediaMTX..."
    docker run -d --rm --name "$CONTAINER_NAME" \
        --network host \
        -e MTX_HLSVARIANT=lowLatency \
        -e MTX_HLSSEGMENTDURATION=200ms \
        -e MTX_HLSPARTDURATION=50ms \
        bluenviron/mediamtx

    sleep 2

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_ok "MediaMTX iniciado."
    else
        log_error "Falha ao iniciar o container MediaMTX. Abortando."
        exit 1
    fi
}

# ─── 3. Detecta câmeras V4L2 e CSI ──────────────────────────────────────────
# Filtra apenas dispositivos de *captura* (não outputs de loopback/renderização).
# Em Jetson sem câmera USB, recorre ao probe CSI via GStreamer/Argus.

detect_cameras() {
    local -a cams=()

    for dev in /dev/video*; do
        [[ -c "$dev" && -r "$dev" ]] || continue

        if command -v v4l2-ctl &>/dev/null; then
            v4l2-ctl --device="$dev" --all 2>/dev/null \
                | grep -qi "Video Capture" || continue
            v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
                | grep -q "\[0\]" || continue
        fi

        # Câmera CSI da Tegra: aparece como /dev/videoN, mas o caminho depende do
        # tipo — YUV/ISP-onboard (NileCAM81) → V4L2 direto (yuv:N); RAW (e-CAM82/
        # eimx485) → Argus (csi:N, sensor-id = N).
        if _is_tegra_csi_device "$dev"; then
            if _is_yuv_direct_device "$dev"; then
                cams+=("yuv:${dev#/dev/video}")
            elif _has_argus; then
                cams+=("csi:${dev#/dev/video}")
            else
                log_warn "Câmera CSI em ${dev} detectada, mas nvarguscamerasrc/GStreamer indisponível — pulando." >&2
            fi
            continue
        fi

        cams+=("$dev")
    done

    # Nenhum /dev/video — tenta CSI por CANPASS_CSI_SENSORS (Jetson/Tegra)
    if [[ ${#cams[@]} -eq 0 ]]; then
        while IFS= read -r csi; do
            cams+=("$csi")
        done < <(_probe_csi_cameras)
    fi

    [[ ${#cams[@]} -gt 0 ]] && printf '%s\n' "${cams[@]}"
}

# ─── 4. Nome amigável da câmera ───────────────────────────────────────────────

# Identifica QUAL câmera do projeto está ativa neste boot (e-CAM82 ↔ NileCAM81 —
# elas dividem o conector J509 e o device tree, então é sempre UMA por boot).
# Fontes, na ordem: módulo de kernel carregado (eimx485/ar0821 — reflete o que
# realmente probou) → linha FDT do extlinux (DTB fixado pelo canpass-camera switch).
# Sai vazio se indeterminado (ex.: não-Jetson).
_active_csi_camera() {
    if lsmod 2>/dev/null | grep -q '^eimx485'; then
        echo "e-CAM82_CUOAGX (IMX485, MIPI)"; return
    fi
    if lsmod 2>/dev/null | grep -Eq '^ar0821|^max96712'; then
        echo "NileCAM81_CUOAGX (GMSL/AR0821)"; return
    fi
    local fdt
    fdt=$(grep -m1 -E '^[[:space:]]*FDT[[:space:]]' /boot/extlinux/extlinux.conf 2>/dev/null \
          | awk '{print tolower($2)}')
    case "$fdt" in
        *imx485*|*ecam82*|*e-cam82*)       echo "e-CAM82_CUOAGX (IMX485, MIPI)" ;;
        *nilecam*|*ar0821*|*0821*|*96712*) echo "NileCAM81_CUOAGX (GMSL/AR0821)" ;;
    esac
}

camera_label() {
    local dev="$1"
    if [[ "$dev" == csi:* ]]; then
        local cam
        cam=$(_active_csi_camera)
        echo "${cam:-CSI Camera} — Jetson sensor-id ${dev#csi:}"
        return
    fi
    if [[ "$dev" == yuv:* ]]; then
        local cam
        cam=$(_active_csi_camera)
        echo "${cam:-Câmera YUV} — /dev/video${dev#yuv:} (ISP onboard, V4L2)"
        return
    fi
    if [[ "$dev" == ip:* ]]; then
        local display_url
        display_url=$(sed 's|rtsp://[^:]*:[^@]*@|rtsp://***:***@|' <<< "${dev#ip:}")
        echo "Câmera IP — ${display_url}"
        return
    fi
    if command -v v4l2-ctl &>/dev/null; then
        local name
        name=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
               | awk -F': ' '/Card type/{gsub(/^[[:space:]]+/,"",$2); print $2}')
        [[ -n "$name" ]] && echo "$name" && return
    fi
    echo "$dev"
}

# ─── 5. Captura e transmite via RTSP (exibição local opcional com --display) ──
# ffmpeg: lê o dispositivo V4L2 e envia stream H.264 ao MediaMTX (background)
# ffplay: consome o stream RTSP para exibição local — apenas com flag --display
#
# Flags de captura:
#   -probesize 32768     ~32 KB — mínimo viável para timestamps estáveis
#   -analyzeduration 0   elimina janela de análise (padrão: 5 s)
#   -fflags nobuffer     desativa buffer do demuxer
#   -flags low_delay     modo low-delay no decoder
#
# Encoding:
#   -preset ultrafast / -tune zerolatency   H.264 de baixa latência
#   -pix_fmt yuv420p                        garante compatibilidade com navegadores e players
#   -g 6 / -keyint_min 6 / -sc_threshold 0     GOP fixo de 6 frames (200 ms @ 30 fps),
#                                               alinhado ao segmento HLS; sem keyframes extras
#                                               por cena (o principal causador de latência alta)
#   -flush_packets 1                        força flush de cada pacote codificado imediatamente
#
# Saída RTSP:
#   -muxdelay 0 / -muxpreload 0             zera buffer interno do muxer RTSP
#
# Exibição local:
#   -sync video          sincroniza pelo relógio de vídeo
#   SDL_RENDER_VSYNC=1   sincroniza com o refresh do monitor (evita tearing)

# ─── 5a. Pipeline CSI → MediaMTX (compartilhado single/--all) ─────────────────
# Captura via nvarguscamerasrc e publica H.264 no MediaMTX, com reconexão.
# $1 = sensor-id · $2 = URL RTSP de saída. Respeita CANPASS_CSI_RES/BITRATE/ENCODER.
# CANPASS_NO_DAEMON_RESTART=1 (modo --all): no retry de "No cameras available" NÃO
# reinicia o nvargus-daemon — isso derrubaria as sessões das outras câmeras.
_csi_stream_loop() {
    local sensor_id="$1" out_url="$2"
    local res="${CANPASS_CSI_RES:-1920x1080@30}"
    local csi_w csi_h csi_fps
    IFS='x@' read -r csi_w csi_h csi_fps <<< "$res"
    local csi_bitrate="${CANPASS_CSI_BITRATE:-8000000}"
    local csi_use_hw=0
    [[ "${CANPASS_CSI_ENCODER:-auto}" != "sw" ]] && gst-inspect-1.0 nvv4l2h264enc &>/dev/null && csi_use_hw=1
    # Mesmos parâmetros de baixa latência do ENCODE de show_camera (x264 software).
    local -a SW_ENCODE=(
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
        -g 2 -keyint_min 2 -sc_threshold 0 -flush_packets 1
    )

    local csi_log="/tmp/canpass_csi_${sensor_id}.log"
    local nvargus_retries=0
    while true; do
        : > "$csi_log"  # limpa a cada tentativa para checar apenas o erro atual
        if (( csi_use_hw )); then
            gst-launch-1.0 -q \
                nvarguscamerasrc sensor-id="$sensor_id" ! \
                "video/x-raw(memory:NVMM),width=${csi_w},height=${csi_h},framerate=${csi_fps}/1,format=NV12" ! \
                nvv4l2h264enc maxperf-enable=1 control-rate=1 bitrate="${csi_bitrate}" \
                    insert-sps-pps=1 iframeinterval="${csi_fps}" idrinterval="${csi_fps}" ! \
                h264parse ! fdsink fd=1 2>>"$csi_log" | \
            ffmpeg -loglevel warning \
                -fflags nobuffer -flags low_delay -analyzeduration 0 -probesize 32768 \
                -r "${csi_fps}" -f h264 -i pipe:0 \
                -c:v copy -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$out_url" 2>>"$csi_log"
        else
            gst-launch-1.0 -q \
                nvarguscamerasrc sensor-id="$sensor_id" ! \
                "video/x-raw(memory:NVMM),width=${csi_w},height=${csi_h},framerate=${csi_fps}/1,format=NV12" ! \
                nvvidconv ! "video/x-raw,format=I420" ! \
                fdsink fd=1 2>>"$csi_log" | \
            ffmpeg -loglevel warning \
                -f rawvideo -pix_fmt yuv420p \
                -s "${csi_w}x${csi_h}" -r "${csi_fps}" \
                -fflags nobuffer -flags low_delay -analyzeduration 0 \
                -i pipe:0 \
                "${SW_ENCODE[@]}" -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$out_url" 2>>"$csi_log"
        fi
        local gst_rc=${PIPESTATUS[0]} ffmpeg_rc=${PIPESTATUS[1]}
        (( gst_rc >= 128 || ffmpeg_rc >= 128 )) && return
        # Daemon nvargus não encontrou a câmera — pode ser problema de timing;
        # tenta de novo antes de desistir (reiniciando o daemon só no modo single).
        if grep -q "No cameras available" "$csi_log" 2>/dev/null; then
            if (( nvargus_retries++ < 2 )); then
                if [[ "${CANPASS_NO_DAEMON_RESTART:-0}" == "1" ]]; then
                    log_warn "[cam${sensor_id}] nvargus sem a câmera — nova tentativa em 5s (${nvargus_retries}/2)..."
                else
                    log_warn "Daemon nvargus não encontrou a câmera — reiniciando (tentativa ${nvargus_retries}/2)..."
                    sudo -n systemctl restart nvargus-daemon 2>/dev/null
                fi
                sleep 5
                continue
            fi
            log_error "[cam${sensor_id}] Câmera CSI inacessível pelo daemon nvargus."
            log_info  "Verifique a conexão física da câmera e execute canpass novamente."
            return 1
        fi
        nvargus_retries=0
        log_warn "[cam${sensor_id}] Stream CSI encerrado (gst=${gst_rc} ffmpeg=${ffmpeg_rc}) — reconectando em 2s... (log: ${csi_log})"
        sleep 2
    done
}

# ─── 5a-bis. Pipeline YUV/V4L2 → MediaMTX (NileCAM81 e afins) ─────────────────
# Câmeras CSI com ISP ONBOARD (saída UYVY): captura por V4L2, sem Argus/nvargus.
# Preferência: nvv4l2camerasrc (NVMM, zero-copy) → nvvidconv → NVENC; fallback
# v4l2src. Caps SEM framerate — a NileCAM81 só anuncia 60 fps (720p/1080p) e
# 16 fps (4K), então deixamos negociar (o fps de CANPASS_CSI_RES vira só o hint
# do ffmpeg/encoder). $1 = nº do /dev/videoN · $2 = URL RTSP de saída.
_yuv_stream_loop() {
    local vnode="$1" out_url="$2"
    local res="${CANPASS_CSI_RES:-1920x1080@60}"
    local w h fps
    IFS='x@' read -r w h fps <<< "$res"
    local bitrate="${CANPASS_CSI_BITRATE:-8000000}"
    local use_hw=0
    [[ "${CANPASS_CSI_ENCODER:-auto}" != "sw" ]] && gst-inspect-1.0 nvv4l2h264enc &>/dev/null && use_hw=1
    local -a src
    if gst-inspect-1.0 nvv4l2camerasrc &>/dev/null; then
        src=( nvv4l2camerasrc device="/dev/video${vnode}" !
              "video/x-raw(memory:NVMM),format=UYVY,width=${w},height=${h}" !
              nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" )
    else
        src=( v4l2src device="/dev/video${vnode}" !
              "video/x-raw,format=UYVY,width=${w},height=${h}" !
              nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" )
    fi
    local -a SW_ENCODE=(
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
        -g 2 -keyint_min 2 -sc_threshold 0 -flush_packets 1
    )

    local ylog="/tmp/canpass_yuv_${vnode}.log"
    local wedge_count=0   # falhas consecutivas de negociação (câmera travada)
    while true; do
        : > "$ylog"
        # Formato pré-fixado: o nvv4l2camerasrc herda o formato corrente do nó
        # (um preview anterior pode ter deixado outra resolução) e não renegocia
        # direito — sintoma: 'NvBufSurfaceCopy: buffer size mismatch' / tela verde.
        # FPS: alinha o frame_rate_control ao pedido (o padrão do driver é 30 e
        # PERSISTE) e lê de volta o aceito — usado p/ GOP do encoder e p/ avisar
        # divergência. A fidelidade temporal NÃO depende mais dele: os PTS reais
        # de captura viajam no MPEG-TS (ver pipeline abaixo).
        if command -v v4l2-ctl &>/dev/null; then
            v4l2-ctl -d "/dev/video${vnode}" --set-fmt-video="width=${w},height=${h},pixelformat=UYVY" 2>/dev/null
            v4l2-ctl -d "/dev/video${vnode}" -c frame_rate_control="${fps}" 2>/dev/null
            local real_fps
            real_fps=$(v4l2-ctl -d "/dev/video${vnode}" --get-ctrl frame_rate_control 2>/dev/null \
                       | awk -F': *' '/frame_rate_control/{print $2}')
            [[ -z "$real_fps" ]] && real_fps=$(v4l2-ctl -d "/dev/video${vnode}" --get-parm 2>/dev/null \
                       | sed -n 's/.*(\([0-9][0-9]*\)\/1).*/\1/p')
            if [[ "$real_fps" =~ ^[0-9]+$ && "$real_fps" -gt 0 && "$real_fps" != "$fps" ]]; then
                log_warn "[cam${vnode}] Câmera reporta ${real_fps} fps (pedido: ${fps})."
                fps="$real_fps"
            fi
        fi
        if (( use_hw )) && gst-inspect-1.0 mpegtsmux &>/dev/null; then
            # FIDELIDADE TEMPORAL fim-a-fim: H.264 cru não carrega timestamps e
            # qualquer '-r' nominal no ffmpeg vira aposta (a câmera pode entregar
            # OUTRO fps — ex.: modos HDR reduzem a taxa real sem refletir no
            # controle). Solução definitiva: o gst estampa cada frame com o
            # relógio REAL de captura e o mpegtsmux TRANSPORTA esses PTS pelo
            # pipe — o ffmpeg só repassa (-c copy), sem assumir fps nenhum.
            gst-launch-1.0 -q "${src[@]}" ! \
                nvv4l2h264enc maxperf-enable=1 control-rate=1 bitrate="${bitrate}" \
                    insert-sps-pps=1 iframeinterval="${fps}" idrinterval="${fps}" ! \
                h264parse config-interval=-1 ! mpegtsmux alignment=7 ! \
                fdsink fd=1 2>>"$ylog" | \
            ffmpeg -loglevel warning \
                -flags low_delay -analyzeduration 1000000 -probesize 262144 \
                -f mpegts -i pipe:0 \
                -c:v copy -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$out_url" 2>>"$ylog"
        elif (( use_hw )); then
            # mpegtsmux ausente — legado: H.264 cru estampado com o fps lido do
            # driver (menos robusto que os PTS reais, mas melhor que o nominal).
            log_warn "[cam${vnode}] mpegtsmux indisponível — usando fps nominal ${fps} (instale gst-plugins-bad)."
            gst-launch-1.0 -q "${src[@]}" ! \
                nvv4l2h264enc maxperf-enable=1 control-rate=1 bitrate="${bitrate}" \
                    insert-sps-pps=1 iframeinterval="${fps}" idrinterval="${fps}" ! \
                h264parse ! fdsink fd=1 2>>"$ylog" | \
            ffmpeg -loglevel warning \
                -fflags nobuffer -flags low_delay -analyzeduration 0 -probesize 32768 \
                -r "${fps}" -f h264 -i pipe:0 \
                -c:v copy -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$out_url" 2>>"$ylog"
        else
            # Caminho por software (raro): rawvideo não carrega PTS — estampa
            # pelo RELÓGIO DE CHEGADA (wallclock), fiel ao tempo real mesmo se
            # o fps real divergir do nominal.
            gst-launch-1.0 -q "${src[@]}" ! \
                nvvidconv ! "video/x-raw,format=I420" ! \
                fdsink fd=1 2>>"$ylog" | \
            ffmpeg -loglevel warning \
                -f rawvideo -pix_fmt yuv420p \
                -s "${w}x${h}" -r "${fps}" \
                -use_wallclock_as_timestamps 1 \
                -fflags nobuffer -flags low_delay -analyzeduration 0 \
                -i pipe:0 \
                "${SW_ENCODE[@]}" -vsync vfr -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$out_url" 2>>"$ylog"
        fi
        local gst_rc=${PIPESTATUS[0]} ffmpeg_rc=${PIPESTATUS[1]}
        (( gst_rc >= 128 || ffmpeg_rc >= 128 )) && return
        # Assinatura de câmera TRAVADA (NileCAM81: MCU não responde no I²C/GMSL):
        # S_FMT falha com EIO / not-negotiated / -121. Diferente de uma queda
        # transitória — aqui reconectar a cada 2s só MANTÉM o MCU travado. Conta
        # falhas consecutivas, faz backoff e tenta recuperar recarregando o ar0821.
        if grep -qiE 'S_FMT failed|VIDIOC_S_FMT|not-negotiated|ret = -121|Input/output error' "$ylog"; then
            (( wedge_count++ ))
            log_warn "[cam${vnode}] Stream YUV não negocia — câmera travada? (gst=${gst_rc} ffmpeg=${ffmpeg_rc}, falha ${wedge_count}; log: ${ylog})"
            (( wedge_count == 2 )) && _cam_recover_ar0821 "$vnode"   # tenta destravar sem reboot
            # 4+ falhas e o reload do ar0821 não resolveu → o nó /dev/video existe
            # mas o MCU não negocia (-121): detect_cameras vê a câmera como "presente"
            # e o reboot de boot NÃO dispara. Escalamos aqui p/ o reboot de campo —
            # mesma proteção de teto/janela/carência e só reinicia se for a câmera do
            # projeto. É o único reset garantido do MCU travado.
            (( wedge_count >= 4 )) && {
                log_warn "[cam${vnode}] Câmera segue sem negociar — escalando p/ REBOOT de campo (reset garantido do MCU -121)."
                _field_do_reboot "$(_active_csi_camera)"
            }
            local backoff=$(( wedge_count * 3 )); (( backoff > 30 )) && backoff=30
            sleep "$backoff"   # backoff progressivo: para de martelar o MCU
        else
            wedge_count=0
            log_warn "[cam${vnode}] Stream YUV encerrado (gst=${gst_rc} ffmpeg=${ffmpeg_rc}) — reconectando em 2s... (log: ${ylog})"
            sleep 2
        fi
    done
}

# ─── 5a-bis. Câmera IP (RTSP) → MediaMTX (compartilhado single/--all) ─────────
# Republica o RTSP da câmera no MediaMTX, com probe inicial (diagnostica 401/404)
# e loop de reconexão. $1 = id (sufixo de path/log) · $2 = RTSP de entrada da
# câmera · $3 = URL RTSP de saída no MediaMTX · $4 = prefixo das mensagens
# (default "[camID] "; o single passa "" p/ log limpo, sem prefixo).
# Por padrão republica SEM reencode (-c copy): a câmera IP já entrega H.264/H.265,
# então copiar poupa CPU — essencial para várias IPs ao mesmo tempo no --all.
# CANPASS_IP_ENCODE=1 força reencode x264 (use se a câmera mandar codec que o
# MediaMTX/gravador não aceitam em cópia).
_ip_stream_loop() {
    local id="$1" rtsp_in="$2" out_url="$3"
    local tag="${4-[cam${id}] }"   # unset → prefixo padrão; "" explícito → sem prefixo (single)
    local err_log="/tmp/canpass_ip_${id}.log"
    # -stimeout: timeout de I/O do socket TCP (µs). SEM ele, num blip de rede da
    # câmera (visto em campo: Hik/Vivotek "No route to host" intermitente) o ffmpeg
    # FICA PENDURADO conectado-mas-sem-dados, o MediaMTX expira o path (404) e a
    # gravação congela p/ sempre. Com timeout, o ffmpeg SAI no stall → o loop de
    # reconexão abaixo religa e a gravação volta sozinha. Padrão 5 s.
    local stimeout_us="${CANPASS_IP_STIMEOUT_US:-5000000}"
    local -a IN=( -probesize 32768 -analyzeduration 0 -fflags nobuffer -flags low_delay
                  -stimeout "$stimeout_us" )
    # SÓ vídeo (-map 0:v): câmeras IP costumam mandar áudio pcm_mulaw + stream de
    # dados (ONVIF). Em -c copy, pcm_mulaw NÃO entra em MP4 ("codec not supported
    # in container") e zera a gravação; o projeto é vídeo + CAN, áudio não importa.
    local -a OUT
    if [[ "${CANPASS_IP_ENCODE:-0}" == "1" ]]; then
        OUT=( -map 0:v -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
              -g 2 -keyint_min 2 -sc_threshold 0 -flush_packets 1 )
    else
        OUT=( -map 0:v -c copy )   # republicação direta, sem reencode (poupa CPU)
    fi

    # Erros DEFINITIVOS de configuração (não adianta repetir): path/credencial.
    # Retorna 1 (desiste) só nesses; qualquer outra falha é TRANSITÓRIA e o loop
    # abaixo segue tentando. ANTES um simples "No route to host" no boot (rede/alias
    # ainda subindo, ou a câmera ainda bootando) fazia o probe desistir P/ SEMPRE —
    # a câmera nunca era republicada e o gravador girava à toa sem nada p/ gravar.
    _ip_fatal_err() {
        if grep -q "404 Not Found" "$err_log"; then
            cat "$err_log" >&2
            log_error "${tag}Path RTSP não encontrado na câmera (404). Reinicie e informe o path correto (opção [4] manual)."
            log_info  "Paths comuns por fabricante:"
            log_info  "  Intelbras: /cam/realmonitor?channel=1&subtype=0 (principal) · subtype=1 (secundário)"
            log_info  "  Hikvision: /Streaming/Channels/101 (canal 1 principal) · 102 (secundário)"
            log_info  "  Vivotek:   /live.sdp · /live1s2.sdp · /media2/stream.sdp?profile=profile1 (ONVIF Media2)"
            return 0
        fi
        if grep -q "401 Unauthorized" "$err_log"; then
            cat "$err_log" >&2
            log_error "${tag}Câmera recusou autenticação (401) — verifique usuário e senha."
            return 0
        fi
        return 1
    }

    # Loop ÚNICO de conexão+reconexão: NUNCA desiste por falha transitória (câmera
    # ausente no boot, blip de rede). Republica continuamente; o gravador associado
    # passa a capturar assim que o stream aparece no MediaMTX. Backoff cresce só
    # enquanto a câmera está inacessível (2→4→…→15s) e ZERA quando ela conecta.
    log_info "${tag}Conectando à câmera IP (aguarde)..."
    local announced=0 backoff=2
    while true; do
        : > "$err_log"
        ffmpeg -loglevel error -rtsp_transport tcp "${IN[@]}" \
            -i "$rtsp_in" "${OUT[@]}" -muxdelay 0 -muxpreload 0 \
            -rtsp_transport tcp -f rtsp "$out_url" 2>"$err_log" &
        local fpid=$! i alive=1
        # Observa ~4s p/ saber se conectou (sem matar — segue publicando se vivo).
        for i in 1 2 3 4; do
            sleep 1
            kill -0 "$fpid" 2>/dev/null || { alive=0; break; }
        done
        if (( alive )); then
            if (( announced == 0 )); then
                log_ok "${tag}Câmera IP conectada — stream disponível no MediaMTX."
                announced=1
            fi
            backoff=2
            wait "$fpid"; local rc=$?
        else
            wait "$fpid"; local rc=$?
        fi
        _ip_fatal_err && return 1
        (( rc >= 128 )) && return            # encerrado por sinal (cleanup do chamador)
        if (( alive )); then
            log_warn "${tag}Stream IP caiu (código ${rc}) — reconectando em 2s..."
            sleep 2
        else
            cat "$err_log" >&2
            log_warn "${tag}Câmera IP inacessível — nova tentativa em ${backoff}s (câmera ligada? rede?)."
            sleep "$backoff"
            (( backoff = backoff < 15 ? backoff * 2 : 15 ))
        fi
    done
}

# ─── FIELD: disco externo como destino padrão de gravação ────────────────────
# Em campo o vídeo deve cair num disco REMOVÍVEL (pendrive/SSD USB), não na eMMC
# do Orin (pequena e que viaja junto com a máquina). _find_external_mount procura
# o PRIMEIRO disco externo montado e gravável; _resolve_rec_dir devolve o destino
# final. Precedência: CANPASS_REC_DIR explícito > primeiro disco externo > local
# (~/canpass_rec). Sem disco externo NÃO trava a gravação — cai no local.
# Externo = removível OU hotplug (USB), montado, gravável e FORA do disco da raiz.
# Desligue a busca com CANPASS_REC_EXTERNAL=0.
_find_external_mount() {
    [[ "${CANPASS_REC_EXTERNAL:-1}" == "1" ]] || return 1
    command -v lsblk >/dev/null 2>&1 || return 1

    # Disco-pai da raiz (a NUNCA usar) — p/ excluir todas as suas partições.
    local root_src root_disk
    root_src=$(findmnt -no SOURCE / 2>/dev/null)
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    [[ -z "$root_disk" ]] && root_disk=$(basename "${root_src:-}" 2>/dev/null)

    local line NAME MOUNTPOINT RM HOTPLUG TYPE PKNAME
    while IFS= read -r line; do
        NAME=""; MOUNTPOINT=""; RM=""; HOTPLUG=""; TYPE=""; PKNAME=""
        eval "$line" 2>/dev/null || continue
        [[ "$TYPE" == "part" || "$TYPE" == "disk" ]] || continue
        [[ -n "$MOUNTPOINT" ]] || continue                       # precisa estar montado
        case "$MOUNTPOINT" in                                    # ignora montagens de sistema
            /|/boot|/boot/*|/home|/var|/var/*|/usr|/usr/*|/efi|/snap/*) continue;;
        esac
        # exclui qualquer partição do disco da raiz
        [[ -n "$root_disk" && ( "$NAME" == "$root_disk" || "$PKNAME" == "$root_disk" ) ]] && continue
        [[ "$RM" == "1" || "$HOTPLUG" == "1" ]] || continue      # só disco externo de verdade
        [[ -w "$MOUNTPOINT" ]] || continue                       # precisa ser gravável
        echo "$MOUNTPOINT"; return 0
    done < <(lsblk -P -o NAME,MOUNTPOINT,RM,HOTPLUG,TYPE,PKNAME 2>/dev/null)
    return 1
}

# Resolve o diretório de gravação aplicando a precedência acima.
_resolve_rec_dir() {
    if [[ -n "${CANPASS_REC_DIR:-}" ]]; then
        echo "$CANPASS_REC_DIR"; return 0
    fi
    local ext
    if ext=$(_find_external_mount); then
        echo "${ext%/}/canpass_rec"; return 0
    fi
    echo "${HOME}/canpass_rec"
}

# FALLBACK + GUARDA DE ESPAÇO de campo: devolve um destino gravável AGORA E com
# margem de espaço. Tenta o preferido (_resolve_rec_dir — disco externo /
# CANPASS_REC_DIR); se não dá p/ escrever (disco externo removido a quente) OU
# está sem a margem livre, cai no CANPASS_REC_DIR_FALLBACK (interno). Se NENHUM
# destino tem a margem (CANPASS_MIN_FREE_MB, padrão 8192 = 8 GB livres p/ o Orin),
# ecoa VAZIO → o gravador PAUSA (não enche o disco). Os gravadores chamam isto a
# cada (re)início → migra sozinho entre externo↔interno e retoma quando libera.
# Saída capturada via $(); avisos vão p/ stderr p/ não poluir o caminho.
_rec_dir_now() {
    local tag="${1:-}"
    local min_mb="${CANPASS_MIN_FREE_MB:-8192}"
    local flag="/tmp/canpass_rec_fallback" sflag="/tmp/canpass_rec_nospace"
    local pref fb d free_mb
    pref="$(_resolve_rec_dir)"
    fb="${CANPASS_REC_DIR_FALLBACK:-${HOME}/canpass_rec}"
    for d in "$pref" "$fb"; do
        [[ -n "$d" ]] || continue
        mkdir -p "$d" 2>/dev/null || continue
        touch "${d}/.canpass_wtest" 2>/dev/null || continue
        rm -f "${d}/.canpass_wtest"
        free_mb=$(df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}')
        [[ "$free_mb" =~ ^[0-9]+$ ]] || continue
        (( free_mb >= min_mb )) || continue
        [[ -f "$sflag" ]] && rm -f "$sflag"
        if [[ "$d" == "$pref" ]]; then
            [[ -f "$flag" ]] && { log_ok "${tag}Destino ${d} de volta — retomando a gravação nele." >&2; rm -f "$flag"; }
        else
            [[ -f "$flag" ]] || { log_warn "${tag}Destino ${pref} indisponível/cheio — gravando no fallback ${fb}." >&2; : > "$flag"; }
        fi
        echo "$d"; return 0
    done
    # Nenhum destino gravável com a margem → pausa a gravação (protege o Orin).
    if [[ ! -f "$sflag" ]]; then
        log_warn "${tag}Sem armazenamento com a margem de ${min_mb}MB livres — gravação PAUSADA até liberar/repor disco." >&2
        : > "$sflag"
    fi
    echo ""
}

# ─── 5b. Gravação por detecção de movimento (modo 'motion') ──────────────────
# Um dos dois modos de gravação (ver _record_loop). Lê o RTSP indicado, emite
# scene-scores (filtro select) e controla um ffmpeg recorder (-c copy → MP4 =
# cópia EXATA do stream, máxima qualidade). $1 = URL RTSP · $2 = prefixo de
# arquivo/log ("" no modo single — nomes inalterados; "camN_" no --all). Com '&'.
_motion_loop() {
    local src_url="$1" prefix="${2:-}"
    local tag=""; [[ -n "$prefix" ]] && tag="[${prefix%_}] "
    local rec_dir; rec_dir="$(_rec_dir_now "$tag")"

    local motion_active=0
    local last_motion_epoch=0
    local recorder_pid=""
    local recording_start_ts=""
    local recording_tmp_file=""
    # Overlay de timestamp (uma vez por loop): se ativo, a gravação reencoda com
    # o relógio queimado; se vazio, mantém a cópia exata (-c copy) de antes.
    local ts_vf; ts_vf=$(_timestamp_vf)
    [[ -n "$ts_vf" ]] && log_info "${tag}Timestamp na gravação ativo (reencode); CANPASS_REC_TIMESTAMP=0 desliga."

    _ml_start_recording() {
        recording_start_ts=$(date +"%d-%m-%Y_%H-%M-%S")
        recording_tmp_file="${rec_dir}/.rec_${prefix}${recording_start_ts}.mp4"
        if [[ -n "$ts_vf" ]]; then
            ffmpeg -loglevel error \
                -fflags nobuffer -analyzeduration 0 -probesize 32768 \
                -rtsp_transport tcp \
                -i "$src_url" \
                -vf "$ts_vf" \
                -c:v libx264 -preset veryfast -crf "${CANPASS_MOTION_CRF:-18}" -pix_fmt yuv420p -an \
                "$recording_tmp_file" 2>/dev/null &
        else
            ffmpeg -loglevel error \
                -fflags nobuffer -analyzeduration 0 -probesize 32768 \
                -rtsp_transport tcp \
                -i "$src_url" \
                -c copy \
                "$recording_tmp_file" 2>/dev/null &
        fi
        recorder_pid=$!
        log_info "${tag}Movimento detectado — gravando: ${recording_start_ts}"
    }

    _ml_stop_recording() {
        [[ -z "$recorder_pid" ]] && return
        kill "$recorder_pid" 2>/dev/null
        wait "$recorder_pid" 2>/dev/null
        local recording_end_ts
        recording_end_ts=$(date +"%H-%M-%S")
        local final_filename="${rec_dir}/${prefix}${recording_start_ts}_${recording_end_ts}.mp4"
        [[ -f "$recording_tmp_file" ]] && mv "$recording_tmp_file" "$final_filename"
        log_info "${tag}Sem movimento — arquivo salvo: $(basename "$final_filename")"
        recorder_pid=""
        recording_start_ts=""
        recording_tmp_file=""
    }

    sleep 5  # aguarda o stream estabilizar no MediaMTX (IP cameras precisam de mais tempo)

    # Loop externo: reinicia o detector se ele cair (ex: stream não estava
    # pronto no MediaMTX quando o detector conectou). É encerrado pelo SIGTERM
    # do cleanup do chamador.
    while true; do
        motion_active=0
        last_motion_epoch=0
        rec_dir="$(_rec_dir_now "$tag")"   # re-resolve: migra p/ o fallback se o disco externo sumir
        [[ -z "$rec_dir" ]] && { sleep 15; continue; }   # sem espaço → pausa a gravação

        # Lê scores de cena do ffmpeg — produz saída apenas quando há movimento.
        # read -t COOLDOWN: expira se nenhum frame de movimento chegar no intervalo.
        while true; do
            local line="" read_status
            IFS= read -r -t "${MOTION_COOLDOWN_SECS}" line
            read_status=$?
            local now
            now=$(date +%s)

            if (( read_status == 0 )); then
                if [[ "$line" =~ lavfi\.scene_score=([0-9.eE+\-]+) ]]; then
                    local scene_score="${BASH_REMATCH[1]}"
                    if awk "BEGIN{exit !($scene_score > ${MOTION_THRESHOLD})}"; then
                        last_motion_epoch=$now
                        if [[ $motion_active -eq 0 ]]; then
                            motion_active=1
                            _ml_start_recording
                        fi
                    fi
                fi
            elif (( read_status == 1 )); then
                break  # EOF — detector encerrado, sai do loop interno
            fi
            if [[ $motion_active -eq 1 ]] && (( now - last_motion_epoch >= MOTION_COOLDOWN_SECS )); then
                motion_active=0
                _ml_stop_recording
            fi

        done < <(
            ffmpeg -loglevel info \
                -rtsp_transport tcp \
                -i "$src_url" \
                -vf "select=gt(scene\,${MOTION_THRESHOLD}),metadata=print:key=lavfi.scene_score" \
                -f null /dev/null 2>&1 | grep --line-buffered "lavfi.scene_score"
        )

        # EOF: encerra gravação em curso e aguarda antes de reiniciar o detector
        [[ $motion_active -eq 1 ]] && _ml_stop_recording
        sleep 5
    done
}

# ─── 5b-bis. Gravação CONTÍNUA (modo 'continuous') ───────────────────────────
# Grava o RTSP sem parar, recomprimindo em H.264 (libx264, CRF) — arquivos bem
# menores que a cópia do stream, com perda visual mínima (CRF ~21 ≈ transparente;
# ajuste via CANPASS_CONT_CRF). Saída segmentada (CANPASS_CONT_SEGMENT_SECS,
# padrão 600 s) em MP4 FRAGMENTADO: uma queda de energia corrompe no máximo o
# segmento corrente — e mesmo ele continua abrindo no player.
# $1 = URL RTSP · $2 = prefixo ("" single / "camN_" no --all). Chame com '&'.
_continuous_loop() {
    local src_url="$1" prefix="${2:-}"
    local tag=""; [[ -n "$prefix" ]] && tag="[${prefix%_}] "
    local crf="${CANPASS_CONT_CRF:-21}"
    local seg="${CANPASS_CONT_SEGMENT_SECS:-600}"
    # Overlay de timestamp (já reencoda neste modo → custo zero adicional além do filtro).
    local ts_vf; ts_vf=$(_timestamp_vf)
    local -a vfargs=(); [[ -n "$ts_vf" ]] && vfargs=(-vf "$ts_vf")

    local fpid=""
    trap '[[ -n "$fpid" ]] && kill "$fpid" 2>/dev/null; exit 0' INT TERM

    local rec_dir; rec_dir="$(_rec_dir_now "$tag")"
    log_info "${tag}Gravação contínua: x264 CRF ${crf}, segmentos de $(( seg / 60 )) min → ${rec_dir}"
    [[ -n "$ts_vf" ]] && log_info "${tag}Timestamp na gravação ativo (HH:MM:SS.mmm, canto $(_ts_position_label))."
    while true; do
        rec_dir="$(_rec_dir_now "$tag")"   # re-resolve a cada ciclo: migra p/ o fallback se o disco externo sumir
        [[ -z "$rec_dir" ]] && { sleep 15; continue; }   # sem espaço → pausa a gravação
        # espera o stream publicar no MediaMTX (evita spam de reconexão do ffmpeg)
        until ffprobe -v quiet -rtsp_transport tcp -i "$src_url" >/dev/null 2>&1; do
            sleep 2
        done
        # -force_key_frames: o segment muxer só corta em keyframe — sem isso o
        # keyint padrão do x264 (250 frames) atrasa/impede o corte no tempo certo.
        ffmpeg -loglevel error \
            -rtsp_transport tcp \
            -i "$src_url" \
            "${vfargs[@]}" \
            -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p -an \
            -force_key_frames "expr:gte(t,n_forced*${seg})" \
            -f segment -segment_time "$seg" -reset_timestamps 1 -strftime 1 \
            -segment_format_options "movflags=+frag_keyframe+empty_moov+default_base_moof" \
            "${rec_dir}/${prefix}cont_%d-%m-%Y_%H-%M-%S.mp4" 2>/dev/null &
        fpid=$!
        wait "$fpid"
        local rc=$?
        fpid=""
        (( rc >= 128 )) && return
        log_warn "${tag}Gravador contínuo encerrou (código ${rc}) — reiniciando em 5s..."
        sleep 5
    done
}

# Despacha para o gravador conforme CANPASS_REC_MODE (definido pela entrevista
# do watchdog): 'continuous' = sempre gravando (recomprimido) · 'motion' (padrão)
# = só com movimento (cópia exata). Mesma assinatura dos dois loops.
_record_loop() {
    if [[ "${CANPASS_REC_MODE:-motion}" == "continuous" ]]; then
        _continuous_loop "$@"
    else
        _motion_loop "$@"
    fi
}

# Linha-resumo do modo de gravação para os banners de status.
_record_mode_label() {
    if [[ "${CANPASS_REC_MODE:-motion}" == "continuous" ]]; then
        echo "contínuo: x264 CRF ${CANPASS_CONT_CRF:-21}, segmentos de $(( ${CANPASS_CONT_SEGMENT_SECS:-600} / 60 )) min"
    else
        echo "movimento: threshold=${MOTION_THRESHOLD}, cooldown=${MOTION_COOLDOWN_SECS}s"
    fi
}

show_camera() {
    local dev="$1"
    local display="${2:-}"
    local loop_pid=""

    ensure_mediamtx

    local -a BASE=(
        -probesize 32768
        -analyzeduration 0
        -fflags nobuffer
        -flags low_delay
    )
    local -a ENCODE=(
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
        -g 2 -keyint_min 2 -sc_threshold 0
        -flush_packets 1
    )

    # ── Inicia captura: YUV/V4L2 (ISP onboard), CSI (Argus) ou V4L2 (USB) ──────
    if [[ "$dev" == yuv:* ]]; then
        local vnode="${dev#yuv:}"
        local yres="${CANPASS_CSI_RES:-1920x1080@60}"
        log_info "Stream YUV/V4L2 (ISP onboard): /dev/video${vnode}, ${yres} — sem Argus."
        log_info "Log de erros: /tmp/canpass_yuv_${vnode}.log"
        _boost_jetson_clocks
        _ffmpeg_loop() { _yuv_stream_loop "$vnode" "$RTSP_URL"; }
    elif [[ "$dev" == csi:* ]]; then
        local sensor_id="${dev#csi:}"

        # Resolução configurável via CANPASS_CSI_RES="WxH@FPS" (padrão: 1920x1080@30).
        # Probes de resolução com nvarguscamerasrc foram removidas — cada probe abre uma
        # sessão no daemon nvargus e impede o stream de iniciar ("No cameras available").
        local res="${CANPASS_CSI_RES:-1920x1080@30}"
        local csi_w csi_h csi_fps
        IFS='x@' read -r csi_w csi_h csi_fps <<< "$res"
        log_info "Stream CSI: sensor-id=${sensor_id}, ${csi_w}x${csi_h} @ ${csi_fps} fps"

        # Maximiza clocks (CPU/GPU/ISP/VI) para frame rate máximo (recomendado pela e-con).
        _boost_jetson_clocks

        # Reinicia o nvargus-daemon para garantir estado limpo antes de abrir a sessão.
        # Sessões encerradas abruptamente (Ctrl+C, testes anteriores) deixam o daemon
        # incapaz de aceitar novas conexões. sudo -n usa a regra NOPASSWD do install.sh.
        if sudo -n systemctl restart nvargus-daemon 2>/dev/null; then
            log_ok "Daemon nvargus reiniciado."
            sleep 5
        fi

        # Encoder CSI: prefere o H.264 por HARDWARE (NVENC, nvv4l2h264enc) do Jetson
        # — latência e uso de CPU muito menores que o x264 por software. Em L4T 35.2.1
        # o nvv4l2h264enc é estável. Fallback automático p/ software se o elemento não
        # existir; force com CANPASS_CSI_ENCODER=sw|hw. Bitrate via CANPASS_CSI_BITRATE.
        if [[ "${CANPASS_CSI_ENCODER:-auto}" != "sw" ]] && gst-inspect-1.0 nvv4l2h264enc &>/dev/null; then
            log_info "Encoder CSI: hardware (nvv4l2h264enc, ${CANPASS_CSI_BITRATE:-8000000} bps)."
        else
            log_info "Encoder CSI: software (libx264)."
        fi
        log_info "Log de erros CSI: /tmp/canpass_csi_${sensor_id}.log"

        # Pipeline + loop de reconexão compartilhados com o modo --all (seção 5a).
        _ffmpeg_loop() { _csi_stream_loop "$sensor_id" "$RTSP_URL"; }
    elif [[ "$dev" == ip:* ]]; then
        # ── IP (RTSP): republica o stream da câmera (ver _ip_stream_loop) ─────
        local rtsp_in="${dev#ip:}"
        local display_url
        display_url=$(sed 's|rtsp://[^:]*:[^@]*@|rtsp://***:***@|' <<< "$rtsp_in")
        log_info "Stream IP: ${display_url}"
        _ffmpeg_loop() { _ip_stream_loop "stream" "$rtsp_in" "$RTSP_URL" ""; }
    else
        # ── V4L2: proba formato de entrada funcional ──────────────────────────
        local working_args=""
        local attempt_label=""
        for args_str in \
            "-f v4l2 -input_format mjpeg -framerate 30 -video_size 1280x720" \
            "-f v4l2 -framerate 30 -video_size 1280x720" \
            "-f v4l2"
        do
            [[ -n "$attempt_label" ]] && log_warn "Formato '${attempt_label}' indisponível — tentando próximo..."
            attempt_label="$args_str"

            read -ra probe_args <<< "$args_str"
            ffmpeg -loglevel error "${BASE[@]}" "${probe_args[@]}" -i "$dev" \
                "${ENCODE[@]}" -muxdelay 0 -muxpreload 0 -rtsp_transport tcp -f rtsp "$RTSP_URL" &
            local probe_pid=$!

            sleep 2
            if kill -0 "$probe_pid" 2>/dev/null; then
                kill "$probe_pid" 2>/dev/null
                wait "$probe_pid" 2>/dev/null
                working_args="$args_str"
                break
            fi
        done

        if [[ -z "$working_args" ]]; then
            log_error "Não foi possível iniciar o stream para ${dev}. Abortando."
            return 1
        fi

        _ffmpeg_loop() {
            local -a input_args
            read -ra input_args <<< "$working_args"
            while true; do
                ffmpeg -loglevel error "${BASE[@]}" "${input_args[@]}" -i "$dev" \
                    "${ENCODE[@]}" -muxdelay 0 -muxpreload 0 -rtsp_transport tcp -f rtsp "$RTSP_URL" 2>/dev/null
                local rc=$?
                (( rc >= 128 )) && return
                log_warn "Stream encerrado (código ${rc}) — reconectando em 2s..."
                sleep 2
            done
        }
    fi

    _ffmpeg_loop &
    loop_pid=$!

    # ── Gravação (contínua ou por movimento — CANPASS_REC_MODE) ──────────────
    # 'motion' (padrão): ffmpeg detector → select filter (scene score) → máquina
    # de estados → ffmpeg recorder (-c copy → MP4, cópia exata).
    # 'continuous': ffmpeg único reencodando (x264 CRF) em segmentos MP4.

    local rec_dir; rec_dir="$(_rec_dir_now)"; [[ -z "$rec_dir" ]] && rec_dir="(pausado: sem espaço livre)"

    # Gravador compartilhado com o modo --all (seções 5b/5b-bis); prefixo
    # vazio mantém os nomes de arquivo do modo single inalterados.
    _record_loop "$RTSP_URL" "" &
    local motion_rec_pid=$!

    # Encerra os loops ao sair (Q, Ctrl+C ou término normal).
    # Remove o IP temporário adicionado para câmera IP, se houver.
    cleanup() {
        # Guarda com :- porque o trap EXIT pode disparar fora do escopo de
        # show_camera (ex.: após um return antecipado), quando os locais já
        # não existem — sem isso, `set -u` aborta com "unbound variable".
        # _kill_tree (não um kill simples): o loop roda `gst | ffmpeg` como
        # filhos — matar só o subshell deixava o gst/ffmpeg segurando a câmera.
        _kill_tree "${loop_pid:-}"
        _kill_tree "${motion_rec_pid:-}"
        if [[ -n "$_TEMP_IP_ADDR" && -n "$_TEMP_IP_IFACE" ]]; then
            sudo -n ip addr del "$_TEMP_IP_ADDR" dev "$_TEMP_IP_IFACE" 2>/dev/null \
                && log_info "IP temporário ${_TEMP_IP_ADDR} removido de ${_TEMP_IP_IFACE}."
        fi
    }
    trap cleanup EXIT INT TERM

    # Aguarda o stream ficar disponível no MediaMTX antes de exibir as URLs.
    # GStreamer + nvargus levam alguns segundos para publicar o primeiro frame;
    # imprimir as URLs antes disso faz o cliente receber "stream not found".
    # A cada iteração verifica se _ffmpeg_loop ainda está vivo: se morreu (erro
    # de câmera) sai imediatamente sem imprimir URLs enganosas.
    log_info "Aguardando stream ficar disponível..."
    local _probe_t=0
    until ffprobe -v quiet -rtsp_transport tcp -i "$RTSP_URL" >/dev/null 2>&1; do
        if ! kill -0 "$loop_pid" 2>/dev/null; then
            wait "$loop_pid" 2>/dev/null
            trap - EXIT INT TERM
            cleanup
            return 1
        fi
        sleep 1
        (( _probe_t++ ))
        if (( _probe_t >= 30 )); then
            log_warn "Stream não confirmado após 30s — verifique o log CSI em /tmp/canpass_csi_0.log"
            break
        fi
    done
    if ! kill -0 "$loop_pid" 2>/dev/null; then
        wait "$loop_pid" 2>/dev/null
        trap - EXIT INT TERM
        cleanup
        return 1
    fi

    echo
    log_ok "Stream RTSP:   ${RTSP_URL}"
    while IFS= read -r iface_line; do
        local iface iface_ip
        iface=$(awk '{print $1}' <<< "$iface_line")
        iface_ip=$(awk '{print $2}' <<< "$iface_line" | cut -d/ -f1)
        log_ok "Stream WebRTC  [${iface}]:  http://${iface_ip}:8889${HLS_PATH}  (~100 ms)"
        log_ok "Stream HLS     [${iface}]:  http://${iface_ip}:8888${HLS_PATH}  (~200 ms)"
    done < <(ip -4 -o addr show | awk '$2 != "lo" {print $2, $4}')
    log_ok "Gravando em:   ${rec_dir}  ($(_record_mode_label))"
    if [[ "$display" == "--display" ]]; then
        log_info "Iniciando visualização local — pressione Q para sair."
        echo
        SDL_RENDER_VSYNC=1 ffplay \
            -probesize 32 \
            -analyzeduration 0 \
            -fflags nobuffer+discardcorrupt \
            -flags low_delay \
            -avioflags direct \
            -sync video \
            -loglevel warning \
            "$RTSP_URL"
    else
        log_info "Stream ativo em background. Pressione Ctrl+C para encerrar."
        wait "$loop_pid"
    fi

    trap - EXIT INT TERM
    cleanup
}

# ─── 6. Modo MULTI-CÂMERA (--all): um stream por câmera CSI ──────────────────
# Publica cada câmera num path próprio do MediaMTX:
#   RTSP rtsp://<ip>:8554/camN · WebRTC http://<ip>:8889/camN · HLS :8888/camN
# + gravação por movimento POR CÂMERA (arquivos camN_<início>_<fim>.mp4).
# Com --display, abre uma janela ffplay por stream.
show_all_cameras() {
    local display="$1"; shift
    local -a cams=("$@")

    ensure_mediamtx
    _boost_jetson_clocks

    # Reinicia o daemon UMA vez, antes de abrir todas as sessões — jamais durante
    # (derrubaria as sessões vizinhas; ver CANPASS_NO_DAEMON_RESTART). Só é
    # necessário se houver câmera Argus (csi:*); as YUV/V4L2 não usam o daemon.
    if [[ " ${cams[*]} " == *" csi:"* ]] && sudo -n systemctl restart nvargus-daemon 2>/dev/null; then
        log_ok "Daemon nvargus reiniciado."
        sleep 5
    fi

    local res="${CANPASS_CSI_RES:-1920x1080@30}"
    log_info "Modo multi-câmera: ${#cams[@]} stream(s) @ ${res} cada."
    log_info "(ajuste com CANPASS_CSI_RES — 4 streams em 4K estouram o NVENC; 1080p é o equilíbrio)"

    local -a pids=() rec_pids=() play_pids=() sids=()
    local cam sid ip_n=0
    for cam in "${cams[@]}"; do
        if [[ "$cam" == ip:* ]]; then
            # IP não tem /dev/videoN — usa id sintético (ip0, ip1...) como token.
            sid="ip${ip_n}"; ip_n=$((ip_n+1))
            sids+=("$sid")
            _ip_stream_loop "$sid" "${cam#ip:}" "rtsp://localhost:8554/cam${sid}" &
        elif [[ "$cam" == yuv:* ]]; then
            sid="${cam#*:}"
            sids+=("$sid")
            _yuv_stream_loop "$sid" "rtsp://localhost:8554/cam${sid}" &
        else
            sid="${cam#*:}"
            sids+=("$sid")
            CANPASS_NO_DAEMON_RESTART=1 _csi_stream_loop "$sid" "rtsp://localhost:8554/cam${sid}" &
        fi
        pids+=($!)
    done

    local rec_dir; rec_dir="$(_rec_dir_now)"; [[ -z "$rec_dir" ]] && rec_dir="(pausado: sem espaço livre)"
    for sid in "${sids[@]}"; do
        _record_loop "rtsp://localhost:8554/cam${sid}" "cam${sid}_" &
        rec_pids+=($!)
    done

    _all_cleanup() {
        local p
        for p in "${play_pids[@]:-}" "${rec_pids[@]:-}" "${pids[@]:-}"; do
            _kill_tree "$p"   # mata gst/ffmpeg filhos, não só o subshell
        done
    }
    trap _all_cleanup EXIT INT TERM

    # Aguarda cada stream publicar no MediaMTX antes de imprimir as URLs
    # (até 30 s por câmera; as seguintes confirmam rápido, o daemon já está quente).
    log_info "Aguardando streams ficarem disponíveis..."
    local ok=0 t
    for sid in "${sids[@]}"; do
        t=0
        until ffprobe -v quiet -rtsp_transport tcp -i "rtsp://localhost:8554/cam${sid}" >/dev/null 2>&1; do
            sleep 1
            t=$((t+1))
            (( t >= 30 )) && break
        done
        if ffprobe -v quiet -rtsp_transport tcp -i "rtsp://localhost:8554/cam${sid}" >/dev/null 2>&1; then
            ok=$((ok+1))
            log_ok "cam${sid} publicando."
        else
            log_warn "cam${sid} não confirmou em 30s — veja /tmp/canpass_*_${sid}.log"
        fi
    done
    if (( ok == 0 )); then
        log_error "Nenhum stream subiu. Encerrando."
        trap - EXIT INT TERM
        _all_cleanup
        return 1
    fi

    echo
    while IFS= read -r iface_line; do
        local iface iface_ip
        iface=$(awk '{print $1}' <<< "$iface_line")
        iface_ip=$(awk '{print $2}' <<< "$iface_line" | cut -d/ -f1)
        log_ok "[${iface}] por câmera N:  rtsp://${iface_ip}:8554/camN  ·  http://${iface_ip}:8889/camN (WebRTC)  ·  http://${iface_ip}:8888/camN (HLS)"
        for sid in "${sids[@]}"; do
            log_ok "  cam${sid}:  http://${iface_ip}:8889/cam${sid}"
        done
    done < <(ip -4 -o addr show | awk '$2 != "lo" {print $2, $4}')
    log_ok "Gravando em: ${rec_dir} — arquivos camN_*.mp4 por câmera ($(_record_mode_label))"

    if [[ "$display" == "--display" ]]; then
        log_info "Abrindo uma janela ffplay por stream — Ctrl+C aqui encerra tudo."
        for sid in "${sids[@]}"; do
            SDL_RENDER_VSYNC=1 ffplay \
                -probesize 32 -analyzeduration 0 \
                -fflags nobuffer+discardcorrupt -flags low_delay -avioflags direct \
                -sync video -loglevel warning \
                -window_title "CANPass cam${sid}" \
                "rtsp://localhost:8554/cam${sid}" &>/dev/null &
            play_pids+=($!)
        done
    fi

    log_info "Streams ativos em background. Pressione Ctrl+C para encerrar."
    wait "${pids[@]}"
    trap - EXIT INT TERM
    _all_cleanup
}

# ─── Preview LOCAL no monitor do Orin (--local) ──────────────────────────────
# Mostra a câmera direto na tela do Orin, sem rede/encode/gravação — menor latência
# possível. CSI: nvarguscamerasrc → nv3dsink (pipeline oficial da e-con). USB/IP: ffplay.
# Resolução/FPS via CANPASS_CSI_RES (padrão local: 1920x1080@60, mais fluido).

show_local() {
    local dev="$1"

    if [[ -z "${DISPLAY:-}" ]]; then
        export DISPLAY=:0
        log_warn "DISPLAY não definido — assumindo :0. Rode num terminal do desktop do Orin."
    fi

    _local_cleanup() {
        if [[ -n "${_TEMP_IP_ADDR:-}" && -n "${_TEMP_IP_IFACE:-}" ]]; then
            sudo -n ip addr del "$_TEMP_IP_ADDR" dev "$_TEMP_IP_IFACE" 2>/dev/null
        fi
    }
    trap _local_cleanup EXIT INT TERM

    if [[ "$dev" == yuv:* ]]; then
        local vnode="${dev#yuv:}"
        local res="${CANPASS_CSI_RES:-1920x1080@60}"
        local y_w y_h y_fps
        IFS='x@' read -r y_w y_h y_fps <<< "$res"
        log_info "Preview local YUV/V4L2 (ISP onboard): /dev/video${vnode}, ${y_w}x${y_h} (nv3dsink)."
        _boost_jetson_clocks
        # Formato + fps reais pré-fixados (evita tela verde por formato herdado
        # e fps divergente do pedido — ver _yuv_stream_loop).
        if command -v v4l2-ctl &>/dev/null; then
            v4l2-ctl -d "/dev/video${vnode}" --set-fmt-video="width=${y_w},height=${y_h},pixelformat=UYVY" 2>/dev/null
            v4l2-ctl -d "/dev/video${vnode}" -c frame_rate_control="${y_fps}" 2>/dev/null
        fi
        log_info "Janela abrindo no monitor do Orin — pressione Ctrl+C aqui para encerrar."
        # Caps NV12 NVMM explícitos após o nvvidconv — sem eles a negociação com
        # o nv3dsink falha ("not-negotiated": passthrough UYVY NVMM não aceito).
        if gst-inspect-1.0 nvv4l2camerasrc &>/dev/null; then
            gst-launch-1.0 -q \
                nvv4l2camerasrc device="/dev/video${vnode}" ! \
                "video/x-raw(memory:NVMM),format=UYVY,width=${y_w},height=${y_h}" ! \
                nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" ! \
                nv3dsink sync=false
        else
            gst-launch-1.0 -q \
                v4l2src device="/dev/video${vnode}" ! \
                "video/x-raw,format=UYVY,width=${y_w},height=${y_h}" ! \
                nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" ! \
                nv3dsink sync=false
        fi
    elif [[ "$dev" == csi:* ]]; then
        local sensor_id="${dev#csi:}"
        local res="${CANPASS_CSI_RES:-1920x1080@60}"
        local csi_w csi_h csi_fps
        IFS='x@' read -r csi_w csi_h csi_fps <<< "$res"
        log_info "Preview local CSI: sensor-id=${sensor_id}, ${csi_w}x${csi_h} @ ${csi_fps} fps (nv3dsink)."
        _boost_jetson_clocks
        sudo -n systemctl restart nvargus-daemon &>/dev/null && sleep 3
        log_info "Janela abrindo no monitor do Orin — pressione Ctrl+C aqui para encerrar."
        gst-launch-1.0 -q \
            nvarguscamerasrc sensor-id="$sensor_id" ! \
            "video/x-raw(memory:NVMM),width=${csi_w},height=${csi_h},framerate=${csi_fps}/1,format=NV12" ! \
            nv3dsink sync=false
    elif [[ "$dev" == ip:* ]]; then
        local rtsp_in="${dev#ip:}"
        log_info "Preview local da câmera IP (ffplay) — pressione Q para sair."
        ffplay -rtsp_transport tcp -fflags nobuffer -flags low_delay -loglevel warning "$rtsp_in"
    else
        log_info "Preview local da câmera USB ${dev} (ffplay) — pressione Q para sair."
        ffplay -f v4l2 -framerate 30 -loglevel warning "$dev"
    fi

    trap - EXIT INT TERM
    _local_cleanup
}

# ─── Preview LOCAL multi-câmera (--local --all): mosaico numa janela ─────────
# nvcompositor compõe as N câmeras numa grade (na GPU, sem encode) → nv3dsink.
# Cada célula é escalada pelo compositor; captura na resolução CANPASS_CSI_RES.
# Tamanho da janela: CANPASS_MOSAIC_W x CANPASS_MOSAIC_H (padrão 1920x1080).
show_local_all() {
    local -a cams=("$@")
    local n=${#cams[@]}

    if [[ -z "${DISPLAY:-}" ]]; then
        export DISPLAY=:0
        log_warn "DISPLAY não definido — assumindo :0. Rode num terminal do desktop do Orin."
    fi
    if ! gst-inspect-1.0 nvcompositor &>/dev/null; then
        log_error "Elemento 'nvcompositor' indisponível — o mosaico requer o GStreamer NVIDIA completo."
        log_info  "Alternativas: 'canpass --local' (uma câmera por vez) ou o app e-multicam da e-con."
        return 1
    fi

    # Grade: 1→1x1 · 2→2x1 · 3-4→2x2 · 5-6→3x2
    local cols rows
    if   (( n <= 1 )); then cols=1; rows=1
    elif (( n == 2 )); then cols=2; rows=1
    elif (( n <= 4 )); then cols=2; rows=2
    else                    cols=3; rows=2
    fi
    local win_w="${CANPASS_MOSAIC_W:-1920}" win_h="${CANPASS_MOSAIC_H:-1080}"
    local cell_w=$(( win_w / cols )) cell_h=$(( win_h / rows ))

    local res="${CANPASS_CSI_RES:-1920x1080@30}"
    local csi_w csi_h csi_fps
    IFS='x@' read -r csi_w csi_h csi_fps <<< "$res"

    _boost_jetson_clocks
    # nvargus-daemon só importa para câmeras Argus (csi:*); YUV/V4L2 não o usa.
    [[ " ${cams[*]} " == *" csi:"* ]] && sudo -n systemctl restart nvargus-daemon &>/dev/null && sleep 3

    log_info "Mosaico ${cols}x${rows} (janela ${win_w}x${win_h}, células ${cell_w}x${cell_h}) com ${n} câmera(s) @ ${res}."
    log_info "Janela abrindo no monitor do Orin — pressione Ctrl+C aqui para encerrar."

    local yuv_src="v4l2src"
    gst-inspect-1.0 nvv4l2camerasrc &>/dev/null && yuv_src="nvv4l2camerasrc"

    # Formato + fps reais pré-fixados nos nós YUV (evita tela verde por formato
    # herdado e fps divergente — ver _yuv_stream_loop).
    if command -v v4l2-ctl &>/dev/null; then
        local yc
        for yc in "${cams[@]}"; do
            [[ "$yc" == yuv:* ]] || continue
            v4l2-ctl -d "/dev/video${yc#yuv:}" \
                --set-fmt-video="width=${csi_w},height=${csi_h},pixelformat=UYVY" 2>/dev/null
            v4l2-ctl -d "/dev/video${yc#yuv:}" -c frame_rate_control="${csi_fps}" 2>/dev/null
        done
    fi

    # Pipeline: posições/tamanhos por sink do compositor + um ramo de captura por
    # câmera (Argus p/ csi:N, V4L2 p/ yuv:N), tudo em memória NVMM (GPU).
    local -a gst=( nvcompositor name=comp )
    local i x y sid
    for i in "${!cams[@]}"; do
        x=$(( (i % cols) * cell_w ))
        y=$(( (i / cols) * cell_h ))
        gst+=( "sink_${i}::xpos=${x}" "sink_${i}::ypos=${y}" "sink_${i}::width=${cell_w}" "sink_${i}::height=${cell_h}" )
    done
    gst+=( ! "video/x-raw(memory:NVMM),format=RGBA" ! nv3dsink sync=false )
    for i in "${!cams[@]}"; do
        sid="${cams[$i]#*:}"
        if [[ "${cams[$i]}" == yuv:* ]]; then
            # Caps NV12 NVMM explícitos após o nvvidconv (mesma razão do preview:
            # sem eles o passthrough UYVY NVMM quebra a negociação).
            if [[ "$yuv_src" == "nvv4l2camerasrc" ]]; then
                gst+=( nvv4l2camerasrc device="/dev/video${sid}" ! \
                       "video/x-raw(memory:NVMM),format=UYVY,width=${csi_w},height=${csi_h}" ! \
                       nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" ! "comp.sink_${i}" )
            else
                gst+=( v4l2src device="/dev/video${sid}" ! \
                       "video/x-raw,format=UYVY,width=${csi_w},height=${csi_h}" ! \
                       nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" ! "comp.sink_${i}" )
            fi
        else
            gst+=( nvarguscamerasrc sensor-id="$sid" ! \
                   "video/x-raw(memory:NVMM),width=${csi_w},height=${csi_h},framerate=${csi_fps}/1,format=NV12" ! \
                   nvvidconv ! "comp.sink_${i}" )
        fi
    done
    gst-launch-1.0 -q "${gst[@]}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local display="" mode="stream" all=0
    for arg in "$@"; do
        [[ "$arg" == "--display" ]] && display="--display"
        [[ "$arg" == "--local" ]] && mode="local"
        [[ "$arg" == "--all" ]] && all=1
    done

    echo -e "${BOLD}${CYAN}"
    echo    "╔══════════════════════════════════════╗"
    echo    "║        CANPass — Camera Viewer       ║"
    echo    "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "Procurando câmeras em /dev/video*..."
    mapfile -t cameras < <(detect_cameras)

    # Em Jetson, anuncia qual das câmeras do projeto está ativa neste boot —
    # a entrada csi:N do menu abaixo corresponde a ela (J509 = uma por boot).
    local active_cam
    active_cam=$(_active_csi_camera)
    if [[ -n "$active_cam" ]]; then
        log_info "Câmera do projeto ativa neste boot: ${BOLD}${active_cam}${NC}"
        log_info "(para alternar e-CAM82 ↔ NileCAM81:  canpass-camera switch)"
    fi

    # FIELD: câmera do projeto ativa no boot mas sem enumerar → re-proba o GMSL e,
    # persistindo, reinicia o Orin (com teto de reboots p/ não travar o acesso remoto).
    local cam_recover_rc
    _recover_or_reboot_no_cam "${cameras[@]:-}"; cam_recover_rc=$?
    if (( cam_recover_rc == 2 )); then
        log_info "Re-detectando câmeras após recuperação..."
        mapfile -t cameras < <(detect_cameras)
    fi

    if [[ ${#cameras[@]} -eq 0 ]]; then
        log_warn "Nenhuma câmera local encontrada."
        [[ -n "$active_cam" ]] && log_warn "A ${active_cam%% *} está ativa no boot mas não enumerou — cabo/base board? 'canpass-camera status' ajuda."
    else
        log_ok "${#cameras[@]} câmera(s) local(is) detectada(s):"
    fi

    for i in "${!cameras[@]}"; do
        local label
        label=$(camera_label "${cameras[$i]}")
        echo -e "  ${GREEN}[$i]${NC} ${cameras[$i]}  —  ${label}"
    done

    # ── Modo --all: todas as câmeras CSI/YUV de uma vez, sem menu ─────────────
    if (( all )); then
        local -a multi_cams=()
        local c
        for c in "${cameras[@]:-}"; do
            [[ "$c" == csi:* || "$c" == yuv:* ]] && multi_cams+=("$c")
        done

        # Entrevista multi-IP: em terminal interativo, oferece somar N câmeras IP
        # às locais (ex.: NileCAM81 + 2 IPs num só processo). Sem tty (boot/systemd)
        # ou CANPASS_NO_INTERVIEW=1, pula — a config de IP exige interação.
        if [[ -t 0 && "${CANPASS_NO_INTERVIEW:-0}" != "1" ]]; then
            local -a ip_cams=()
            mapfile -t ip_cams < <(_prompt_ip_cameras_multi)
            (( ${#ip_cams[@]} > 0 )) && multi_cams+=("${ip_cams[@]}")
        fi

        # Câmeras IP por AMBIENTE (boot/systemd — perfil de campo, sem tty):
        # CANPASS_IP_URLS = lista de URLs RTSP separadas por espaço, ';' ou nova-linha.
        # Cada uma vira 'ip:<url>' e soma às locais (NileCAM81 + 2 IPs num só processo).
        if [[ -n "${CANPASS_IP_URLS:-}" ]]; then
            local _ipurl _added=0 _norm
            _norm="$(printf '%s' "$CANPASS_IP_URLS" | tr ';\n\t' '   ')"
            for _ipurl in $_norm; do
                [[ -n "$_ipurl" ]] || continue
                [[ "$_ipurl" == ip:* ]] || _ipurl="ip:${_ipurl}"
                multi_cams+=("$_ipurl"); _added=$((_added+1))
            done
            (( _added > 0 )) && log_info "--all: ${_added} câmera(s) IP de CANPASS_IP_URLS (perfil de campo)."
        fi


        if [[ ${#multi_cams[@]} -eq 0 ]]; then
            log_error "--all: nenhuma câmera (nem CSI/YUV detectada, nem IP informada)."
            exit 1
        fi

        # Mosaico local: nvcompositor só compõe CSI/YUV — descarta IP com aviso.
        if [[ "$mode" == "local" ]]; then
            local -a local_cams=()
            for c in "${multi_cams[@]}"; do
                [[ "$c" == ip:* ]] && { log_warn "Mosaico --local não inclui câmera IP — ignorando uma."; continue; }
                local_cams+=("$c")
            done
            if [[ ${#local_cams[@]} -eq 0 ]]; then
                log_error "--local --all: nenhuma câmera CSI/YUV para o mosaico (IP não é suportada aqui)."
                exit 1
            fi
            echo
            log_ok "--local --all: ${#local_cams[@]} câmera(s) no mosaico."
            echo
            show_local_all "${local_cams[@]}"
            exit 0   # preview manual: não deixa o watchdog reiniciar ao encerrar
        fi

        local disp
        disp=$(printf '%s\n' "${multi_cams[@]}" | sed 's|rtsp://[^:]*:[^@]*@|rtsp://***:***@|' | tr '\n' ' ')
        echo
        log_ok "--all: usando ${#multi_cams[@]} câmera(s): ${disp}"
        echo
        show_all_cameras "$display" "${multi_cams[@]}"
        return
    fi

    local ip_idx=${#cameras[@]}
    echo -e "  ${GREEN}[${ip_idx}]${NC}  + Câmera IP (RTSP)"
    echo

    local selected="" choice
    # Sem tty (boot via systemd) ou CANPASS_NO_INTERVIEW=1: NÃO travar no prompt.
    # A entrevista tem timeout, mas este read não — sem isto o serviço pendurava
    # aqui esperando uma tecla que nunca vem. Auto-seleciona a 1ª câmera local.
    if [[ ! -t 0 || "${CANPASS_NO_INTERVIEW:-0}" == "1" ]]; then
        if (( ${#cameras[@]} > 0 )); then
            selected="${cameras[0]}"
            log_info "Modo não-interativo — câmera [0] selecionada automaticamente: ${selected}"
        else
            log_error "Nenhuma câmera local e modo não-interativo — nada a transmitir."
            log_error "(o watchdog tentará de novo; verifique 'canpass-camera status' / cabo / driver)"
            exit 1
        fi
    else
        while true; do
            read -rp "$(echo -e "${CYAN}Selecione [0–${ip_idx}]:${NC} ")" choice
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if (( choice < ${#cameras[@]} )); then
                    selected="${cameras[$choice]}"
                    break
                elif (( choice == ip_idx )); then
                    selected=$(_prompt_ip_camera) || { log_warn "Câmera IP não configurada. Tente novamente."; continue; }
                    [[ -n "$selected" ]] && break
                fi
            fi
            log_warn "Opção inválida. Tente novamente."
        done
    fi

    echo
    if [[ "$mode" == "local" ]]; then
        show_local "$selected"
        exit 0   # preview manual: não deixa o watchdog reiniciar ao encerrar
    fi
    show_camera "$selected" "$display"
}

main "$@"
