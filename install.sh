#!/usr/bin/env bash
# install.sh — Instala dependências, configura alias e serviço systemd do CANPass.

set -uo pipefail

# ─── Cores / log ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

# ─── Constantes ──────────────────────────────────────────────────────────────
INSTALL_DIR="/usr/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="canpass"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Preserva o usuário real mesmo quando executado via sudo
CALLING_USER="${SUDO_USER:-$USER}"
CALLING_HOME=$(eval echo "~${CALLING_USER}")
BASHRC="${CALLING_HOME}/.bashrc"

SUDO_CMD=""
[[ $EUID -ne 0 ]] && SUDO_CMD="sudo"

# ─── 1. Dependências ─────────────────────────────────────────────────────────

install_apt_package() {
    local package="$1"
    local command="${2:-$1}"

    if command -v "$command" &>/dev/null; then
        log_ok "${command} já instalado em $(command -v "$command")."
        return 0
    fi

    log_warn "${command} não encontrado. Instalando ${package}..."
    $SUDO_CMD apt-get update -qq
    $SUDO_CMD apt-get install -y "$package"

    if command -v "$command" &>/dev/null; then
        log_ok "${package} instalado com sucesso."
    else
        log_error "Falha ao instalar ${package}. Abortando."
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        log_ok "docker já instalado em $(command -v docker)."
    else
        log_warn "docker não encontrado. Executando docker-install.sh..."
        local installer="${SCRIPT_DIR}/.rsc/docker-install.sh"
        if [[ ! -f "$installer" ]]; then
            log_error "docker-install.sh não encontrado em ${SCRIPT_DIR}/.rsc/. Abortando."
            exit 1
        fi
        bash "$installer"
        command -v docker &>/dev/null || { log_error "Falha ao instalar docker."; exit 1; }
        log_ok "docker instalado com sucesso."
    fi

    if ! groups "$CALLING_USER" | grep -q '\bdocker\b'; then
        $SUDO_CMD usermod -aG docker "$CALLING_USER"
        log_ok "Usuário '${CALLING_USER}' adicionado ao grupo docker."
        log_warn "Faça logout/login ou execute 'newgrp docker' para aplicar."
    else
        log_ok "Usuário '${CALLING_USER}' já está no grupo docker."
    fi
}

# ─── 2. Scripts ──────────────────────────────────────────────────────────────

install_scripts() {
    for script in cam_view.sh watchdog.sh; do
        local source_path="${SCRIPT_DIR}/.rsc/${script}"
        local dest_path="${INSTALL_DIR}/${script}"

        if [[ ! -f "$source_path" ]]; then
            log_error "${source_path} não encontrado. Abortando."
            exit 1
        fi

        chmod +x "$source_path"
        $SUDO_CMD cp "$source_path" "$dest_path"
        $SUDO_CMD chmod +x "$dest_path"
        log_ok "${script} instalado em ${dest_path}."
    done
}

# ─── 3. Alias ────────────────────────────────────────────────────────────────

setup_alias() {
    local alias_line="alias canpass='${INSTALL_DIR}/watchdog.sh'"

    # Remove versões anteriores do alias para evitar duplicatas
    if grep -q "alias canpass=" "$BASHRC" 2>/dev/null; then
        sed -i '/# CANPass camera viewer/d' "$BASHRC"
        sed -i '/alias canpass=/d' "$BASHRC"
        log_warn "Alias anterior removido de ${BASHRC}."
    fi

    printf '\n# CANPass camera viewer\n%s\n' "$alias_line" >> "$BASHRC"
    log_ok "Alias 'canpass' configurado em ${BASHRC}."
    log_info "Execute 'source ~/.bashrc' ou abra um novo terminal para ativar."
}

# ─── 4. Systemd ──────────────────────────────────────────────────────────────

setup_systemd_service() {
    $SUDO_CMD tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=CANPass Camera Watchdog
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
User=${CALLING_USER}
ExecStart=${INSTALL_DIR}/watchdog.sh
Restart=on-failure
RestartSec=3
SuccessExitStatus=0 130 143
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes

[Install]
WantedBy=multi-user.target
EOF

    $SUDO_CMD systemctl daemon-reload
    log_ok "Serviço '${SERVICE_NAME}' criado em ${SERVICE_FILE}."
    log_info "Comandos úteis:"
    log_info "  sudo systemctl start   ${SERVICE_NAME}   # inicia agora"
    log_info "  sudo systemctl enable  ${SERVICE_NAME}   # habilita no boot"
    log_info "  sudo systemctl status  ${SERVICE_NAME}   # verifica estado"
    log_info "  sudo systemctl stop    ${SERVICE_NAME}   # encerra"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║       CANPass — Instalador           ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    log_step "1/4 — Instalando dependências"
    install_apt_package ffmpeg ffplay
    install_apt_package v4l-utils v4l2-ctl
    install_docker

    log_step "2/4 — Instalando scripts em ${INSTALL_DIR}"
    install_scripts

    log_step "3/4 — Configurando alias 'canpass'"
    setup_alias

    log_step "4/4 — Configurando serviço systemd"
    setup_systemd_service

    echo
    log_ok "Instalação concluída!"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    log_info "Para usar: source ~/.bashrc && canpass"
    echo -e "${CYAN}────────────────────────────────────────${NC}"

    log_info "Removendo arquivos de instalação..."
    [[ -f "${CALLING_HOME}/main.zip" ]] && rm -f "${CALLING_HOME}/main.zip" && log_info "main.zip removido."
    echo "$SCRIPT_DIR" > /tmp/.canpass_src_dir
    find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 ! -name "install.sh" -exec rm -rf {} \;
}

main "$@"
