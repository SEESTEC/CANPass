#!/usr/bin/env bash
# Instala os drivers de câmera e-con no Jetson AGX Orin (JP 6.2.2 / L4T 36.4.5).
# Deve ser executado no próprio Orin, a partir da pasta ~/econ_drivers.
# Uso: sudo bash install_drivers.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NILECAM81_DIR="${SCRIPT_DIR}/NileCAM81_CUOAGX/JP6.0_L4T36.3.0/e-CAM_YUV-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.3.0_09-AUG-2024_R03"
ECAM82_DIR="${SCRIPT_DIR}/e-CAM82_CUOAGX_L4T36.4.3/e-CAM_YUV-OCTA-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.4.3_10-FEB-2025_R02"

# ── Validações ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    log_error "Execute com sudo: sudo bash $0"
    exit 1
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    log_error "Este script deve ser executado no Jetson Orin (aarch64), não no PC."
    exit 1
fi

# ── Banner ───────────────────────────────────────────────────────────────────

echo -e "${BOLD}${CYAN}"
echo "╔═══════════════════════════════════════════════╗"
echo "║   e-con Systems — Instalador de Drivers       ║"
echo "║   Jetson AGX Orin  •  JP 6.2.2  •  L4T 36.4.5 ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Menu principal ───────────────────────────────────────────────────────────

echo "Qual driver deseja instalar?"
echo ""
echo "  1) NileCAM81   — L4T 36.3.0 / JP 6.0  (produto 81, 2-lane GMSL)"
echo "  2) e-CAM82     — L4T 36.4.3 / JP 6.2  (produto 81, 4-lane GMSL)"
echo ""
read -rp "Escolha [1 ou 2]: " choice

# ── NileCAM81 ────────────────────────────────────────────────────────────────

install_nilecam81() {
    if [[ ! -d "${NILECAM81_DIR}" ]]; then
        log_error "Pasta '${NILECAM81_DIR}' não encontrada. Execute copy_to_orin.sh primeiro."
        exit 1
    fi

    # Avisa se o kernel do Orin for diferente do alvo do pacote (5.15.136-tegra)
    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.15.136"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER}"
        log_warn "Este pacote foi compilado para 5.15.136-tegra (JP6.0)."
        log_warn "Os módulos .ko serão instalados no caminho do pacote, não no kernel atual."
        log_warn "Para JP6.2.2 use o pacote L4T36.4.4 quando disponível via suporte e-con."
        echo ""
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    log_info "Iniciando instalação NileCAM81..."
    cd "${NILECAM81_DIR}"
    bash install_binaries.sh 81
}

# ── e-CAM82 ──────────────────────────────────────────────────────────────────

install_ecam82() {
    if [[ ! -d "${ECAM82_DIR}" ]]; then
        log_error "Pasta '${ECAM82_DIR}' não encontrada. Execute copy_to_orin.sh primeiro."
        exit 1
    fi

    echo ""
    log_info "Selecione a variante do e-CAM82 (produto 81):"
    echo "  1) 4 câmeras  — DTBO: ar0821_four_lane_four_cam"
    echo "  2) 8 câmeras  — DTBO: ar0821_four_lane"
    echo ""
    read -rp "Variante [1 ou 2]: " cam_variant
    if [[ "${cam_variant}" != "1" && "${cam_variant}" != "2" ]]; then
        log_error "Opção inválida: '${cam_variant}'."
        exit 1
    fi

    log_info "Iniciando instalação e-CAM82 (variante ${cam_variant})..."
    cd "${ECAM82_DIR}"
    # O install_binaries.sh recebe o produto via argumento ($1) e lê a variante
    # via stdin — passamos cam_variant diretamente pelo pipe.
    echo "${cam_variant}" | bash install_binaries.sh 81
}

# ── Execução ─────────────────────────────────────────────────────────────────

case "${choice}" in
    1) install_nilecam81 ;;
    2) install_ecam82 ;;
    *)
        log_error "Opção inválida: '${choice}'. Escolha 1 ou 2."
        exit 1
        ;;
esac
