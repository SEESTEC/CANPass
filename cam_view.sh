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

# ─── 1. Verifica / instala pacote ────────────────────────────────────────────

ensure_installed() {
    local pkg="$1" cmd="${2:-$1}"

    if command -v "$cmd" &>/dev/null; then
        log_ok "$cmd já instalado em $(command -v "$cmd")."
        return 0
    fi

    log_warn "$cmd não encontrado. Instalando $pkg..."

    local apt
    apt="$([ "$EUID" -eq 0 ] && echo 'apt-get' || echo 'sudo apt-get')"

    $apt update -qq
    $apt install -y "$pkg"

    if command -v "$cmd" &>/dev/null; then
        log_ok "$pkg instalado com sucesso."
    else
        log_error "Falha ao instalar $pkg. Abortando."
        exit 1
    fi
}

# ─── 2. Instala Docker via script dedicado ───────────────────────────────────

ensure_docker_installed() {
    if command -v docker &>/dev/null; then
        log_ok "docker já instalado em $(command -v docker)."
        return 0
    fi

    log_warn "docker não encontrado. Executando docker-install.sh..."

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local installer="${script_dir}/docker-install.sh"

    if [[ ! -f "$installer" ]]; then
        log_error "docker-install.sh não encontrado em ${script_dir}. Abortando."
        exit 1
    fi

    bash "$installer"

    if command -v docker &>/dev/null; then
        log_ok "docker instalado com sucesso."
    else
        log_error "Falha ao instalar docker. Abortando."
        exit 1
    fi
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
        log_ok "Container '${CONTAINER_NAME}' já está em execução."
        return 0
    fi

    log_info "Iniciando container MediaMTX..."
    docker run -d --rm --name "$CONTAINER_NAME" \
        -p 8554:8554 -p 8889:8889 \
        bluenviron/mediamtx

    sleep 2

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_ok "MediaMTX iniciado."
    else
        log_error "Falha ao iniciar o container MediaMTX. Abortando."
        exit 1
    fi
}

# ─── 4. Detecta câmeras V4L2 ─────────────────────────────────────────────────
# Filtra apenas dispositivos de *captura* (não outputs de loopback/renderização).

detect_cameras() {
    local -a cams=()

    for dev in /dev/video*; do
        # Deve ser um character device acessível
        [[ -c "$dev" && -r "$dev" ]] || continue

        # Se v4l2-ctl disponível, confirma que suporta captura de vídeo
        if command -v v4l2-ctl &>/dev/null; then
            v4l2-ctl --device="$dev" --all 2>/dev/null \
                | grep -qi "Video Capture" || continue
        fi

        cams+=("$dev")
    done

    printf '%s\n' "${cams[@]+"${cams[@]}"}"
}

# ─── 5. Nome amigável da câmera ───────────────────────────────────────────────

camera_label() {
    local dev="$1"
    if command -v v4l2-ctl &>/dev/null; then
        local name
        name=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
               | awk -F': ' '/Card type/{gsub(/^[[:space:]]+/,"",$2); print $2}')
        [[ -n "$name" ]] && echo "$name" && return
    fi
    echo "$dev"
}

# ─── 6. Cria alias 'canpass' no ~/.bashrc ────────────────────────────────────

setup_alias() {
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local alias_line="alias canpass='${script_path}'"
    local bashrc="${HOME}/.bashrc"

    if grep -qF "alias canpass=" "$bashrc" 2>/dev/null; then
        log_ok "Alias 'canpass' já existe em ${bashrc}."
    else
        printf '\n# CANPass camera viewer\n%s\n' "$alias_line" >> "$bashrc"
        log_ok "Alias 'canpass' adicionado em ${bashrc}."
        log_info "Execute 'source ~/.bashrc' ou abra um novo terminal para ativar."
    fi
}

# ─── 7. Captura e transmite via RTSP (exibição local opcional com --display) ──
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
#
# Exibição local:
#   -sync video          sincroniza pelo relógio de vídeo
#   SDL_RENDER_VSYNC=1   sincroniza com o refresh do monitor (evita tearing)

show_camera() {
    local dev="$1"
    local display="${2:-}"
    local ffmpeg_pid=""

    ensure_mediamtx

    local -a BASE=(
        -probesize 32768
        -analyzeduration 0
        -fflags nobuffer
        -flags low_delay
    )
    local -a ENCODE=( -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p )

    # Tenta iniciar ffmpeg com fallbacks de formato de entrada
    local started=0
    local attempt_label=""
    for args_str in \
        "-f v4l2 -input_format mjpeg -framerate 30 -video_size 1280x720" \
        "-f v4l2 -framerate 30 -video_size 1280x720" \
        "-f v4l2"
    do
        [[ -n "$attempt_label" ]] && log_warn "Tentativa '${attempt_label}' falhou — próximo formato..."
        attempt_label="$args_str"

        read -ra input_args <<< "$args_str"
        ffmpeg -loglevel warning "${BASE[@]}" "${input_args[@]}" -i "$dev" \
            "${ENCODE[@]}" -f rtsp "$RTSP_URL" &
        ffmpeg_pid=$!

        sleep 2
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            started=1
            break
        fi
    done

    if [[ $started -eq 0 ]]; then
        log_error "Não foi possível iniciar o stream para ${dev}. Abortando."
        return 1
    fi

    # Encerra ffmpeg ao sair (Q, Ctrl+C ou término normal)
    cleanup() { kill "$ffmpeg_pid" 2>/dev/null; }
    trap cleanup EXIT INT TERM

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo
    log_ok "Stream RTSP ativo:   ${RTSP_URL}"
    log_ok "Stream WebRTC:       http://${ip}:8889/stream  (abra no navegador de outra máquina)"
    if [[ "$display" == "--display" ]]; then
        log_info "Iniciando visualização local — pressione Q para sair."
        echo
        SDL_RENDER_VSYNC=1 ffplay \
            -fflags nobuffer -flags low_delay -sync video \
            -window_title "CANPass: $dev" -loglevel warning \
            "$RTSP_URL"
    else
        log_info "Stream ativo em background. Pressione Ctrl+C para encerrar."
        wait "$ffmpeg_pid"
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

    ensure_installed ffmpeg ffplay
    ensure_installed v4l-utils v4l2-ctl
    ensure_docker_installed
    setup_alias
    echo

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
