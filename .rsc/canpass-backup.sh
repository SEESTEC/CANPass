#!/usr/bin/env bash
# canpass-backup.sh — snapshot/restore do Orin (eMMC interna) via ferramentas L4T.
#
# ⚠️  RODA NO PC HOST (x86_64 Linux), NÃO no Orin. O AGX Orin dá boot da eMMC
#     interna — não há cartão p/ clonar; o backup é feito do host, com a placa em
#     RECOVERY MODE, conectada por USB-C.
#
# Embrulha a ferramenta oficial 'l4t_backup_restore.sh' (do BSP Linux_for_Tegra)
# com checagens de segurança. Se essa ferramenta não existir no BSP (ela só entrou
# ~L4T 35.3.x), cai no método clássico 'flash.sh -r -k APP -G' (backup do rootfs).
#
# Uso:
#   canpass-backup.sh check                        # valida ambiente (host, BSP, recovery)
#   canpass-backup.sh backup  [--archive <dir>]    # snapshot do estado atual da eMMC
#   canpass-backup.sh restore [--from <dir>]       # regrava a eMMC a partir do snapshot
#
# Onde achar o BSP (Linux_for_Tegra), em ordem de prioridade:
#   --l4t <dir>  |  $L4T_DIR  |  ./Linux_for_Tegra  |  diretório atual (se tiver flash.sh)
#
# Variáveis:
#   L4T_DIR     caminho do Linux_for_Tegra
#   L4T_BOARD   nome da placa (padrão: jetson-agx-orin-devkit)
#
# IMPORTANTE p/ este projeto: para o BACKUP/RESTORE do estado e-CAM82 (L4T 35.2.1),
# use um Linux_for_Tegra do MESMO L4T 35.2.1. O flash de TESTE da NileCAM (35.4.1)
# é uma operação separada (flash.sh / SDK Manager) — não é este script.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error() { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

L4T_BOARD="${L4T_BOARD:-jetson-agx-orin-devkit}"
BR_TOOL_REL="tools/backup_restore/l4t_backup_restore.sh"
IMAGES_REL="tools/backup_restore/images"

# ─── Localiza o Linux_for_Tegra ──────────────────────────────────────────────
_resolve_l4t() {
    local d="${1:-}"
    [[ -z "$d" ]] && d="${L4T_DIR:-}"
    [[ -z "$d" && -f "./Linux_for_Tegra/flash.sh" ]] && d="./Linux_for_Tegra"
    [[ -z "$d" && -f "./flash.sh" ]] && d="."
    if [[ -z "$d" || ! -f "${d}/flash.sh" ]]; then
        log_error "Linux_for_Tegra não encontrado (procuro por flash.sh)."
        log_error "Passe --l4t <dir> ou exporte L4T_DIR=/caminho/Linux_for_Tegra."
        return 1
    fi
    ( cd "$d" && pwd )
}

# ─── Checagens de ambiente ───────────────────────────────────────────────────
_check_host() {
    local arch; arch="$(uname -m)"
    if [[ "$arch" != "x86_64" ]]; then
        log_error "Arquitetura ${arch} — este script roda no PC HOST x86_64, não no Orin."
        return 1
    fi
    log_ok "Host x86_64."
}

_check_recovery() {
    if ! command -v lsusb &>/dev/null; then
        log_warn "lsusb ausente — não dá p/ confirmar recovery mode. (apt install usbutils)"
        return 0
    fi
    local line
    line="$(lsusb | grep -iE '0955:' || true)"   # 0955 = NVIDIA Corp (APX/recovery)
    if [[ -n "$line" ]]; then
        log_ok "Orin em RECOVERY detectado:  ${line}"
        return 0
    fi
    log_warn "Nenhum dispositivo NVIDIA em recovery (ID 0955:xxxx) visível no USB."
    log_warn "Coloque o Orin em recovery: segure FORCE RECOVERY, ligue/POWER, solte após ~2 s."
    log_warn "Confirme com:  lsusb | grep 0955"
    return 1
}

cmd_check() {
    local l4t; l4t="$(_resolve_l4t "${L4T_ARG:-}")" || return 1
    log_ok  "BSP:   ${l4t}"
    log_info "Placa: ${L4T_BOARD}"
    if [[ -f "${l4t}/${BR_TOOL_REL}" ]]; then
        log_ok "Ferramenta oficial presente: ${BR_TOOL_REL} (backup FULL de todas as partições)."
    else
        log_warn "l4t_backup_restore.sh ausente neste BSP — usarei o método flash.sh (rootfs APP)."
    fi
    _check_host || return 1
    _check_recovery || true
    echo
    log_info "Pronto. 'backup' p/ snapshot; 'restore' p/ regravar."
}

# ─── Backup ──────────────────────────────────────────────────────────────────
cmd_backup() {
    local archive=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive) archive="${2:-}"; shift 2 ;;
            *) log_error "Argumento desconhecido: $1"; return 2 ;;
        esac
    done

    local l4t; l4t="$(_resolve_l4t "${L4T_ARG:-}")" || return 1
    _check_host || return 1
    _check_recovery || { log_error "Coloque o Orin em recovery e tente de novo."; return 1; }

    log_warn "BACKUP vai LER a eMMC do Orin — pode levar vários minutos. Não desconecte o USB."
    read -rp "$(echo -e "${CYAN}Prosseguir com o backup? [s/N]:${NC} ")" a
    [[ "$a" =~ ^[sSyY]$ ]] || { log_info "Cancelado."; return 0; }

    if [[ -f "${l4t}/${BR_TOOL_REL}" ]]; then
        log_info "Backup FULL via l4t_backup_restore.sh..."
        ( cd "$l4t" && sudo ./${BR_TOOL_REL} -b "${L4T_BOARD}" ) || { log_error "Backup falhou."; return 1; }
        log_ok "Imagens geradas em ${l4t}/${IMAGES_REL}/"
        if [[ -n "$archive" ]]; then
            local dst="${archive%/}/canpass-snapshot-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$dst" && cp -a "${l4t}/${IMAGES_REL}/." "$dst/" \
                && log_ok "Cópia de segurança em ${dst}" \
                || log_warn "Falha ao arquivar em ${archive} — as imagens seguem em ${IMAGES_REL}/."
        else
            log_warn "Guarde a pasta ${IMAGES_REL}/ — é o seu ponto de restauração."
        fi
    else
        # Fallback: backup só do rootfs (APP). Captura /boot (kernel/DTB/extlinux) e
        # os módulos/driver da e-CAM82 — suficiente p/ este projeto.
        local img="${archive:-$l4t}"
        mkdir -p "$img"
        local out="${img%/}/canpass-rootfs-$(date +%Y%m%d-%H%M%S).img"
        log_info "Backup do rootfs (APP) via flash.sh → ${out}"
        ( cd "$l4t" && sudo ./flash.sh -r -k APP -G "$out" "${L4T_BOARD}" internal ) \
            || { log_error "Backup falhou."; return 1; }
        log_ok "Imagem do rootfs salva: ${out}"
        log_warn "Restore deste formato é manual (copiar p/ bootloader/system.img + flash.sh)."
        log_warn "Para restore automático, prefira um BSP com l4t_backup_restore.sh."
    fi
}

# ─── Restore ─────────────────────────────────────────────────────────────────
cmd_restore() {
    local from=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:-}"; shift 2 ;;
            *) log_error "Argumento desconhecido: $1"; return 2 ;;
        esac
    done

    local l4t; l4t="$(_resolve_l4t "${L4T_ARG:-}")" || return 1
    _check_host || return 1

    if [[ ! -f "${l4t}/${BR_TOOL_REL}" ]]; then
        log_error "Este BSP não tem l4t_backup_restore.sh — restore automático indisponível."
        log_error "Use um Linux_for_Tegra com a ferramenta, ou o Plano B: reflashar L4T 35.2.1"
        log_error "e rodar 'sudo bash install_drivers.sh' (reproduz o estado e-CAM82 pelo repo)."
        return 1
    fi

    # Se as imagens estão arquivadas em outro lugar, recoloca-as em images/.
    if [[ -n "$from" ]]; then
        [[ -d "$from" ]] || { log_error "Pasta de origem não existe: ${from}"; return 1; }
        log_info "Copiando snapshot de ${from} → ${IMAGES_REL}/"
        mkdir -p "${l4t}/${IMAGES_REL}" && cp -a "${from%/}/." "${l4t}/${IMAGES_REL}/" \
            || { log_error "Falha ao copiar o snapshot."; return 1; }
    fi
    if [[ ! -d "${l4t}/${IMAGES_REL}" ]] || [[ -z "$(ls -A "${l4t}/${IMAGES_REL}" 2>/dev/null)" ]]; then
        log_error "Sem imagens em ${IMAGES_REL}/. Passe --from <dir do snapshot>."
        return 1
    fi

    _check_recovery || { log_error "Coloque o Orin em recovery e tente de novo."; return 1; }

    log_error "RESTORE É DESTRUTIVO: vai REGRAVAR a eMMC do Orin e apagar o estado atual."
    read -rp "$(echo -e "${CYAN}Digite RESTAURAR para confirmar:${NC} ")" a
    [[ "$a" == "RESTAURAR" ]] || { log_info "Cancelado."; return 0; }

    log_info "Restaurando via l4t_backup_restore.sh -r..."
    ( cd "$l4t" && sudo ./${BR_TOOL_REL} -r "${L4T_BOARD}" ) || { log_error "Restore falhou."; return 1; }
    log_ok "Restore concluído. O Orin deve bootar no estado do snapshot."
}

usage() {
    cat <<EOF
canpass-backup.sh — snapshot/restore da eMMC do Orin (RODA NO PC HOST)

  canpass-backup.sh check                      valida host + BSP + recovery
  canpass-backup.sh backup  [--archive <dir>]  snapshot do estado atual
  canpass-backup.sh restore [--from <dir>]     regrava a eMMC a partir do snapshot

Opções globais:  --l4t <dir>   (ou L4T_DIR)    caminho do Linux_for_Tegra
                 --board <nm>  (ou L4T_BOARD)  padrão: jetson-agx-orin-devkit

Orin SEMPRE em recovery (FORCE RECOVERY + power) e ligado por USB-C ao host.
EOF
}

main() {
    # Extrai opções globais (--l4t/--board) de qualquer posição.
    local -a rest=()
    L4T_ARG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --l4t)   L4T_ARG="${2:-}"; shift 2 ;;
            --board) L4T_BOARD="${2:-}"; shift 2 ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    set -- "${rest[@]:-}"

    local cmd="${1:-check}"; shift || true
    case "$cmd" in
        check)          cmd_check "$@" ;;
        backup)         cmd_backup "$@" ;;
        restore)        cmd_restore "$@" ;;
        -h|--help|help) usage ;;
        *) log_error "Comando desconhecido: '$cmd'"; echo; usage; return 2 ;;
    esac
}

main "$@"
