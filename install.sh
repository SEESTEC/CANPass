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

# Sinaliza, ao final, que o Orin precisa reiniciar para o driver entrar em vigor.
NEED_REBOOT=0

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

# ─── 1b. GStreamer NVIDIA (apenas Jetson/Tegra) ───────────────────────────────

install_jetson_gstreamer() {
    grep -aqE "nvidia" /proc/device-tree/compatible 2>/dev/null || return 0
    log_info "Plataforma Jetson detectada — instalando GStreamer com suporte CSI..."
    $SUDO_CMD apt-get install -y \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        nvidia-l4t-multimedia 2>/dev/null \
        || log_warn "Alguns pacotes GStreamer NVIDIA não disponíveis — câmeras CSI podem não funcionar."
    log_ok "Pacotes GStreamer instalados."
}

# ─── 1c. Sudoers nvargus-daemon (apenas Jetson/Tegra) ────────────────────────
# Permite que o usuário reinicie o nvargus-daemon sem senha.
# Necessário porque sessões CSI encerradas abruptamente deixam o daemon em estado
# inválido; cam_view.sh reinicia o daemon automaticamente antes de cada stream.

setup_jetson_sudoers() {
    grep -aqE "nvidia" /proc/device-tree/compatible 2>/dev/null || return 0
    local sudoers_file="/etc/sudoers.d/canpass-nvargus"

    # Resolve caminhos (variam entre layouts L4T); só inclui o que existe.
    local systemctl_bin nvpmodel_bin jetson_clocks_bin
    systemctl_bin="$(command -v systemctl || echo /bin/systemctl)"
    nvpmodel_bin="$(command -v nvpmodel || true)"
    jetson_clocks_bin="$(command -v jetson_clocks || true)"

    # cam_view.sh, no caminho CSI, reinicia o nvargus-daemon e maximiza os clocks
    # (nvpmodel/jetson_clocks + max-isp-vi-clks.sh da e-con) sem senha, via sudo -n.
    local -a cmds=("${systemctl_bin} restart nvargus-daemon")
    [[ -n "$nvpmodel_bin" ]]      && cmds+=("${nvpmodel_bin} -m 0")
    [[ -n "$jetson_clocks_bin" ]] && cmds+=("${jetson_clocks_bin}")
    cmds+=("${CALLING_HOME}/max-isp-vi-clks.sh")   # caminho determinístico; inofensivo se ausente

    local joined
    joined=$(IFS=,; echo "${cmds[*]}")

    echo "${CALLING_USER} ALL=(ALL) NOPASSWD: ${joined}" | $SUDO_CMD tee "$sudoers_file" > /dev/null
    $SUDO_CMD chmod 440 "$sudoers_file"

    # Valida a sintaxe — um sudoers inválido pode travar o sudo do sistema inteiro.
    if $SUDO_CMD visudo -cf "$sudoers_file" >/dev/null 2>&1; then
        log_ok "Permissões NOPASSWD (nvargus + clocks) configuradas em ${sudoers_file}."
    else
        log_warn "Regra sudoers inválida — removendo ${sudoers_file} por segurança."
        $SUDO_CMD rm -f "$sudoers_file"
    fi
}

# ─── 1d. Driver de câmera e-CAM82 (apenas Jetson/Tegra) ──────────────────────
# Instala automaticamente o driver CORRETO (IMX485) de forma não-interativa.
# Pula se não for Jetson ou se a câmera já enumera (/dev/video0 presente).

install_ecam82_driver() {
    if ! grep -aqE "nvidia" /proc/device-tree/compatible 2>/dev/null; then
        log_info "Plataforma não-Jetson — driver de câmera CSI não se aplica."
        return 0
    fi

    if [[ -e /dev/video0 ]]; then
        log_ok "Câmera já enumera em /dev/video0 — driver e-CAM82 presumido instalado. Pulando."
        return 0
    fi

    local drv_installer="${SCRIPT_DIR}/install_drivers.sh"
    if [[ ! -f "$drv_installer" ]]; then
        log_warn "install_drivers.sh não encontrado em ${SCRIPT_DIR} — pulando instalação do driver."
        return 0
    fi

    log_info "Nenhuma câmera CSI ativa — instalando driver e-CAM82 (IMX485) automaticamente..."
    if bash "$drv_installer" --auto; then
        log_ok "Driver e-CAM82 instalado."
        NEED_REBOOT=1
    else
        log_warn "Instalação automática do driver não concluída."
        log_warn "Causas comuns: flash L4T incompatível (precisa L4T 35.2.1 / JP 5.1.0) ou"
        log_warn "pacote de driver ausente (baixe o repo via 'git clone' + 'git lfs pull', não .zip)."
        log_warn "Para tentar manualmente:  sudo bash ${drv_installer}"
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

        $SUDO_CMD install -m 755 "$source_path" "$dest_path"
        log_ok "${script} instalado em ${dest_path}."
    done

    # canpass-camera: instalado SEM o sufixo .sh (comando voltado ao usuário).
    local cc_src="${SCRIPT_DIR}/.rsc/canpass-camera.sh"
    if [[ -f "$cc_src" ]]; then
        $SUDO_CMD install -m 755 "$cc_src" "${INSTALL_DIR}/canpass-camera"
        log_ok "canpass-camera instalado em ${INSTALL_DIR}/canpass-camera."

        # Registra o diretório-fonte para 'canpass-camera update' (git pull + recopia).
        $SUDO_CMD install -d /usr/local/share/canpass
        echo "${SCRIPT_DIR}" | $SUDO_CMD tee /usr/local/share/canpass/src_dir >/dev/null
        log_ok "Repo-fonte registrado para 'canpass-camera update': ${SCRIPT_DIR}"
    fi
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
ExecStartPre=-/bin/systemctl restart nvargus-daemon
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

    log_step "1/5 — Instalando dependências"
    install_apt_package ffmpeg ffplay
    install_apt_package v4l-utils v4l2-ctl
    install_docker
    install_jetson_gstreamer
    setup_jetson_sudoers

    log_step "2/5 — Instalando driver de câmera (Jetson)"
    install_ecam82_driver

    log_step "3/5 — Instalando scripts em ${INSTALL_DIR}"
    install_scripts

    log_step "4/5 — Configurando alias 'canpass'"
    setup_alias
    # Carrega o alias na sessão atual sem precisar fechar o terminal
    # shellcheck disable=SC1090
    source "$BASHRC" 2>/dev/null || true

    log_step "5/5 — Configurando serviço systemd"
    setup_systemd_service

    echo
    log_ok "Instalação concluída!"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    log_info "Para usar: source ~/.bashrc && canpass"
    if [[ $NEED_REBOOT -eq 1 ]]; then
        log_warn "REINICIE o Orin para ativar o driver da câmera:  sudo reboot"
    fi
    echo -e "${CYAN}────────────────────────────────────────${NC}"
}

main "$@"
