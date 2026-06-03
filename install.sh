#!/usr/bin/env bash
# Install sms-telegram-bot: venv, configs, optional config.pkl, systemd unit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_USER_MODE=false
CONFIG_PKL_READY=false
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
        # User service: keep PID file in the repo (writable without /run).
        local pid_file pid_esc
        pid_file="${SCRIPT_DIR}/gammu-smsd.pid"
        pid_esc="$(escape_sed "$pid_file")"
        sed -i "s|/run/gammu-smsd.pid|${pid_esc}|g" "${SCRIPT_DIR}/gammu-smsd.service"
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

# Print path to a non-empty config.pkl, or return 1 if none exists.
config_pkl_path() {
    local candidate
    for candidate in \
        "${SCRIPT_DIR}/src/config.pkl" \
        "${SCRIPT_DIR}/config.pkl"; do
        if [[ -s "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

setup_config_pkl() {
    local config_pkl="${SCRIPT_DIR}/src/config.pkl"
    local inbox="${SCRIPT_DIR}/sms/inbox"
    local vpy existing
    vpy="$(venv_python)"

    if existing="$(config_pkl_path)"; then
        info "config.pkl already present at ${existing} — skipping setup."
        CONFIG_PKL_READY=true
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
        echo ""
        echo "Skipped config.pkl. Run later:"
        echo "  ${vpy} ${SCRIPT_DIR}/src/models/configuration.py ${config_pkl}"
        echo ""
        echo "gammu-smsd will be enabled but not started until config.pkl exists."
        return 0
    fi

    export PYTHONPATH="${SCRIPT_DIR}/src:${PYTHONPATH:-}"
    "$vpy" "${SCRIPT_DIR}/src/models/configuration.py" "$config_pkl"
    CONFIG_PKL_READY=true
}

gammu_smsd_is_active() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        systemctl --user is-active --quiet gammu-smsd.service 2>/dev/null
    else
        "${SUDO_CMD[@]}" systemctl is-active --quiet gammu-smsd.service 2>/dev/null
    fi
}

gammu_smsd_status_hint() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        echo "systemctl --user status gammu-smsd"
    else
        echo "sudo systemctl status gammu-smsd"
    fi
}

gammu_smsd_restart_hint() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        echo "systemctl --user restart gammu-smsd"
    else
        echo "sudo systemctl restart gammu-smsd"
    fi
}

start_gammu_smsd() {
    local ctl_start ctl_restart was_active=false
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        ctl_start=(systemctl --user start gammu-smsd.service)
        ctl_restart=(systemctl --user restart gammu-smsd.service)
    else
        ctl_start=("${SUDO_CMD[@]}" systemctl start gammu-smsd.service)
        ctl_restart=("${SUDO_CMD[@]}" systemctl restart gammu-smsd.service)
    fi

    if gammu_smsd_is_active; then
        was_active=true
    fi

    # Running service (--user or system): always restart after daemon-reload above.
    if [[ "$was_active" == true ]]; then
        info "gammu-smsd already running — restarting to apply unit/config changes (timeout 90s)..."
        if ! timeout 90 "${ctl_restart[@]}"; then
            warn "gammu-smsd restart timed out (modem missing or gammurc device wrong?)."
            info "Check: $(gammu_smsd_status_hint)"
        fi
        if [[ "$CONFIG_PKL_READY" != true ]]; then
            warn "config.pkl missing — create it for Telegram forwarding to work."
            info "  .venv/bin/python src/models/configuration.py ${SCRIPT_DIR}/src/config.pkl"
        fi
        return 0
    fi

    if [[ "$CONFIG_PKL_READY" != true ]]; then
        warn "config.pkl missing — unit enabled, not started."
        if [[ "$INSTALL_USER_MODE" == true ]]; then
            info "After creating config.pkl: systemctl --user start gammu-smsd"
        else
            info "After creating config.pkl: sudo systemctl start gammu-smsd"
        fi
        return 0
    fi

    info "Starting gammu-smsd (timeout 90s)..."
    if ! timeout 90 "${ctl_start[@]}"; then
        warn "gammu-smsd did not start in time (modem missing or gammurc device wrong?)."
        info "Check: $(gammu_smsd_status_hint)"
    fi
}

install_systemd_unit() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        info "Installing user systemd unit..."
        mkdir -p "$user_unit_dir"
        cp "${SCRIPT_DIR}/gammu-smsd.service" "${user_unit_dir}/gammu-smsd.service"
        systemctl --user daemon-reload
        systemctl --user enable gammu-smsd.service
        info "Reloaded user systemd units."
    else
        info "Installing system systemd unit..."
        "${SUDO_CMD[@]}" cp "${SCRIPT_DIR}/gammu-smsd.service" \
            /etc/systemd/system/gammu-smsd.service
        "${SUDO_CMD[@]}" systemctl daemon-reload
        "${SUDO_CMD[@]}" systemctl enable gammu-smsd.service
        info "Reloaded system systemd units."
    fi
    start_gammu_smsd
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
    if [[ "$CONFIG_PKL_READY" != true ]]; then
        warn "  config.pkl: not created — run configuration.py before relying on SMS → Telegram."
    fi
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

    install_systemd_unit

    print_summary
}

main "$@"
