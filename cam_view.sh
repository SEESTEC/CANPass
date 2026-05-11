#!/usr/bin/env bash
# camera_viewer.sh — Detecta câmeras V4L2 e exibe stream via ffplay.
# Testado em Ubuntu 22.04 LTS.

set -uo pipefail

# ─── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

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

# ─── 2. Detecta câmeras V4L2 ─────────────────────────────────────────────────
# Filtra apenas dispositivos de *captura* (não outputs de loopback/renderização).

detect_cameras() {
    local -a cams=()

    for dev in /dev/video*; do
        # Deve ser um character device acessível
        [[ -c "$dev" && -r "$dev" ]] || continue

        # Se v4l2-ctl disponível, confirma que suporta captura de vídeo
        if command -v v4l2-ctl &>/dev/null; then
            v4l2-ctl --device="$dev" --list-formats-ext &>/dev/null \
                && v4l2-ctl --device="$dev" --all 2>/dev/null \
                | grep -qi "Video Capture" || continue
        fi

        cams+=("$dev")
    done

    printf '%s\n' "${cams[@]+"${cams[@]}"}"
}

# ─── 3. Nome amigável da câmera ───────────────────────────────────────────────

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

# ─── 4. Exibe stream com ffplay ───────────────────────────────────────────────

show_camera() {
    local dev="$1"
    log_info "Iniciando stream de ${dev} — pressione Q ou feche a janela para sair."
    echo

    # Tenta 30 fps / 1280×720; se falhar, deixa ffplay escolher os parâmetros
    if ! ffplay -f v4l2 -framerate 30 -video_size 1280x720 \
                -i "$dev" -window_title "Camera: $dev" \
                -loglevel warning 2>/dev/null; then

        log_warn "Resolução padrão não suportada — tentando com parâmetros automáticos..."
        ffplay -f v4l2 -i "$dev" -window_title "Camera: $dev" -loglevel warning
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo    "╔══════════════════════════════════════╗"
    echo    "║        CANPass — Camera Viewer       ║"
    echo    "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    # Garante ffmpeg (inclui ffplay) e v4l-utils (opcional, melhora detecção)
    ensure_installed ffmpeg ffplay
    ensure_installed v4l-utils v4l2-ctl
    echo

    # Detecta câmeras
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

    # Seleção automática se houver apenas uma câmera
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
    show_camera "$selected"
}

main "$@"
