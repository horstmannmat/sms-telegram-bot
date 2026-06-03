#!/usr/bin/env bash
# Install sms-telegram-bot: venv, configs, optional config.pkl, systemd unit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_USER_MODE=false
for arg in "$@"; do
    if [[ "$arg" == "--user" ]]; then
        INSTALL_USER_MODE=true
    fi
done

MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10

RUN_AS_USER="${SUDO_USER:-${USER:-$(whoami)}}"
SUDO_CMD=()
if [[ "${EUID}" -ne 0 ]]; then
    SUDO_CMD=(sudo)
fi

error() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "$*"
}

warn() {
    echo "warning: $*" >&2
}

escape_sed() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "This installer targets Linux (gammu-smsd). Use a Linux host for deployment."
    fi
}

require_sudo() {
    if ! "${SUDO_CMD[@]}" -v; then
        error "System install requires sudo. Use ./install.sh --user for a user-level service."
    fi
}

apt_install_deps() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "apt-get not found. Install python3 (>=3.10), python3-venv, gammu, and gammu-smsd manually."
    fi
    info "Installing system packages (python3, gammu, gammu-smsd)..."
    "${SUDO_CMD[@]}" apt-get update -qq
    "${SUDO_CMD[@]}" apt-get install -y python3 python3-venv python3-pip gammu gammu-smsd
}

python_version_ok() {
    local py="$1"
    "$py" -c "import sys; raise SystemExit(0 if sys.version_info >= (${MIN_PYTHON_MAJOR}, ${MIN_PYTHON_MINOR}) else 1)" 2>/dev/null
}

find_python() {
    local py="${PYTHON:-python3}"
    if ! command -v "$py" >/dev/null 2>&1; then
        return 1
    fi
    if python_version_ok "$py"; then
        echo "$py"
        return 0
    fi
    return 1
}

ensure_python() {
    local py
    if py="$(find_python)"; then
        echo "$py"
        return 0
    fi
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        error "python3 >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} is required. Install it and re-run."
    fi
    apt_install_deps
    py="$(find_python)" || error "python3 >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} still not available after apt install."
    echo "$py"
}

ensure_gammu_smsd() {
    if command -v gammu-smsd >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        error "gammu-smsd not found. Install gammu-smsd (e.g. sudo apt install gammu gammu-smsd)."
    fi
    apt_install_deps
    command -v gammu-smsd >/dev/null 2>&1 || error "gammu-smsd not found after apt install."
}

setup_venv() {
    local py="$1"

    _venv_install() {
        cd "$SCRIPT_DIR"
        "$py" -m venv .venv
        # shellcheck source=/dev/null
        source .venv/bin/activate
        pip install .
        deactivate 2>/dev/null || true
    }

    info "Creating virtualenv..."
    rm -rf "${SCRIPT_DIR}/.venv"
    if [[ -n "${SUDO_USER:-}" && "$(id -un)" == "root" ]]; then
        sudo -u "$RUN_AS_USER" -H bash -euo pipefail -c "
            cd $(printf '%q' "$SCRIPT_DIR")
            $(printf '%q' "$py") -m venv .venv
            source .venv/bin/activate
            pip install .
        "
    else
        _venv_install
    fi
}

venv_python() {
    local vpy="${SCRIPT_DIR}/.venv/bin/python"
    [[ -x "$vpy" ]] || error "venv python not found at ${vpy}"
    echo "$vpy"
}

generate_configs() {
    local script_esc sms_esc gammurc_esc sysconfig_esc
    script_esc="$(escape_sed "$SCRIPT_DIR")"
    sms_esc="$(escape_sed "${SCRIPT_DIR}/sms")"
    gammurc_esc="$(escape_sed "${SCRIPT_DIR}/gammurc")"
    sysconfig_esc="$(escape_sed "${SCRIPT_DIR}/gammu-smsd.sysconfig")"

    cp "${SCRIPT_DIR}/gammurc.example" "${SCRIPT_DIR}/gammurc"
    sed -i "s|/path/to/home/sms-telegram-bot|${script_esc}|g" "${SCRIPT_DIR}/gammurc"
    sed -i "s|/path/to/home/sms|${sms_esc}|g" "${SCRIPT_DIR}/gammurc"
    chmod 600 "${SCRIPT_DIR}/gammurc"

    cp "${SCRIPT_DIR}/gammu-smsd.sysconfig.example" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
    sed -i "s|GAMMU_CONFIG_FILE=/etc/gammurc|GAMMU_CONFIG_FILE=${gammurc_esc}|g" \
        "${SCRIPT_DIR}/gammu-smsd.sysconfig"

    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local user_name group_name user_esc group_esc
        user_name="${USER:-$(whoami)}"
        group_name="$(id -gn "$user_name")"
        user_esc="$(escape_sed "$user_name")"
        group_esc="$(escape_sed "$group_name")"
        sed -i "s|^GAMMU_USER=.*|GAMMU_USER=${user_esc}|g" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
        sed -i "s|^GAMMU_GROUP=.*|GAMMU_GROUP=${group_esc}|g" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
    fi

    cp "${SCRIPT_DIR}/gammu-smsd.service.example" "${SCRIPT_DIR}/gammu-smsd.service"
    sed -i "s|EnvironmentFile=-/etc/sysconfig/gammu-smsd|EnvironmentFile=-${sysconfig_esc}|g" \
        "${SCRIPT_DIR}/gammu-smsd.service"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        # User systemd has no multi-user.target; default.target is the session default.
        sed -i 's|WantedBy=multi-user.target|WantedBy=default.target|g' \
            "${SCRIPT_DIR}/gammu-smsd.service"
    fi

    if grep -qE '\$SCRIPT_DIR|\$\{SCRIPT_DIR\}' \
        "${SCRIPT_DIR}/gammurc" \
        "${SCRIPT_DIR}/gammu-smsd.sysconfig" \
        "${SCRIPT_DIR}/gammu-smsd.service" 2>/dev/null; then
        error "Generated configs still contain unresolved SCRIPT_DIR variables."
    fi
}

create_sms_dirs() {
    mkdir -p \
        "${SCRIPT_DIR}/sms/inbox" \
        "${SCRIPT_DIR}/sms/outbox" \
        "${SCRIPT_DIR}/sms/sent" \
        "${SCRIPT_DIR}/sms/error"
}

setup_config_pkl() {
    local config_pkl="${SCRIPT_DIR}/src/config.pkl"
    local inbox="${SCRIPT_DIR}/sms/inbox"
    local vpy
    vpy="$(venv_python)"

    if [[ -f "$config_pkl" ]]; then
        info "config.pkl already exists at ${config_pkl}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        warn "config.pkl not found (non-interactive session)."
        echo ""
        echo "Create it manually:"
        echo "  ${vpy} ${SCRIPT_DIR}/src/models/configuration.py ${config_pkl}"
        echo "  Recommended inbox folder: ${inbox}/"
        echo ""
        return 0
    fi

    echo ""
    info "config.pkl is required for Telegram credentials."
    info "Recommended inbox folder: ${inbox}/"
    read -r -p "Create config.pkl now? [Y/n] " reply
    reply="${reply:-Y}"
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Skipped. Run later:"
        echo "  ${vpy} ${SCRIPT_DIR}/src/models/configuration.py ${config_pkl}"
        return 0
    fi

    export PYTHONPATH="${SCRIPT_DIR}/src:${PYTHONPATH:-}"
    "$vpy" "${SCRIPT_DIR}/src/models/configuration.py" "$config_pkl"
}

install_systemd_user() {
    local user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$user_unit_dir"
    cp "${SCRIPT_DIR}/gammu-smsd.service" "${user_unit_dir}/gammu-smsd.service"
    systemctl --user daemon-reload
    systemctl --user enable --now gammu-smsd.service
}

install_systemd_system() {
    "${SUDO_CMD[@]}" cp "${SCRIPT_DIR}/gammu-smsd.service" /etc/systemd/system/gammu-smsd.service
    "${SUDO_CMD[@]}" systemctl daemon-reload
    "${SUDO_CMD[@]}" systemctl enable --now gammu-smsd.service
}

print_linger_warning() {
    echo ""
    echo "================================================================"
    echo " IMPORTANT: Enable user lingering for gammu-smsd after logout"
    echo ""
    echo "   sudo loginctl enable-linger ${USER:-$(whoami)}"
    echo ""
    echo " Without this, the user-level gammu-smsd service stops when"
    echo " you log out."
    echo "================================================================"
    echo ""
}

print_summary() {
    local vpy
    vpy="$(venv_python)"
    echo ""
    info "Installation complete."
    info "  Directory:     ${SCRIPT_DIR}"
    info "  Python:        $("$vpy" -V 2>&1)"
    info "  gammurc:       ${SCRIPT_DIR}/gammurc"
    info "  sysconfig:     ${SCRIPT_DIR}/gammu-smsd.sysconfig"
    info "  systemd unit:  ${SCRIPT_DIR}/gammu-smsd.service"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        info "  Mode:          user (systemctl --user)"
        info "  GAMMU_USER:    ${USER:-$(whoami)}"
        print_linger_warning
        info "  Status:        systemctl --user status gammu-smsd"
    else
        info "  Mode:          system (sudo systemctl)"
        info "  Status:        sudo systemctl status gammu-smsd"
    fi
    info "  Edit device in gammurc if needed (default /dev/ttyUSB0)."
    echo ""
}

main() {
    require_linux

    if [[ "$INSTALL_USER_MODE" == true ]]; then
        if ! systemctl --user status >/dev/null 2>&1; then
            error "systemd user session unavailable. Cannot use --user."
        fi
    else
        require_sudo
    fi

    local py
    py="$(ensure_python)"
    ensure_gammu_smsd

    info "Using Python: ${py}"
    setup_venv "$py"
    generate_configs
    create_sms_dirs
    setup_config_pkl

    if [[ "$INSTALL_USER_MODE" == true ]]; then
        install_systemd_user
    else
        install_systemd_system
    fi

    print_summary
}

main "$@"
