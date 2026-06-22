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
FIELD_ENV="/usr/local/share/canpass/canpass-field.env"

# NTP/fuso de campo: o Orin serve o próprio relógio como NTP p/ a sub-rede
# (câmeras IP sincronizam aqui) e roda no fuso de Brasília — assim vídeo, log CAN
# e OSD das câmeras compartilham a MESMA base de tempo. Ajustáveis via ambiente.
TIMEZONE="${CANPASS_TZ:-America/Sao_Paulo}"
NTP_ALLOW_SUBNET="${CANPASS_NTP_SUBNET:-192.168.20.0/24}"

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
    local systemctl_bin nvpmodel_bin jetson_clocks_bin ip_bin modprobe_bin reboot_bin
    systemctl_bin="$(command -v systemctl || echo /bin/systemctl)"
    nvpmodel_bin="$(command -v nvpmodel || true)"
    jetson_clocks_bin="$(command -v jetson_clocks || true)"
    ip_bin="$(command -v ip || echo /usr/sbin/ip)"
    modprobe_bin="$(command -v modprobe || echo /usr/sbin/modprobe)"
    reboot_bin="$(command -v reboot || echo /sbin/reboot)"

    # cam_view.sh, no caminho CSI, reinicia o nvargus-daemon e maximiza os clocks
    # (nvpmodel/jetson_clocks + max-isp-vi-clks.sh da e-con) sem senha, via sudo -n.
    # 'ip *': o canpass-can log roda em BACKGROUND (sem tty p/ pedir senha) e
    # precisa de sudo p/ configurar/subir/derrubar a interface CAN do CANable.
    local -a cmds=("${systemctl_bin} restart nvargus-daemon")
    [[ -n "$nvpmodel_bin" ]]      && cmds+=("${nvpmodel_bin} -m 0")
    [[ -n "$jetson_clocks_bin" ]] && cmds+=("${jetson_clocks_bin}")
    cmds+=("${ip_bin} *")
    cmds+=("${CALLING_HOME}/max-isp-vi-clks.sh")   # caminho determinístico; inofensivo se ausente
    # Recuperação da NileCAM81 travada (MCU em -121): cam_view.sh recarrega o
    # ar0821 sem reboot — precisa de modprobe sem senha (roda sem tty).
    cmds+=("${modprobe_bin} -r ar0821" "${modprobe_bin} ar0821")
    # FIELD: recuperação automática quando a câmera não enumera no boot — cam_view.sh
    # reinicia o Orin (reset garantido do link GMSL). Sem tty → precisa NOPASSWD.
    cmds+=("${systemctl_bin} reboot" "${reboot_bin}")

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

# ─── 1c-bis. Servidor NTP + fuso de Brasília ─────────────────────────────────
# Unifica o horário do sistema (vídeo + log CAN usam o relógio do Orin) e serve
# esse horário como NTP p/ as câmeras IP da sub-rede — em campo NÃO há internet,
# então o chrony serve o PRÓPRIO relógio (local stratum). NÃO instala pacote aqui
# (o apt roda só no install completo, na etapa de dependências); se o chrony não
# estiver presente, apenas avisa — assim o 'canpass update' offline não quebra.
setup_ntp_server() {
    # Fuso horário (não depende de rede).
    if command -v timedatectl >/dev/null 2>&1; then
        if $SUDO_CMD timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
            log_ok "Fuso horário do Orin: ${TIMEZONE}."
        else
            log_warn "Não consegui definir o fuso ${TIMEZONE} (timedatectl)."
        fi
    fi

    if ! command -v chronyc >/dev/null 2>&1 && [[ ! -x /usr/sbin/chronyd && ! -x /usr/bin/chronyd ]]; then
        log_warn "chrony ausente — Orin NÃO será servidor NTP. (rode o install.sh completo c/ rede)"
        return 0
    fi

    local conf="/etc/chrony/chrony.conf"
    [[ -f "$conf" ]] || conf="/etc/chrony.conf"
    if [[ ! -f "$conf" ]]; then
        log_warn "chrony.conf não encontrado — Orin não configurado como servidor NTP."
        return 0
    fi

    # Bloco gerenciado idempotente: remove o antigo e reescreve.
    local tmp; tmp=$(mktemp)
    $SUDO_CMD sed '/# >>> CANPASS NTP/,/# <<< CANPASS NTP/d' "$conf" 2>/dev/null > "$tmp"
    {
        echo "# >>> CANPASS NTP (gerenciado pelo install.sh — não editar à mão) >>>"
        echo "# Serve o relógio do Orin como NTP p/ a sub-rede de campo, mesmo SEM"
        echo "# upstream/internet (local stratum) — assim câmeras + CAN + vídeo ficam"
        echo "# com a MESMA base de tempo (uniforme). Câmeras IP apontam o NTP p/ o Orin."
        echo "allow ${NTP_ALLOW_SUBNET}"
        echo "local stratum 10"
        echo "# rtcsync: mantém o RTC de hardware disciplinado (~11 min) — com bateria"
        echo "# de backup no carrier, a hora REAL sobrevive ao power-off offline."
        echo "rtcsync"
        echo "# <<< CANPASS NTP (gerenciado pelo install.sh — não editar à mão) <<<"
    } >> "$tmp"
    $SUDO_CMD cp "$tmp" "$conf" && rm -f "$tmp"

    # Habilita + reinicia o serviço (o nome varia entre distros: chrony | chronyd).
    # 'systemctl cat' é o teste de existência confiável (o list-unit-files|grep
    # falhava em algumas versões e o bloco acima ficava sem ser aplicado).
    local svc="" s
    for s in chrony chronyd; do
        if $SUDO_CMD systemctl cat "${s}.service" >/dev/null 2>&1; then svc="$s"; break; fi
    done
    if [[ -z "$svc" ]]; then
        log_warn "Serviço chrony não encontrado p/ habilitar — verifique manualmente (systemctl status chrony)."
        return 0
    fi
    $SUDO_CMD systemctl enable "$svc" >/dev/null 2>&1
    if $SUDO_CMD systemctl restart "$svc" >/dev/null 2>&1; then
        log_ok "Servidor NTP ativo (${svc}) — servindo ${NTP_ALLOW_SUBNET}; câmeras usam o IP do Orin como NTP."
    else
        log_warn "chrony configurado mas não reiniciou — 'sudo systemctl restart ${svc}' e verifique 'chronyc sources'."
    fi

    # ── Persistência da hora REAL offline ────────────────────────────────────
    # Sem internet, a hora real entre power-offs depende do RTC. Semeia o RTC com
    # a hora atual AGORA (se há internet no setup, já é a hora certa) e liga o
    # fake-hwclock como rede de segurança: sem bateria no RTC, o Orin passa a
    # bootar na ÚLTIMA hora conhecida em vez do default de fábrica (visto: 2024).
    # Semeia TODOS os RTCs presentes (o Jetson expõe rtc0=tegra e rtc1=PMIC; o
    # /dev/rtc pode apontar p/ o sem bateria). Escrever a hora boa em ambos
    # maximiza a chance de o RTC que o kernel lê no boot estar correto.
    local rtc seeded=0
    for rtc in /dev/rtc0 /dev/rtc1 /dev/rtc; do
        [[ -e "$rtc" ]] || continue
        $SUDO_CMD hwclock --systohc -f "$rtc" 2>/dev/null && seeded=1
    done
    if (( seeded )); then
        log_ok "RTC(s) de hardware semeados com a hora atual (rtc0: $($SUDO_CMD hwclock -r -f /dev/rtc0 2>/dev/null | head -1))."
        log_warn "Se algum RTC voltar a 1969/2024 após power-off, é falta de BATERIA de backup no carrier — sem ela a hora real offline depende do fake-hwclock + seed no deploy."
    else
        log_warn "Sem /dev/rtc gravável — a hora real offline dependerá do fake-hwclock + seed no deploy."
    fi
    if $SUDO_CMD systemctl cat fake-hwclock.service >/dev/null 2>&1; then
        $SUDO_CMD systemctl enable --now fake-hwclock >/dev/null 2>&1 \
            && log_ok "fake-hwclock ativo (boota na última hora conhecida se o RTC perder energia)." \
            || log_warn "fake-hwclock presente mas não ativou — 'sudo systemctl enable --now fake-hwclock'."
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

    # Comandos canpass-*: instalados SEM o sufixo .sh (voltados ao usuário).
    local cc src
    for cc in canpass-camera canpass-can; do
        src="${SCRIPT_DIR}/.rsc/${cc}.sh"
        [[ -f "$src" ]] || continue
        $SUDO_CMD install -m 755 "$src" "${INSTALL_DIR}/${cc}"
        log_ok "${cc} instalado em ${INSTALL_DIR}/${cc}."
    done

    # Registra o diretório-fonte para 'canpass-camera update' (git pull + recopia).
    if [[ -f "${SCRIPT_DIR}/.rsc/canpass-camera.sh" ]]; then
        $SUDO_CMD install -d /usr/local/share/canpass
        echo "${SCRIPT_DIR}" | $SUDO_CMD tee /usr/local/share/canpass/src_dir >/dev/null
        log_ok "Repo-fonte registrado para 'canpass-camera update': ${SCRIPT_DIR}"
    fi

    # Perfil de CAMPO: instala o canpass-field.env onde o serviço systemd o lê.
    # Define câmeras IP do projeto + gravação contínua + ts sup-esq + CAN 250k etc.
    if [[ -f "${SCRIPT_DIR}/.rsc/canpass-field.env" ]]; then
        $SUDO_CMD install -d /usr/local/share/canpass
        $SUDO_CMD install -m 644 "${SCRIPT_DIR}/.rsc/canpass-field.env" "$FIELD_ENV"
        log_ok "Perfil de campo instalado em ${FIELD_ENV}."
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
# network-online: as câmeras IP do perfil de campo precisam da rede de pé no boot
# (mesmo com retry no cam_view, evita falhas iniciais e o chrony NTP sobe antes).
After=docker.service network-online.target chrony.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=${CALLING_USER}
# Perfil de CAMPO: câmeras IP do projeto + gravação contínua + ts sup-esq +
# CAN 250k humano + sem entrevista. '-' = não falha se o arquivo não existir.
EnvironmentFile=-${FIELD_ENV}
ExecStartPre=-/bin/systemctl restart nvargus-daemon
ExecStart=${INSTALL_DIR}/watchdog.sh --all
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

    # Habilita no boot automaticamente — o produto de campo deve subir sozinho
    # quando o Orin liga, sem depender de login/terminal.
    if $SUDO_CMD systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1; then
        log_ok "Serviço '${SERVICE_NAME}' habilitado no boot."
    else
        log_warn "Falha ao habilitar '${SERVICE_NAME}' no boot — habilite manualmente: sudo systemctl enable ${SERVICE_NAME}"
    fi

    log_info "Comandos úteis:"
    log_info "  sudo systemctl start    ${SERVICE_NAME}   # inicia agora"
    log_info "  sudo systemctl disable  ${SERVICE_NAME}   # desabilita no boot"
    log_info "  sudo systemctl status   ${SERVICE_NAME}   # verifica estado"
    log_info "  sudo systemctl stop     ${SERVICE_NAME}   # encerra"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    # --update: atualização leve (chamada pelo 'canpass update' após o git pull) —
    # recopia scripts e reaplica sudoers/alias/serviço, SEM apt/docker/driver
    # (não depende de rede nem dispara instalação de driver em campo).
    if [[ "${1:-}" == "--update" || "${1:-}" == "update" ]]; then
        log_step "Atualização — scripts, sudoers, NTP, alias e serviço (sem deps/driver)"
        setup_jetson_sudoers
        setup_ntp_server       # fuso + config NTP (não instala pacote; offline-safe)
        install_scripts
        setup_alias
        setup_systemd_service
        echo
        log_ok "Atualização concluída."
        return 0
    fi

    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║       CANPass — Instalador           ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"

    log_step "1/5 — Instalando dependências"
    install_apt_package ffmpeg ffplay
    install_apt_package v4l-utils v4l2-ctl
    install_apt_package can-utils candump   # canpass-can (CANable/J1939)
    install_apt_package curl curl           # controles de imagem de câmera IP (HTTP API)
    install_apt_package chrony chronyc      # Orin como servidor NTP (horário unificado de campo)
    install_docker
    install_jetson_gstreamer
    setup_jetson_sudoers
    setup_ntp_server        # fuso de Brasília + Orin como servidor NTP da sub-rede

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
    log_info "O serviço sobe sozinho no próximo boot do Orin."
    log_info "Para usar agora: source ~/.bashrc && canpass"
    if [[ $NEED_REBOOT -eq 1 ]]; then
        log_warn "REINICIE o Orin para ativar o driver da câmera:  sudo reboot"
    fi
    echo -e "${CYAN}────────────────────────────────────────${NC}"
}

main "$@"
