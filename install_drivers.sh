#!/usr/bin/env bash
# Instala os drivers de câmera e-con no Jetson AGX Orin.
# Deve ser executado no próprio Orin, a partir da raiz deste repositório.
# Uso: sudo bash install_drivers.sh
#
# Matriz de compatibilidade dos pacotes presentes neste repositório:
#   • e-CAM82_CUOAGX (IMX485, MIPI)  → L4T 35.2.1 / JP 5.1.0 → kernel 5.10.104-tegra  (CORRETO p/ a câmera deste projeto)
#   • [GMSL] e-CAM YUV OCTA (AR0821) → L4T 36.4.3 / JP 6.2.0 → kernel 5.15.148-tegra  (OUTRO produto — não é a e-CAM82)
#   • [GMSL] NileCAM81_CUOAGX        → L4T 36.3.0 / JP 6.0.0 → kernel 5.15.136-tegra  (OUTRO produto — pendente build 36.4.x)
#
# IMPORTANTE — a e-CAM82_CUOAGX deste projeto é uma câmera MIPI CSI-2 com sensor
# Sony IMX485 e ISP externo (Argus/V4L2). NÃO é GMSL. O driver correto é o pacote
# L4T 35.2.1 / JP 5.1.0. Os pacotes GMSL (OCTA AR0821 / NileCAM81) são de OUTROS
# produtos e foram a causa dos erros 'ser_status=f0' / 'ret=-121' quando instalados
# por engano nesta câmera.
#
# IMPORTANTE — o módulo/kernel só funciona se o L4T do flash casar EXATAMENTE com
# o alvo do pacote. O instalador da e-con aborta se /etc/nv_tegra_release não bater.
# Para a e-CAM82: flasheie o Orin com L4T 35.2.1 / JetPack 5.1.0 (kernel 5.10.104-tegra).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# e-CAM82 IMX485 (MIPI) — pacote CORRETO para a câmera deste projeto
ECAM82_IMX485_DIR="${SCRIPT_DIR}/e-CAM82_CUOAGX_JETSON_XAVIER_ORIN_L4T35.2.1_13-MAR-2023_R02_RC1/e-CAM82_CUOAGX_JETSON_XAVIER_ORIN_L4T35.2.1_13-MAR-2023_R02"

# Pacotes GMSL — OUTROS produtos, mantidos apenas por referência
GMSL_OCTA_DIR="${SCRIPT_DIR}/e-CAM82_CUOAGX_L4T36.4.3/e-CAM_YUV-OCTA-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.4.3_10-FEB-2025_R02"
NILECAM81_DIR="${SCRIPT_DIR}/NileCAM81_CUOAGX/JP6.0_L4T36.3.0/e-CAM_YUV-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.3.0_09-AUG-2024_R03"

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
echo "╔═══════════════════════════════════════════════════╗"
echo "║   e-con Systems — Instalador de Drivers           ║"
echo "║   Jetson AGX Orin                                 ║"
echo "║   Câmera do projeto: e-CAM82 (IMX485, MIPI)       ║"
echo "║   Flash necessário: JP 5.1.0 / L4T 35.2.1         ║"
echo "║   (kernel 5.10.104-tegra — alvo da e-CAM82)       ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Menu principal ───────────────────────────────────────────────────────────

echo "Qual driver deseja instalar?"
echo ""
echo "  1) e-CAM82 (IMX485, MIPI) — L4T 35.2.1 / JP 5.1.0 (kernel 5.10.104-tegra)  ✓ recomendado"
echo "  2) [GMSL] e-CAM YUV OCTA (AR0821) — L4T 36.4.3 / JP 6.2  ⚠ OUTRO produto, não é a e-CAM82"
echo "  3) [GMSL] NileCAM81 — L4T 36.3.0 / JP 6.0  ⚠ OUTRO produto, pendente build 36.4.x"
echo ""
read -rp "Escolha [1, 2 ou 3]: " choice

# ── e-CAM82 IMX485 (MIPI) — pacote correto ────────────────────────────────────

install_ecam82_imx485() {
    if [[ ! -d "${ECAM82_IMX485_DIR}" ]]; then
        log_error "Pasta '${ECAM82_IMX485_DIR}' não encontrada. Verifique se o repositório foi clonado corretamente (git pull)."
        exit 1
    fi

    # Avisa se o kernel do Orin for diferente do alvo do pacote (5.10.104-tegra)
    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.10.104"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER}"
        log_warn "Este pacote foi compilado para 5.10.104-tegra (L4T 35.2.1 / JP 5.1.0)."
        log_warn "O instalador da e-con confere /etc/nv_tegra_release e ABORTA se o L4T"
        log_warn "não casar exatamente (ex.: L4T 35.6.4 será rejeitado)."
        log_warn "Flasheie o Orin com L4T 35.2.1 / JetPack 5.1.0 antes de prosseguir."
        echo ""
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    echo ""
    log_info "Selecione a configuração de lanes da e-CAM82 (IMX485):"
    echo "  1) 2 lanes  — DTBO: tegra234-...camera-2lane-eimx485"
    echo "  2) 4 lanes  — DTBO: tegra234-...camera-4lane-eimx485"
    echo ""
    read -rp "Lanes [1 ou 2]: " lane_variant
    if [[ "${lane_variant}" != "1" && "${lane_variant}" != "2" ]]; then
        log_error "Opção inválida: '${lane_variant}'."
        exit 1
    fi

    log_info "Iniciando instalação e-CAM82 IMX485 (lanes ${lane_variant})..."
    cd "${ECAM82_IMX485_DIR}"
    # O install_binaries.sh da e-con lê a configuração de lane via stdin
    # (1=2lane, 2=4lane) — passamos a escolha diretamente pelo pipe.
    echo "${lane_variant}" | bash install_binaries.sh
}

# ── [GMSL] e-CAM YUV OCTA (AR0821) — OUTRO produto ────────────────────────────

install_gmsl_octa() {
    log_warn "Este NÃO é o driver da e-CAM82 deste projeto."
    log_warn "É o pacote GMSL OCTA (sensor AR0821 + desserializador max96712), de outro produto."
    log_warn "Instalá-lo na e-CAM82 (IMX485) causa 'ser_status=f0' / 'ret=-121'."
    read -rp "Tem certeza que quer prosseguir? [s/N]: " confirm
    [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }

    if [[ ! -d "${GMSL_OCTA_DIR}" ]]; then
        log_error "Pasta '${GMSL_OCTA_DIR}' não encontrada. Verifique o git pull."
        exit 1
    fi

    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.15.148"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER} (alvo: 5.15.148-tegra / L4T 36.4.3)."
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    echo ""
    log_info "Selecione a variante:"
    echo "  1) 4 câmeras  — DTBO: ar0821_four_lane_four_cam"
    echo "  2) 8 câmeras  — DTBO: ar0821_four_lane"
    echo ""
    read -rp "Variante [1 ou 2]: " cam_variant
    if [[ "${cam_variant}" != "1" && "${cam_variant}" != "2" ]]; then
        log_error "Opção inválida: '${cam_variant}'."
        exit 1
    fi

    log_info "Iniciando instalação GMSL OCTA (variante ${cam_variant})..."
    cd "${GMSL_OCTA_DIR}"
    echo "${cam_variant}" | bash install_binaries.sh 81
}

# ── [GMSL] NileCAM81 — OUTRO produto ──────────────────────────────────────────

install_nilecam81() {
    log_warn "Este NÃO é o driver da e-CAM82 deste projeto (é a NileCAM81, GMSL)."
    read -rp "Tem certeza que quer prosseguir? [s/N]: " confirm
    [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }

    if [[ ! -d "${NILECAM81_DIR}" ]]; then
        log_error "Pasta '${NILECAM81_DIR}' não encontrada. Verifique o git pull."
        exit 1
    fi

    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.15.136"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER} (alvo: 5.15.136-tegra / L4T 36.3.0)."
        log_warn "Não há build da NileCAM81 para L4T 36.4.x neste repo — solicite ao suporte e-con."
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    log_info "Iniciando instalação NileCAM81..."
    cd "${NILECAM81_DIR}"
    bash install_binaries.sh 81
}

# ── Execução ─────────────────────────────────────────────────────────────────

case "${choice}" in
    1) install_ecam82_imx485 ;;
    2) install_gmsl_octa ;;
    3) install_nilecam81 ;;
    *)
        log_error "Opção inválida: '${choice}'. Escolha 1, 2 ou 3."
        exit 1
        ;;
esac
