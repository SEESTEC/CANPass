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

# ─── 1. Detecção de câmeras CSI (Jetson/Tegra) ───────────────────────────────
# Em plataformas Jetson, câmeras CSI são gerenciadas pelo Argus daemon da NVIDIA
# via GStreamer (nvarguscamerasrc). Elas NÃO aparecem como /dev/video*, apenas
# como /dev/media* (controlador de mídia Tegra), portanto precisam de caminho
# de captura separado do V4L2 padrão.

_probe_csi_cameras() {
    grep -aqE "nvidia" /proc/device-tree/compatible 2>/dev/null || return
    command -v gst-launch-1.0 &>/dev/null || return
    gst-inspect-1.0 nvarguscamerasrc &>/dev/null 2>&1 || return
    # Não abre sessões nvarguscamerasrc aqui — cada probe esgota o daemon e impede
    # o stream subsequente ("No cameras available"). Lista os IDs de CANPASS_CSI_SENSORS
    # (padrão: 0) sem validação; o stream vai confirmar a disponibilidade real.
    local ids="${CANPASS_CSI_SENSORS:-0}"
    local id
    for id in $ids; do
        echo "csi:${id}"
    done
}

# ─── 2. Inicia container MediaMTX (servidor RTSP/WebRTC) ─────────────────────

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

        cams+=("$dev")
    done

    # Sem câmeras V4L2 — tenta CSI (Jetson/Tegra)
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
        -g 6 -keyint_min 6 -sc_threshold 0
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

        # Loop CSI: GStreamer captura e converte (NV12→I420) via pipe para
        # ffmpeg, que faz encode H.264 e envia ao MediaMTX por RTSP.
        # nvv4l2h264enc e rtspclientsink são evitados por inconsistência entre
        # versões de JetPack — ffmpeg garante compatibilidade.
        _ffmpeg_loop() {
            local csi_log="/tmp/canpass_csi_${sensor_id}.log"
            : > "$csi_log"
            log_info "Log de erros CSI: ${csi_log}"
            while true; do
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
                log_warn "Stream CSI encerrado (gst=${gst_rc} ffmpeg=${ffmpeg_rc}) — reconectando em 2s... (log: ${csi_log})"
                sleep 2
            done
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

        sleep 1  # aguarda o stream RTSP estabilizar

        # Lê scores de cena do ffmpeg — produz saída apenas quando há movimento
        # read -t COOLDOWN: expira se nenhum frame de movimento chegar no intervalo
        while true; do
            local line="" read_status
            IFS= read -r -t "${MOTION_COOLDOWN_SECS}" line
            read_status=$?
            local now
            now=$(date +%s)

            if (( read_status == 0 )); then
                # Frame com movimento recebido: extrai o score e atualiza estado
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
                break  # EOF — detector encerrado (stream RTSP caiu)
            fi
            # read_status > 128 = timeout (nenhum frame de movimento no intervalo)
            # Verifica cooldown em ambos os casos (timeout e frame sem score relevante)
            if [[ $motion_active -eq 1 ]] && (( now - last_motion_epoch >= MOTION_COOLDOWN_SECS )); then
                motion_active=0
                _stop_recording
            fi

        done < <(
            # Detector: decodifica o stream, seleciona frames com alteração significativa
            # e captura os scores de cena via stderr (loglevel info) filtrado por grep
            ffmpeg -loglevel info \
                -rtsp_transport tcp \
                -i "$RTSP_URL" \
                -vf "select=gt(scene\,${MOTION_THRESHOLD}),metadata=print:key=lavfi.scene_score" \
                -f null /dev/null 2>&1 | grep --line-buffered "lavfi.scene_score"
        )

        # Garante que a gravação seja encerrada se o loop sair inesperadamente
        [[ $motion_active -eq 1 ]] && _stop_recording
    }

    _motion_recording_loop &
    local motion_rec_pid=$!

    # Encerra os loops ao sair (Q, Ctrl+C ou término normal)
    cleanup() { kill "$loop_pid" "$motion_rec_pid" 2>/dev/null; }
    trap cleanup EXIT INT TERM

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo
    log_ok "Stream RTSP:         ${RTSP_URL}"
    log_ok "Stream WebRTC:       http://${ip}:8889${HLS_PATH}  (~100 ms — recomendado para browser)"
    log_ok "Stream HLS:          http://${ip}:8888${HLS_PATH}  (~200 ms — fallback para browser)"
    log_ok "Gravando em:         ${rec_dir}  (movimento: threshold=${MOTION_THRESHOLD}, cooldown=${MOTION_COOLDOWN_SECS}s)"
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
        log_error "Nenhuma câmera encontrada."
        log_info  "Verifique se o dispositivo está conectado e o módulo uvcvideo carregado:"
        log_info  "  lsusb && lsmod | grep uvcvideo"
        exit 1
    fi

    log_ok "${#cameras[@]} câmera(s) detectada(s):"
    for i in "${!cameras[@]}"; do
        local label
        label=$(camera_label "${cameras[$i]}")
        echo -e "  ${GREEN}[$i]${NC} ${cameras[$i]}  —  ${label}"
    done
    echo

    local selected
    if [[ ${#cameras[@]} -eq 1 ]]; then
        selected="${cameras[0]}"
        log_info "Câmera única detectada: $selected"
    else
        local choice
        while true; do
            read -rp "$(echo -e "${CYAN}Selecione a câmera [0–$((${#cameras[@]}-1))]:${NC} ")" choice
            if [[ "$choice" =~ ^[0-9]+$ && "$choice" -lt "${#cameras[@]}" ]]; then
                selected="${cameras[$choice]}"
                break
            fi
            log_warn "Opção inválida. Tente novamente."
        done
    fi

    echo
    show_camera "$selected" "$display"
}

main "$@"
