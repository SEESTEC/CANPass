#!/usr/bin/env bash
# Instala os drivers de câmera e-con no Jetson AGX Orin.
# Deve ser executado no próprio Orin, a partir da raiz deste repositório.
# Uso: sudo bash install_drivers.sh
#
# Matriz de compatibilidade dos pacotes presentes neste repositório:
#   • e-CAM82_CUOAGX (IMX485, MIPI)  → L4T 35.2.1 / JP 5.1.0 → kernel 5.10.104-tegra  (câmera PRINCIPAL do projeto)
#   • NileCAM81_CUOAGX (GMSL/AR0821) → L4T 35.2.1 / JP 5.1.0 → kernel 5.10.104-tegra  (câmera ALTERNATIVA — build R02
#     solicitado à e-con em 2026-06; MESMO flash da e-CAM82 → alternância sem reflash via canpass-camera switch)
#   • [GMSL] e-CAM YUV OCTA (AR0821) → L4T 36.4.3 / JP 6.2.0 → kernel 5.15.148-tegra  (OUTRO produto — não usar)
#   • [GMSL] NileCAM81 JP6           → L4T 36.3.0 / JP 6.0.0 → kernel 5.15.136-tegra  (build p/ JP6 — exige reflash)
#
# IMPORTANTE — a e-CAM82_CUOAGX é MIPI CSI-2 (Sony IMX485, ISP externo, Argus/V4L2);
# a NileCAM81_CUOAGX é GMSL2 (AR0821 + desserializadora no J509). As duas usam o MESMO
# conector J509 e UM device tree por boot → NÃO rodam juntas; é alternar, uma por boot
# (canpass-camera switch). Instalar o pacote GMSL errado na e-CAM82 causa
# 'ser_status=f0' / 'ret=-121'.
#
# IMPORTANTE — o módulo/kernel só funciona se o L4T do flash casar EXATAMENTE com
# o alvo do pacote. O instalador da e-con aborta se /etc/nv_tegra_release não bater,
# e REBOOTA AUTOMATICAMENTE o Orin ao final da instalação.
# Para as opções 1 e 2: flasheie o Orin com L4T 35.2.1 / JP 5.1.0 (kernel 5.10.104-tegra).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Modo não-interativo: --auto / -y / --yes instala automaticamente a opção 1
# (e-CAM82 IMX485) em 4 lanes, sem perguntas. Usado pelo install.sh.
AUTO=0
for _arg in "$@"; do
    case "$_arg" in
        --auto|-y|--yes) AUTO=1 ;;
    esac
done

# Drivers/documentação vivem sob doc/<câmera>/<produto>/ (reorganização 2026-06-10).
# e-CAM82 IMX485 (MIPI) — câmera principal do projeto
ECAM82_IMX485_DIR="${SCRIPT_DIR}/doc/e-CAM82/e-CAM82_CUOAGX/e-CAM82_CUOAGX_JETSON_XAVIER_ORIN_L4T35.2.1_13-MAR-2023_R02_RC1/e-CAM82_CUOAGX_JETSON_XAVIER_ORIN_L4T35.2.1_13-MAR-2023_R02"

# NileCAM81 (GMSL) p/ L4T 35.2.1 — câmera ALTERNATIVA, mesmo flash da e-CAM82
NILECAM81_3521_DIR="${SCRIPT_DIR}/doc/NileCAM81/NileCAM81_CUOAGX/JP5.1.0_L4T35.2.1"

# Pacotes GMSL p/ JP6 — outros alvos de flash, mantidos apenas por referência
GMSL_OCTA_DIR="${SCRIPT_DIR}/doc/e-CAM82/e-CAM82_CUOAGX/e-CAM_YUV-OCTA-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.4.3_10-FEB-2025_R02"
NILECAM81_JP6_DIR="${SCRIPT_DIR}/doc/NileCAM81/NileCAM81_CUOAGX/JP6.0_L4T36.3.0/e-CAM_YUV-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.3.0_09-AUG-2024_R03"

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
echo "║   Câmeras do projeto (alternáveis, 1 por boot):   ║"
echo "║     • e-CAM82  (IMX485, MIPI)  — principal        ║"
echo "║     • NileCAM81 (GMSL/AR0821)  — alternativa      ║"
echo "║   Flash necessário: JP 5.1.0 / L4T 35.2.1         ║"
echo "║   (kernel 5.10.104-tegra — alvo das duas)         ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Menu principal ───────────────────────────────────────────────────────────

if [[ $AUTO -eq 1 ]]; then
    choice=1
    log_info "Modo automático: instalando opção 1 — e-CAM82 (IMX485, MIPI)."
else
    echo "Qual driver deseja instalar?"
    echo ""
    echo "  1) e-CAM82 (IMX485, MIPI)   — L4T 35.2.1 / JP 5.1.0  ✓ câmera principal"
    echo "  2) NileCAM81 (GMSL/AR0821)  — L4T 35.2.1 / JP 5.1.0  ✓ câmera alternativa (mesmo flash;"
    echo "                                exige a placa desserializadora GMSL no J509)"
    echo "  3) [GMSL] e-CAM YUV OCTA (AR0821) — L4T 36.4.3 / JP 6.2  ⚠ OUTRO produto"
    echo "  4) [GMSL] NileCAM81 p/ JP6 — L4T 36.3.0 / JP 6.0  ⚠ exige reflash p/ JP6 (use a opção 2)"
    echo ""
    read -rp "Escolha [1–4]: " choice
fi

# ── e-CAM82 IMX485 (MIPI) — pacote correto ────────────────────────────────────

# Garante que o binário do driver (rastreado por Git LFS) foi baixado de fato,
# e não é apenas o ponteiro LFS (o que acontece ao baixar o repo como .zip).
# $1 = diretório do pacote (contém o .tar.gz do driver no primeiro nível).
ensure_lfs_payload() {
    local pkg_dir="${1:-$ECAM82_IMX485_DIR}" pkg_tar
    pkg_tar=$(find "${pkg_dir}" -maxdepth 1 -name '*.tar.gz' -print -quit 2>/dev/null || true)
    if [[ -z "$pkg_tar" || ! -f "$pkg_tar" ]]; then
        log_error "Pacote .tar.gz do driver não encontrado em ${pkg_dir}."
        return 1
    fi

    local size
    size=$(stat -c%s "$pkg_tar" 2>/dev/null || echo 0)
    if [[ "$size" -ge 1048576 ]]; then
        return 0   # binário real já presente
    fi

    log_warn "O pacote do driver tem apenas ${size} bytes — é um ponteiro Git LFS, não o binário."
    log_warn "Isso ocorre ao baixar o repositório como .zip: o GitHub não inclui o conteúdo LFS."

    if git -C "${SCRIPT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        if ! command -v git-lfs >/dev/null 2>&1; then
            log_info "Instalando git-lfs..."
            { apt-get update -qq && apt-get install -y git-lfs; } || log_warn "Falha ao instalar git-lfs."
        fi
        log_info "Baixando objetos LFS (git lfs pull)..."
        git -C "${SCRIPT_DIR}" lfs install || true
        git -C "${SCRIPT_DIR}" lfs pull   || log_warn "git lfs pull falhou."
        size=$(stat -c%s "$pkg_tar" 2>/dev/null || echo 0)
    fi

    if [[ "$size" -lt 1048576 ]]; then
        log_error "Não foi possível obter o binário completo do driver via Git LFS."
        log_error "Clone o repositório com LFS em vez de baixar o .zip:"
        log_error "  sudo apt install -y git git-lfs && git lfs install"
        log_error "  git clone https://github.com/SEESTEC/CANPass.git && cd CANPass && git lfs pull"
        return 1
    fi
    log_ok "Binário do driver obtido via LFS (${size} bytes)."
    return 0
}

# Copia os DTBs com NOME PRÓPRIO do pacote para /boot — é neles que o
# 'canpass-camera switch' aponta a linha FDT do extlinux para alternar as câmeras.
# Precisa rodar ANTES do install_binaries.sh da e-con, que reboota o Orin ao final.
# (O instalador da e-con só grava o DTB no nome GENÉRICO kernel_tegra234-*.dtb,
#  que a outra câmera sobrescreveria.)
install_named_dtbs() {
    local pkg_dir="$1"; shift
    local pat dtb copied=0
    for pat in "$@"; do
        for dtb in "${pkg_dir}"/misc/${pat}; do
            [[ -f "$dtb" ]] || continue
            cp -f "$dtb" /boot/ && { log_ok "DTB p/ alternância copiado: /boot/$(basename "$dtb")"; copied=1; }
        done
    done
    [[ $copied -eq 1 ]] || log_warn "Nenhum DTB nomeado encontrado em ${pkg_dir}/misc — 'canpass-camera switch' pode não achar o DTB."
}

install_ecam82_imx485() {
    if [[ ! -d "${ECAM82_IMX485_DIR}" ]]; then
        log_error "Pasta '${ECAM82_IMX485_DIR}' não encontrada. Clone o repositório com git-lfs (git clone + git lfs pull)."
        exit 1
    fi

    # Garante que o binário do driver (LFS) está presente, não um ponteiro.
    ensure_lfs_payload "${ECAM82_IMX485_DIR}" || exit 1

    # Confere se o kernel do Orin casa com o alvo do pacote (5.10.104-tegra)
    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.10.104"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER}"
        log_warn "Este pacote foi compilado para 5.10.104-tegra (L4T 35.2.1 / JP 5.1.0)."
        log_warn "O instalador da e-con confere /etc/nv_tegra_release e ABORTA se o L4T"
        log_warn "não casar exatamente (ex.: L4T 35.6.4 será rejeitado)."
        if [[ $AUTO -eq 1 ]]; then
            log_error "Flash incompatível — reflasheie o Orin com L4T 35.2.1 / JP 5.1.0 e rode novamente."
            exit 1
        fi
        log_warn "Flasheie o Orin com L4T 35.2.1 / JetPack 5.1.0 antes de prosseguir."
        echo ""
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    local lane_variant
    if [[ $AUTO -eq 1 ]]; then
        lane_variant=2   # 4 lanes — configuração do AGX Orin
        log_info "Modo automático: 4 lanes (variante 2)."
    else
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
    fi

    # DTBs nomeados p/ o canpass-camera switch — antes do instalador (que reboota).
    install_named_dtbs "${ECAM82_IMX485_DIR}" "tegra234-*eimx485*.dtb"

    log_info "Iniciando instalação e-CAM82 IMX485 (lanes ${lane_variant})..."
    log_warn "O instalador da e-con REBOOTA o Orin automaticamente ao final."
    cd "${ECAM82_IMX485_DIR}"
    # O install_binaries.sh da e-con lê a configuração de lane via stdin
    # (1=2lane, 2=4lane) — passamos a escolha diretamente pelo pipe.
    echo "${lane_variant}" | bash install_binaries.sh
}

# ── NileCAM81 (GMSL) p/ L4T 35.2.1 — câmera ALTERNATIVA do projeto ───────────
# Build R02 solicitado à e-con (2026-06): MESMO L4T/kernel da e-CAM82, permitindo
# os dois drivers no flash atual e alternância por boot via 'canpass-camera switch'.

install_nilecam81_3521() {
    log_warn "NileCAM81 é a câmera ALTERNATIVA (GMSL2). Ela exige o kit GMSL no lugar"
    log_warn "da base board MIPI: desserializadora e-CAM_CUOAGX_DESER_6H01R1 no J509 +"
    log_warn "serializador + cabo coaxial FAKRA + fonte 12 V. Sem esse hardware não há imagem."
    log_warn ""
    log_warn "O instalador da e-con SUBSTITUI /boot/Image e o DTB genérico (backup automático"
    log_warn "em ~/Images_Backup) e REBOOTA o Orin ao final. Após o reboot, use"
    log_warn "'canpass-camera switch ecam82|nilecam81' para fixar a câmera desejada."
    read -rp "Prosseguir com a instalação? [s/N]: " confirm
    [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }

    if [[ ! -d "${NILECAM81_3521_DIR}" ]]; then
        log_error "Pasta '${NILECAM81_3521_DIR}' não encontrada. Atualize o repo (git pull && git lfs pull)."
        exit 1
    fi

    ensure_lfs_payload "${NILECAM81_3521_DIR}" || exit 1

    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.10.104"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER} (alvo: 5.10.104-tegra / L4T 35.2.1 / JP 5.1.0)."
        log_warn "O instalador da e-con confere /etc/nv_tegra_release e ABORTA se não casar."
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    # DTBs nomeados p/ o canpass-camera switch — antes do instalador (que reboota).
    install_named_dtbs "${NILECAM81_3521_DIR}" "tegra234-*nilecam81*.dtb"

    log_info "Iniciando instalação NileCAM81 (L4T 35.2.1, two-lane)..."
    cd "${NILECAM81_3521_DIR}"
    bash install_binaries.sh
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

# ── [GMSL] NileCAM81 p/ JP6 — exige reflash p/ L4T 36.3.0 ────────────────────

install_nilecam81_jp6() {
    log_warn "Este build da NileCAM81 é para L4T 36.3.0 / JP 6.0 — NÃO roda no flash"
    log_warn "atual do projeto (35.2.1). Para usar a NileCAM81 sem reflash, use a OPÇÃO 2."
    read -rp "Tem certeza que quer prosseguir? [s/N]: " confirm
    [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }

    if [[ ! -d "${NILECAM81_JP6_DIR}" ]]; then
        log_error "Pasta '${NILECAM81_JP6_DIR}' não encontrada. Verifique o git pull."
        exit 1
    fi

    KERNEL_VER="$(uname -r)"
    if [[ "${KERNEL_VER}" != *"5.15.136"* ]]; then
        log_warn "Kernel detectado: ${KERNEL_VER} (alvo: 5.15.136-tegra / L4T 36.3.0)."
        read -rp "Continuar mesmo assim? [s/N]: " confirm
        [[ "${confirm,,}" == "s" ]] || { log_info "Cancelado."; exit 0; }
    fi

    log_info "Iniciando instalação NileCAM81 (JP6)..."
    cd "${NILECAM81_JP6_DIR}"
    bash install_binaries.sh 81
}

# ── Execução ─────────────────────────────────────────────────────────────────

case "${choice}" in
    1) install_ecam82_imx485 ;;
    2) install_nilecam81_3521 ;;
    3) install_gmsl_octa ;;
    4) install_nilecam81_jp6 ;;
    *)
        log_error "Opção inválida: '${choice}'. Escolha 1, 2, 3 ou 4."
        exit 1
        ;;
esac
