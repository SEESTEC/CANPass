#!/usr/bin/env bash
# watchdog.sh — Supervisiona cam_view.sh e reinicia em caso de falha inesperada.
# Encerramento explícito pelo usuário (Ctrl+C / SIGTERM) não dispara reinício.

set -uo pipefail

YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }

CAM_VIEW="/usr/bin/cam_view.sh"
RESTART_DELAY_SECS=3

# Códigos que indicam encerramento intencional pelo usuário
INTENTIONAL_EXIT_CODES=(0 130 143)

is_intentional_exit() {
    local exit_code="$1"
    for code in "${INTENTIONAL_EXIT_CODES[@]}"; do
        [[ $exit_code -eq $code ]] && return 0
    done
    return 1
}

trap 'exit 130' INT
trap 'exit 143' TERM

_cleanup_install_dir() {
    local src_file="/tmp/.canpass_src_dir"
    [[ -f "$src_file" ]] || return
    local src_dir
    src_dir=$(cat "$src_file")
    rm -f "$src_file"
    [[ -d "$src_dir" ]] || return
    rm -rf "$src_dir"
    log_info "Repositório de instalação removido: ${src_dir}"
}
_cleanup_install_dir

log_info "Watchdog iniciado — supervisionando ${CAM_VIEW}"

while true; do
    "$CAM_VIEW" "$@"
    exit_code=$?

    if is_intentional_exit "$exit_code"; then
        log_info "Encerramento intencional (código ${exit_code}) — watchdog finalizado."
        exit 0
    fi

    log_warn "cam_view.sh encerrou inesperadamente (código ${exit_code}) — reiniciando em ${RESTART_DELAY_SECS}s..."
    sleep "$RESTART_DELAY_SECS"
done
