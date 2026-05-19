#!/usr/bin/env bash
# Copia os pacotes de driver para o Jetson AGX Orin via SCP.
# Uso: bash copy_to_orin.sh <IP_DO_ORIN> [usuario]
# Exemplo: bash copy_to_orin.sh 192.168.55.1 nvidia

set -euo pipefail

ORIN_IP="${1:?Uso: $0 <IP_DO_ORIN> [usuario]  Ex: $0 192.168.55.1 nvidia}"
ORIN_USER="${2:-nvidia}"
REMOTE="${ORIN_USER}@${ORIN_IP}"
DEST="~/econ_drivers"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NILECAM81_SRC="${SCRIPT_DIR}/NileCAM81_CUOAGX/JP6.0_L4T36.3.0/e-CAM_YUV-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.3.0_09-AUG-2024_R03"
ECAM82_SRC="${SCRIPT_DIR}/e-CAM82_CUOAGX_L4T36.4.3/e-CAM_YUV-OCTA-GMSL-PRODUCTS_JETSON_AGX_ORIN_L4T36.4.3_10-FEB-2025_R02"

echo "============================================="
echo " Copiando drivers para ${REMOTE}:${DEST}"
echo "============================================="

echo "[1/4] Criando estrutura de pastas no Orin..."
ssh "${REMOTE}" "mkdir -p ${DEST}"

echo "[2/4] Copiando NileCAM81 (L4T36.3.0 — JP6.0)..."
scp -r "${NILECAM81_SRC}" "${REMOTE}:${DEST}/nilecam81"

echo "[3/4] Copiando e-CAM82 (L4T36.4.3 — JP6.2)..."
scp -r "${ECAM82_SRC}" "${REMOTE}:${DEST}/ecam82"

echo "[4/4] Copiando script de instalação..."
scp "${SCRIPT_DIR}/install_drivers.sh" "${REMOTE}:${DEST}/install_drivers.sh"
ssh "${REMOTE}" "chmod +x ${DEST}/install_drivers.sh"

echo ""
echo "============================================="
echo " Pronto! No terminal do Orin execute:"
echo "   cd ~/econ_drivers"
echo "   sudo bash install_drivers.sh"
echo "============================================="
