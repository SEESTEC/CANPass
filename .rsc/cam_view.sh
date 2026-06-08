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
    if sudo ip addr add "${jetson_ip}/24" dev "${chosen_iface}" 2>/dev/null; then
        log_ok "IP ${jetson_ip}/24 configurado em ${chosen_iface}. Será removido ao encerrar o canpass."
        _TEMP_IP_ADDR="${jetson_ip}/24"
        _TEMP_IP_IFACE="${chosen_iface}"
    else
        log_warn "Falha ao configurar IP (já existe ou permissão insuficiente). Continuando..."
    fi
}

# ─── 3. Coleta dados de câmera IP e monta URL RTSP ───────────────────────────

_prompt_ip_camera() {
    local ip port path user pass url
    echo >&2
    read -rp "$(echo -e "${CYAN}  IP da câmera:${NC} ")" ip
    [[ -z "$ip" ]] && return 1

    _check_and_configure_subnet "$ip" >&2

    read -rp "$(echo -e "${CYAN}  Porta RTSP [554]:${NC} ")" port
    port="${port:-554}"

    read -rp "$(echo -e "${CYAN}  Caminho do stream [/cam/realmonitor?channel=1&subtype=0]:${NC} ")" path
    path="${path:-/cam/realmonitor?channel=1&subtype=0}"
    [[ "$path" != /* ]] && path="/${path}"

    read -rp "$(echo -e "${CYAN}  Usuário (Enter para nenhum):${NC} ")" user

    if [[ -n "$user" ]]; then
        read -rsp "$(echo -e "${CYAN}  Senha:${NC} ")" pass
        echo >&2
        url="rtsp://${user}:${pass}@${ip}:${port}${path}"
    else
        url="rtsp://${ip}:${port}${path}"
    fi

    echo "ip:${url}"
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

        # Câmera CSI da Tegra (ex.: e-CAM82/eimx485): aparece como /dev/videoN mas
        # exige o caminho Argus. Mapeia para csi:N (sensor-id = N) em vez do V4L2.
        if _is_tegra_csi_device "$dev"; then
            if _has_argus; then
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

camera_label() {
    local dev="$1"
    if [[ "$dev" == csi:* ]]; then
        echo "CSI Camera — Jetson sensor-id ${dev#csi:}"
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

    # ── Inicia captura: CSI (Jetson/Argus) ou V4L2 (USB/padrão) ────────────────
    if [[ "$dev" == csi:* ]]; then
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

        # Loop CSI: GStreamer captura e converte (NV12→I420) via pipe para
        # ffmpeg, que faz encode H.264 e envia ao MediaMTX por RTSP.
        # nvv4l2h264enc e rtspclientsink são evitados por inconsistência entre
        # versões de JetPack — ffmpeg garante compatibilidade.
        _ffmpeg_loop() {
            local csi_log="/tmp/canpass_csi_${sensor_id}.log"
            local nvargus_retries=0
            log_info "Log de erros CSI: ${csi_log}"
            while true; do
                : > "$csi_log"  # limpa a cada tentativa para checar apenas o erro atual
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
                    "${ENCODE[@]}" -muxdelay 0 -muxpreload 0 \
                    -rtsp_transport tcp -f rtsp "$RTSP_URL" 2>>"$csi_log"
                local gst_rc=${PIPESTATUS[0]} ffmpeg_rc=${PIPESTATUS[1]}
                (( gst_rc >= 128 || ffmpeg_rc >= 128 )) && return
                # Daemon nvargus não encontrou a câmera — pode ser problema de timing;
                # reinicia e tenta novamente antes de desistir.
                if grep -q "No cameras available" "$csi_log" 2>/dev/null; then
                    if (( nvargus_retries++ < 2 )); then
                        log_warn "Daemon nvargus não encontrou a câmera — reiniciando (tentativa ${nvargus_retries}/2)..."
                        sudo -n systemctl restart nvargus-daemon 2>/dev/null
                        sleep 5
                        continue
                    fi
                    log_error "Câmera CSI inacessível pelo daemon nvargus."
                    log_info  "Verifique a conexão física da câmera e execute canpass novamente."
                    return 1
                fi
                nvargus_retries=0
                log_warn "Stream CSI encerrado (gst=${gst_rc} ffmpeg=${ffmpeg_rc}) — reconectando em 2s... (log: ${csi_log})"
                sleep 2
            done
        }
    elif [[ "$dev" == ip:* ]]; then
        # ── IP (RTSP): lê diretamente do stream da câmera ─────────────────────
        local rtsp_in="${dev#ip:}"
        local display_url
        display_url=$(sed 's|rtsp://[^:]*:[^@]*@|rtsp://***:***@|' <<< "$rtsp_in")
        log_info "Stream IP: ${display_url}"

        _ffmpeg_loop() {
            local err_log
            err_log=$(mktemp /tmp/canpass_ip_XXXXXX.log)

            _ip_check_err() {
                cat "$err_log" >&2
                if grep -q "404 Not Found" "$err_log"; then
                    log_error "Path RTSP não encontrado na câmera (404). Reinicie e informe o path correto."
                    log_info  "Paths comuns para câmeras Intelbras:"
                    log_info  "  /cam/realmonitor?channel=1&subtype=0  (principal)"
                    log_info  "  /cam/realmonitor?channel=1&subtype=1  (secundário)"
                    log_info  "  /live"
                    return 1
                fi
                if grep -q "401 Unauthorized" "$err_log"; then
                    log_error "Câmera recusou autenticação (401) — verifique usuário e senha."
                    return 1
                fi
                return 0
            }

            # Probe: inicia o stream e aguarda 3s para confirmar que a câmera
            # está respondendo e o MediaMTX já recebe dados antes de exibir os URLs.
            log_info "Conectando à câmera IP (aguarde)..."
            : > "$err_log"
            ffmpeg -loglevel error \
                -rtsp_transport tcp \
                "${BASE[@]}" \
                -i "$rtsp_in" \
                "${ENCODE[@]}" -muxdelay 0 -muxpreload 0 \
                -rtsp_transport tcp -f rtsp "$RTSP_URL" 2>"$err_log" &
            local probe_pid=$!
            sleep 3
            if ! kill -0 "$probe_pid" 2>/dev/null; then
                wait "$probe_pid" 2>/dev/null
                _ip_check_err || { rm -f "$err_log"; return 1; }
                log_error "Câmera IP desconectou antes de iniciar o stream."
                rm -f "$err_log"
                return 1
            fi
            kill "$probe_pid" 2>/dev/null
            wait "$probe_pid" 2>/dev/null
            log_ok "Câmera IP conectada — stream disponível no MediaMTX."

            # Loop de reconexão para quedas transitórias após o stream estar estável.
            while true; do
                : > "$err_log"
                ffmpeg -loglevel error \
                    -rtsp_transport tcp \
                    "${BASE[@]}" \
                    -i "$rtsp_in" \
                    "${ENCODE[@]}" -muxdelay 0 -muxpreload 0 \
                    -rtsp_transport tcp -f rtsp "$RTSP_URL" 2>"$err_log"
                local rc=$?
                _ip_check_err || { rm -f "$err_log"; return 1; }
                (( rc >= 128 )) && { rm -f "$err_log"; return; }
                log_warn "Stream IP encerrado (código ${rc}) — reconectando em 2s..."
                sleep 2
            done
            rm -f "$err_log"
        }
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

    # ── Gravação por detecção de movimento ───────────────────────────────────
    # Arquitetura:
    #   ffmpeg detector  →  select filter (scene score)  →  bash state machine
    #                                                              ↓
    #                                                   ffmpeg recorder (-c copy → MP4)
    #
    # O detector lê o RTSP e emite apenas frames onde ≥ MOTION_THRESHOLD da
    # imagem mudou. A máquina de estados inicia/para a gravação conforme o fluxo
    # de eventos e o cooldown configurado.

    local rec_dir="${CANPASS_REC_DIR:-${HOME}/canpass_rec}"
    mkdir -p "$rec_dir"

    _motion_recording_loop() {
        local motion_active=0
        local last_motion_epoch=0
        local recorder_pid=""
        local recording_start_ts=""
        local recording_tmp_file=""

        _start_recording() {
            recording_start_ts=$(date +"%d-%m-%Y_%H-%M-%S")
            recording_tmp_file="${rec_dir}/.rec_${recording_start_ts}.mp4"
            ffmpeg -loglevel error \
                -fflags nobuffer \
                -analyzeduration 0 \
                -probesize 32768 \
                -rtsp_transport tcp \
                -i "$RTSP_URL" \
                -c copy \
                "$recording_tmp_file" 2>/dev/null &
            recorder_pid=$!
            log_info "Movimento detectado — gravando: ${recording_start_ts}"
        }

        _stop_recording() {
            [[ -z "$recorder_pid" ]] && return
            kill "$recorder_pid" 2>/dev/null
            wait "$recorder_pid" 2>/dev/null
            local recording_end_ts
            recording_end_ts=$(date +"%H-%M-%S")
            local final_filename="${rec_dir}/${recording_start_ts}_${recording_end_ts}.mp4"
            [[ -f "$recording_tmp_file" ]] && mv "$recording_tmp_file" "$final_filename"
            log_info "Sem movimento — arquivo salvo: $(basename "$final_filename")"
            recorder_pid=""
            recording_start_ts=""
            recording_tmp_file=""
        }

        sleep 5  # aguarda o stream estabilizar no MediaMTX (IP cameras precisam de mais tempo)

        # Loop externo: reinicia o detector se ele cair (ex: stream não estava
        # pronto no MediaMTX quando o detector conectou). É encerrado pelo SIGTERM
        # enviado pelo cleanup() ao matar motion_rec_pid.
        while true; do
            motion_active=0
            last_motion_epoch=0

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
                                _start_recording
                            fi
                        fi
                    fi
                elif (( read_status == 1 )); then
                    break  # EOF — detector encerrado, sai do loop interno
                fi
                if [[ $motion_active -eq 1 ]] && (( now - last_motion_epoch >= MOTION_COOLDOWN_SECS )); then
                    motion_active=0
                    _stop_recording
                fi

            done < <(
                ffmpeg -loglevel info \
                    -rtsp_transport tcp \
                    -i "$RTSP_URL" \
                    -vf "select=gt(scene\,${MOTION_THRESHOLD}),metadata=print:key=lavfi.scene_score" \
                    -f null /dev/null 2>&1 | grep --line-buffered "lavfi.scene_score"
            )

            # EOF: encerra gravação em curso e aguarda antes de reiniciar o detector
            [[ $motion_active -eq 1 ]] && _stop_recording
            sleep 5
        done
    }

    _motion_recording_loop &
    local motion_rec_pid=$!

    # Encerra os loops ao sair (Q, Ctrl+C ou término normal).
    # Remove o IP temporário adicionado para câmera IP, se houver.
    cleanup() {
        # Guarda com :- porque o trap EXIT pode disparar fora do escopo de
        # show_camera (ex.: após um return antecipado), quando os locais já
        # não existem — sem isso, `set -u` aborta com "unbound variable".
        kill "${loop_pid:-}" "${motion_rec_pid:-}" 2>/dev/null
        if [[ -n "$_TEMP_IP_ADDR" && -n "$_TEMP_IP_IFACE" ]]; then
            sudo ip addr del "$_TEMP_IP_ADDR" dev "$_TEMP_IP_IFACE" 2>/dev/null \
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
    log_ok "Gravando em:   ${rec_dir}  (movimento: threshold=${MOTION_THRESHOLD}, cooldown=${MOTION_COOLDOWN_SECS}s)"
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

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local display=""
    for arg in "$@"; do
        [[ "$arg" == "--display" ]] && display="--display"
    done

    echo -e "${BOLD}${CYAN}"
    echo    "╔══════════════════════════════════════╗"
    echo    "║        CANPass — Camera Viewer       ║"
    echo    "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "Procurando câmeras em /dev/video*..."
    mapfile -t cameras < <(detect_cameras)

    if [[ ${#cameras[@]} -eq 0 ]]; then
        log_warn "Nenhuma câmera local encontrada."
    else
        log_ok "${#cameras[@]} câmera(s) local(is) detectada(s):"
    fi

    for i in "${!cameras[@]}"; do
        local label
        label=$(camera_label "${cameras[$i]}")
        echo -e "  ${GREEN}[$i]${NC} ${cameras[$i]}  —  ${label}"
    done

    local ip_idx=${#cameras[@]}
    echo -e "  ${GREEN}[${ip_idx}]${NC}  + Câmera IP (RTSP)"
    echo

    local selected="" choice
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

    echo
    show_camera "$selected" "$display"
}

main "$@"
