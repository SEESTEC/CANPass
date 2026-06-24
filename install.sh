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
# NTP UPSTREAM (cliente): por padrão usa os pools públicos do chrony (internet).
# Em rede SEM saída p/ internet mas COM um servidor de hora interno (NTP corporativo,
# roteador que serve NTP, ou um PC da bancada), aponte aqui — assim o Orin SINCRONIZA
# a hora real como um PC normal, mesmo sem internet pública. Vários separados por
# espaço/vírgula. Ex.: CANPASS_NTP_UPSTREAM="10.105.4.1 192.168.1.190".
# Vazio = mantém os pools default do chrony.conf (só funcionam com internet pública).
NTP_UPSTREAM="${CANPASS_NTP_UPSTREAM:-}"
# Sub-redes que o servidor NTP atende: por padrão TODAS as sub-redes conectadas
# (uma 'allow' por interface), não só a da rota default. O Orin de campo é
# multi-homed (ex.: eth0 = LAN das câmeras 192.168.20.x + wlan0 = internet/NTP
# upstream 192.168.x): autodetectar SÓ a rota default pegava a wlan0 e as câmeras
# do eth0 ficavam sem servidor de hora. Override fixo: CANPASS_NTP_SUBNET=...
# (resolvido em setup_ntp_server, não aqui).

# Lista as sub-redes IPv4 conectadas (rotas scope-link do kernel), uma por linha,
# excluindo loopback, docker/bridges/veth e link-local (169.254). Ex. de saída:
#   10.105.4.0/24
#   192.168.20.0/24
_connected_subnets() {
    ip -4 route show scope link proto kernel 2>/dev/null | awk '
        { net=$1; dev=""; for (i=1;i<=NF;i++) if ($i=="dev") dev=$(i+1) }
        net ~ /\// && net !~ /^169\.254/ && dev !~ /^(lo|docker|br-|veth)/ { print net }
    ' | sort -u
}

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

    # Helper root que MONTA discos USB (com filesystem) ainda não montados — sem
    # depender do auto-mount do desktop, que num boot HEADLESS (sem autologin) não
    # roda, e do udisksctl, que o polkit nega no contexto do serviço. Roda via
    # 'sudo -n' (NOPASSWD abaixo) a partir do watchdog. Exclui a eMMC interna.
    $SUDO_CMD install -d /usr/local/sbin
    $SUDO_CMD tee /usr/local/sbin/canpass-mount-ext >/dev/null <<'MEEOF'
#!/bin/bash
# canpass-mount-ext — monta partições USB (com FS) não montadas, como root, em
# /media/canpass/<dev>. Idempotente; imprime os mountpoints. Exclui mmcblk0 (eMMC).
set -u
while IFS= read -r line; do
    NAME=""; PKNAME=""; FSTYPE=""; MOUNTPOINT=""; TYPE=""
    eval "$line"
    [[ "$TYPE" == part && -n "$FSTYPE" ]] || continue
    [[ "$NAME" == *mmcblk0* ]] && continue
    tran=$(lsblk -dno TRAN "${PKNAME:-$NAME}" 2>/dev/null)
    [[ "$tran" == usb ]] || continue
    if [[ -n "$MOUNTPOINT" ]]; then echo "$MOUNTPOINT"; continue; fi
    mp="/media/canpass/$(basename "$NAME")"
    mkdir -p "$mp" 2>/dev/null
    case "$FSTYPE" in
        vfat|exfat|ntfs|ntfs3|fuseblk) opts="rw,uid=1000,gid=1000,umask=0002" ;;
        *)                             opts="rw" ;;
    esac
    if timeout 25 mount -t "$FSTYPE" -o "$opts" "$NAME" "$mp" 2>/dev/null \
       || timeout 25 mount -o "$opts" "$NAME" "$mp" 2>/dev/null; then
        [[ "$FSTYPE" == ext* ]] && chown 1000:1000 "$mp" 2>/dev/null
        echo "$mp"
    fi
done < <(lsblk -P -p -o NAME,PKNAME,FSTYPE,MOUNTPOINT,TYPE 2>/dev/null)
exit 0
MEEOF
    $SUDO_CMD chmod 755 /usr/local/sbin/canpass-mount-ext

    # Resolve caminhos (variam entre layouts L4T); só inclui o que existe.
    local systemctl_bin nvpmodel_bin jetson_clocks_bin ip_bin modprobe_bin reboot_bin tee_bin
    systemctl_bin="$(command -v systemctl || echo /bin/systemctl)"
    nvpmodel_bin="$(command -v nvpmodel || true)"
    jetson_clocks_bin="$(command -v jetson_clocks || true)"
    ip_bin="$(command -v ip || echo /usr/sbin/ip)"
    modprobe_bin="$(command -v modprobe || echo /usr/sbin/modprobe)"
    reboot_bin="$(command -v reboot || echo /sbin/reboot)"
    tee_bin="$(command -v tee || echo /usr/bin/tee)"

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
    # CAN: canpass-can desliga o autosuspend de USB do CANable escrevendo 'on' em
    # .../power/control (causa comum de "parou de receber"). Roda em BACKGROUND
    # (sem tty) → sem NOPASSWD aparecia "a password is required" no journal e o
    # autosuspend nunca era desligado. O caminho varia com a topologia USB → curinga
    # (sudoers usa fnmatch sem FNM_PATHNAME, então '*' cobre as barras do /sys).
    cmds+=("${tee_bin} /sys/devices/*/power/control")
    # FIELD: watchdog monta o SSD externo via este helper root (boot headless não
    # tem auto-mount). Sem tty → precisa NOPASSWD.
    cmds+=("/usr/local/sbin/canpass-mount-ext")

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
    # Sub-redes a atender: override fixo (CANPASS_NTP_SUBNET) > TODAS as conectadas
    # > default. O override aceita várias separadas por espaço/vírgula.
    local -a subnets=()
    if [[ -n "${CANPASS_NTP_SUBNET:-}" ]]; then
        local _s; for _s in ${CANPASS_NTP_SUBNET//,/ }; do subnets+=("$_s"); done
    else
        mapfile -t subnets < <(_connected_subnets)
    fi
    [[ ${#subnets[@]} -eq 0 ]] && subnets=("192.168.20.0/24")

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
        # CLIENTE: se houver um servidor de hora alcançável (CANPASS_NTP_UPSTREAM —
        # NTP interno/roteador/PC da bancada, ou os pools públicos com internet), o
        # Orin sincroniza a hora REAL como um PC normal e corrige o relógio sozinho.
        # 'prefer' = prioriza o upstream sobre o 'local stratum 10' (o relógio próprio).
        if [[ -n "$NTP_UPSTREAM" ]]; then
            local _us; for _us in ${NTP_UPSTREAM//,/ }; do echo "server ${_us} iburst prefer"; done
        fi
        local _sn; for _sn in "${subnets[@]}"; do echo "allow ${_sn}"; done
        echo "local stratum 10"
        # makestep: no boot, se a hora estiver MUITO errada (RTC sem bateria → preso
        # na última hora), SALTA p/ a correta de uma vez nas primeiras atualizações,
        # em vez de corrigir a passo de tartaruga. Limitado às 3 primeiras p/ NUNCA
        # pular o relógio DURANTE a gravação (preserva a sincronia vídeo↔CAN).
        echo "makestep 1.0 3"
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
        log_ok "Servidor NTP ativo (${svc}) — servindo ${subnets[*]}; câmeras usam o IP do Orin como NTP."
    else
        log_warn "chrony configurado mas não reiniciou — 'sudo systemctl restart ${svc}' e verifique 'chronyc sources'."
    fi

    # ── Correção IMEDIATA da hora durante o próprio 'canpass update' ──────────
    # Se houver QUALQUER fonte NTP alcançável agora (upstream interno ou internet),
    # força a sincronia já — assim o Orin sai do update com a hora certa, sem esperar
    # o próximo boot. Sem fonte (campo/bancada isolada) é inócuo: o makestep não tem
    # o que aplicar e a hora segue como está. O re-seed do RTC abaixo então grava a
    # hora JÁ corrigida (antes, semeava a hora errada por rodar antes da sincronia).
    if command -v chronyc >/dev/null 2>&1; then
        $SUDO_CMD chronyc -a online   >/dev/null 2>&1 || true
        $SUDO_CMD chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
        sleep 5
        if $SUDO_CMD chronyc -a makestep >/dev/null 2>&1; then
            local _refid; _refid=$($SUDO_CMD chronyc -n tracking 2>/dev/null | awk -F'[:[:space:]]+' '/Reference ID/{print $4}')
            if [[ -n "$_refid" && "$_refid" != "7F7F0101" && "$_refid" != "00000000" ]]; then
                log_ok "Hora sincronizada AGORA via NTP (ref ${_refid}): $(date '+%F %T %z')."
            else
                log_warn "Sem fonte NTP alcançável agora — hora mantida ($(date '+%F %T %z')). Em campo a hora real vem do CAN (PGN 65254) ou de bateria de RTC."
            fi
        fi
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

        # Save FREQUENTE do fake-hwclock. O cron.hourly padrão só grava a cada hora,
        # então um corte de energia SEM shutdown limpo (campo: alimentação cortada)
        # perde até ~1 h da "última hora conhecida". Sem bateria de RTC essa é a única
        # referência offline — gravá-la a cada 5 min limita a perda evitável a 5 min
        # (o gap inevitável continua sendo o tempo DESLIGADO; isso exige bateria no RTC).
        $SUDO_CMD tee /etc/systemd/system/canpass-fakehwclock-save.service >/dev/null <<'FHCEOF'
[Unit]
Description=CANPass — salva a hora atual no fake-hwclock (referência offline fresca)
[Service]
Type=oneshot
# Salva no fake-hwclock E disciplina TODOS os RTCs com a hora atual. Disciplinar o
# rtc0 (PMIC) é insurance: SE o carrier tiver QUALQUER retenção nele, o boot seguinte
# já o encontra fresco (o canpass-clock-restore prefere o RTC mais recente plausível).
ExecStart=/bin/sh -c 'fake-hwclock save 2>/dev/null; for r in /dev/rtc0 /dev/rtc1; do [ -e "$r" ] && hwclock --systohc -f "$r" 2>/dev/null; done; true'
FHCEOF
        $SUDO_CMD tee /etc/systemd/system/canpass-fakehwclock-save.timer >/dev/null <<'FHTEOF'
[Unit]
Description=CANPass — grava o fake-hwclock a cada 5 min (limita a perda em power-off sujo)
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
FHTEOF
        $SUDO_CMD systemctl daemon-reload
        $SUDO_CMD systemctl enable --now canpass-fakehwclock-save.timer >/dev/null 2>&1 \
            && log_ok "fake-hwclock salvo a cada 5 min (limita a perda em corte de energia sujo)." \
            || log_warn "Timer canpass-fakehwclock-save não ativou — verifique 'systemctl status canpass-fakehwclock-save.timer'."
    fi

    # ── Restauração da hora no BOOT (canpass-clock.service) ───────────────────
    # PROBLEMA visto em campo: offline, a data ficava MUITO errada. No AGX Orin o
    # kernel seta o relógio do sistema a partir do rtc1 (tegra_rtc, hctosys=1) —
    # que NÃO tem bateria de backup — e IGNORA o rtc0 (nvvrs-pseq-rtc/PMIC), que é
    # o que pode ter bateria no carrier. Resultado: pós-power-off lia 1969/2024.
    # Solução: um oneshot que roda ANTES do chrony e escolhe a hora MAIS RECENTE e
    # plausível entre os RTCs e o relógio atual (que o fake-hwclock já adiantou),
    # aplica no sistema e regrava em TODOS os RTCs. Com bateria no PMIC recupera a
    # hora REAL; sem bateria cai na última hora do fake-hwclock (melhor que 1969).
    local clk_bin="/usr/local/sbin/canpass-clock-restore.sh"
    $SUDO_CMD install -d /usr/local/sbin
    $SUDO_CMD tee "$clk_bin" >/dev/null <<'CLKEOF'
#!/bin/bash
# canpass-clock-restore — escolhe a hora mais recente e plausível (RTC c/ bateria >
# fake-hwclock) no boot e propaga p/ todos os RTCs. O tempo só anda p/ frente, então
# "mais recente válida" é a melhor estimativa de 'agora' quando offline.
set -u
FLOOR=$(date -d '2025-01-01 00:00:00' +%s 2>/dev/null || echo 1735707600)  # piso de sanidade
CEIL=$(date -d  '2099-01-01 00:00:00' +%s 2>/dev/null || echo 4070926800)  # teto anti-lixo
best=$(date +%s); src="sistema/fake-hwclock"
for r in /dev/rtc0 /dev/rtc1; do
    [[ -e "$r" ]] || continue
    t=$(hwclock -r -f "$r" 2>/dev/null) || continue
    e=$(date -d "$t" +%s 2>/dev/null) || continue
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    (( e > FLOOR && e < CEIL && e > best )) && { best=$e; src="$r"; }
done
date -s "@$best" >/dev/null 2>&1
for r in /dev/rtc0 /dev/rtc1; do [[ -e "$r" ]] && hwclock --systohc -f "$r" 2>/dev/null; done
logger -t canpass-clock "hora restaurada de ${src}: $(date '+%F %T %z')"
exit 0
CLKEOF
    $SUDO_CMD chmod 755 "$clk_bin"
    $SUDO_CMD tee /etc/systemd/system/canpass-clock.service >/dev/null <<EOF
[Unit]
Description=CANPass — restaura a hora real offline (RTC c/ bateria > fake-hwclock)
# Roda DEPOIS do fake-hwclock (que provê o piso) e ANTES do chrony (que serve a
# hora às câmeras) — assim, offline, o NTP já entrega a hora corrigida.
After=fake-hwclock.service
Before=chrony.service chronyd.service ${SERVICE_NAME}.service

[Service]
Type=oneshot
ExecStart=${clk_bin}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    $SUDO_CMD systemctl daemon-reload
    if $SUDO_CMD systemctl enable --now canpass-clock.service >/dev/null 2>&1; then
        log_ok "canpass-clock.service ativo — restaura a hora no boot (RTC c/ bateria > fake-hwclock)."
    else
        log_warn "canpass-clock.service não ativou — verifique 'systemctl status canpass-clock'."
    fi

    # ── Hora real pelo CAN no BOOT (canpass-cantime-boot.service) ─────────────
    # Sem internet/bateria/GPS, a ÚNICA fonte de hora real no campo é o próprio
    # J1939: muitas máquinas transmitem o PGN 65254 (Time/Date). Este oneshot roda
    # ANTES da gravação e, se a máquina estiver ligada e transmitir, ajusta a hora
    # UMA vez (nunca durante a sessão — isso quebraria a sincronia vídeo↔CAN). Em
    # operação, o offset vivo vai p/ clock_offset.csv via o monitor que o watchdog
    # sobe junto do log CAN. No-op (não trava o boot) se não houver CAN/frame.
    if [[ -x "${INSTALL_DIR}/canpass-can" ]]; then
        $SUDO_CMD tee /etc/systemd/system/canpass-cantime-boot.service >/dev/null <<EOF
[Unit]
Description=CANPass — ajusta a hora pela hora do J1939 (PGN 65254) ANTES da gravação
After=canpass-clock.service
Before=${SERVICE_NAME}.service

[Service]
Type=oneshot
EnvironmentFile=-${FIELD_ENV}
ExecStart=${INSTALL_DIR}/canpass-can cantime-boot
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
        $SUDO_CMD systemctl daemon-reload
        $SUDO_CMD systemctl enable canpass-cantime-boot.service >/dev/null 2>&1 \
            && log_ok "canpass-cantime-boot ativo — busca a hora real no CAN (PGN 65254) antes de gravar." \
            || log_warn "canpass-cantime-boot não habilitou — verifique 'systemctl status canpass-cantime-boot'."
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

    # Perfil de CAMPO: o serviço systemd lê ${FIELD_ENV}. Esse arquivo é EDITÁVEL
    # em campo (IPs/senhas das câmeras, sub-rede) e NÃO deve ser sobrescrito pelo
    # 'canpass update' — então só é criado se NÃO existir; a referência do repo vai
    # sempre p/ ${FIELD_ENV}.example. Edite o instalado, nunca o do repo (.rsc/).
    if [[ -f "${SCRIPT_DIR}/.rsc/canpass-field.env" ]]; then
        $SUDO_CMD install -d /usr/local/share/canpass
        $SUDO_CMD install -m 644 "${SCRIPT_DIR}/.rsc/canpass-field.env" "${FIELD_ENV}.example"
        if [[ -f "$FIELD_ENV" ]]; then
            log_ok "Perfil de campo PRESERVADO (${FIELD_ENV}); referência em ${FIELD_ENV}.example."
        else
            $SUDO_CMD install -m 644 "${SCRIPT_DIR}/.rsc/canpass-field.env" "$FIELD_ENV"
            log_ok "Perfil de campo instalado em ${FIELD_ENV} (edite-o p/ ajustar câmeras)."
        fi
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
    # fake-hwclock: best-effort (binário em /usr/sbin quebra o command -v do
    # install_apt_package). setup_ntp_server o habilita se presente.
    $SUDO_CMD apt-get install -y fake-hwclock 2>/dev/null \
        && log_ok "fake-hwclock instalado (boota na última hora se o RTC não tem bateria)." \
        || log_warn "fake-hwclock não instalado (sem rede?) — hora offline dependerá só do RTC."
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
