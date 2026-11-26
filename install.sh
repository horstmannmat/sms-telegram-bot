#!/usr/bin/env bash
# Install or uninstall sms-telegram-bot (venv, configs, systemd unit).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_USER_MODE=false
UNINSTALL_MODE=false
CONFIG_PKL_READY=false
DETECTED_DEVICE=""
UDEV_RULE_NAME="99-gammu-smsd-modem.rules"
UDEV_RULE_DST="/etc/udev/rules.d/${UDEV_RULE_NAME}"
for arg in "$@"; do
    case "$arg" in
        --user)
            INSTALL_USER_MODE=true
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            ;;
    esac
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

use_color() {
    [[ -t 1 ]]
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
    if [[ "${EUID}" -eq 0 ]]; then
        return 0
    fi
    if ! sudo -v; then
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

# Map a raw /dev/ttyUSB* or /dev/ttyACM* path to its persistent /dev/serial/by-id
# (or /dev/serial/by-path) symlink when available.
resolve_persistent_device() {
    local dev="$1"
    local target link link_target
    target="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"

    local dir
    for dir in /dev/serial/by-id /dev/serial/by-path; do
        [[ -d "$dir" ]] || continue
        shopt -s nullglob
        for link in "${dir}"/*; do
            link_target="$(readlink -f "$link" 2>/dev/null || true)"
            if [[ -n "$link_target" && "$link_target" == "$target" ]]; then
                shopt -u nullglob
                printf '%s' "$link"
                return 0
            fi
        done
        shopt -u nullglob
    done

    printf '%s' "$dev"
}

# Huawei broadband sticks (e.g. 12d1:1c05) expose multiple serial interfaces where
# if02 is the PCUI/AT control port (if01 is diagnostic and times out on AT).
detect_huawei_if02_by_id() {
    [[ -d /dev/serial/by-id ]] || return 1
    local link lower
    shopt -s nullglob
    for link in /dev/serial/by-id/*; do
        lower="${link,,}"
        if [[ "$lower" == *huawei*if02* && -e "$link" ]]; then
            shopt -u nullglob
            printf '%s' "$link"
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# Fallback when neither Huawei if02 nor gammu-detect yields a device:
# prefer /dev/serial/by-id/* (if02, else second entry), then /dev/ttyUSB* / /dev/ttyACM*.
_fallback_serial_device() {
    local -a by_id=() devices=()
    local link lower
    if [[ -d /dev/serial/by-id ]]; then
        shopt -s nullglob
        by_id=(/dev/serial/by-id/*)
        shopt -u nullglob
        for link in "${by_id[@]}"; do
            lower="${link,,}"
            if [[ "$lower" == *if02* && -e "$link" ]]; then
                printf '%s' "$link"
                return 0
            fi
        done
        if [[ ${#by_id[@]} -ge 2 ]]; then
            printf '%s' "${by_id[1]}"
            return 0
        fi
        if [[ ${#by_id[@]} -eq 1 ]]; then
            warn "Only one /dev/serial/by-id port found; using ${by_id[0]}."
            printf '%s' "${by_id[0]}"
            return 0
        fi
    fi

    shopt -s nullglob
    devices=(/dev/ttyUSB* /dev/ttyACM*)
    shopt -u nullglob
    if [[ ${#devices[@]} -ge 2 ]]; then
        resolve_persistent_device "${devices[1]}"
        return 0
    fi
    if [[ ${#devices[@]} -eq 1 ]]; then
        warn "Only one serial port found; using ${devices[0]}."
        resolve_persistent_device "${devices[0]}"
        return 0
    fi
    return 1
}

detect_gammu_device() {
    local detect_out device

    if [[ -n "${GAMMU_DEVICE:-}" ]]; then
        if [[ -e "$GAMMU_DEVICE" ]]; then
            printf '%s' "$GAMMU_DEVICE"
            return 0
        fi
        warn "GAMMU_DEVICE=${GAMMU_DEVICE} does not exist; falling back to auto-detection."
    fi

    if device="$(detect_huawei_if02_by_id)"; then
        printf '%s' "$device"
        return 0
    fi

    if command -v gammu-detect >/dev/null 2>&1; then
        detect_out="$(gammu-detect 2>/dev/null || true)"
        device="$(
            printf '%s\n' "$detect_out" | awk '
                /^\[gammu\]$/ { in_gammu=1; next }
                /^\[/ { in_gammu=0 }
                in_gammu && /^device = / {
                    sub(/^device = /, "")
                    print
                    exit
                }
            '
        )"
        if [[ -z "$device" ]]; then
            device="$(printf '%s\n' "$detect_out" | grep -m1 '^device = ' | sed 's/^device = //')"
        fi
        device="${device//[[:space:]]/}"
        if [[ -n "$device" && -e "$device" ]]; then
            resolve_persistent_device "$device"
            return 0
        fi
        if [[ -n "$device" ]]; then
            warn "gammu-detect suggested ${device} but that device node is missing."
        fi
    fi
    _fallback_serial_device
}

apply_gammu_device() {
    local gammurc="$1"
    local device device_esc
    if device="$(detect_gammu_device)"; then
        DETECTED_DEVICE="$device"
        info "Modem device: ${device}"
        device_esc="$(escape_sed "$device")"
        sed -i "s|^device = .*|device = ${device_esc}|g" "$gammurc"
        return 0
    fi
    warn "No modem detected. Plug in the USB modem and re-run install.sh, or edit device in gammurc."
    return 1
}

generate_udev_rule() {
    local vid="12d1" pid="1c05" ifnum="02"
    local props if_match="" restart_cmd user_name
    local rule_out="${SCRIPT_DIR}/${UDEV_RULE_NAME}"

    if [[ -n "$DETECTED_DEVICE" && -e "$DETECTED_DEVICE" ]] && command -v udevadm >/dev/null 2>&1; then
        props="$(udevadm info -q property -n "$DETECTED_DEVICE" 2>/dev/null || true)"
        local det_vid det_pid det_if
        det_vid="$(printf '%s\n' "$props" | awk -F= '$1=="ID_VENDOR_ID"{print $2; exit}')"
        det_pid="$(printf '%s\n' "$props" | awk -F= '$1=="ID_MODEL_ID"{print $2; exit}')"
        det_if="$(printf '%s\n' "$props" | awk -F= '$1=="ID_USB_INTERFACE_NUM"{print $2; exit}')"
        if [[ -n "$det_vid" && -n "$det_pid" ]]; then
            vid="$det_vid"
            pid="$det_pid"
            ifnum="$det_if"
            info "Udev modem match: ${vid}:${pid}${ifnum:+ (if${ifnum})}"
        fi
    else
        info "No USB modem properties detected; defaulting udev rule to Huawei ${vid}:${pid} (if${ifnum})."
    fi

    if [[ -n "$ifnum" ]]; then
        if_match=", ENV{ID_USB_INTERFACE_NUM}==\"${ifnum}\""
    fi

    if [[ "$INSTALL_USER_MODE" == true ]]; then
        user_name="${USER:-$(whoami)}"
        restart_cmd="/usr/bin/systemctl --machine=${user_name}@.host --user restart --no-block gammu-smsd.service"
    else
        restart_cmd="/usr/bin/systemctl restart --no-block gammu-smsd.service"
    fi

    cp "${SCRIPT_DIR}/${UDEV_RULE_NAME}.example" "$rule_out"
    sed -i \
        -e "s|__VID__|$(escape_sed "$vid")|g" \
        -e "s|__PID__|$(escape_sed "$pid")|g" \
        -e "s|__IF_MATCH__|$(escape_sed "$if_match")|g" \
        -e "s|__RESTART_CMD__|$(escape_sed "$restart_cmd")|g" \
        "$rule_out"
}

generate_configs() {
    local script_esc sms_esc gammurc_esc sysconfig_esc
    local gammu_log_esc gammu_err_log_esc
    script_esc="$(escape_sed "$SCRIPT_DIR")"
    sms_esc="$(escape_sed "${SCRIPT_DIR}/sms")"
    gammurc_esc="$(escape_sed "${SCRIPT_DIR}/gammurc")"
    sysconfig_esc="$(escape_sed "${SCRIPT_DIR}/gammu-smsd.sysconfig")"

    cp "${SCRIPT_DIR}/gammurc.example" "${SCRIPT_DIR}/gammurc"
    sed -i "s|/path/to/home/sms-telegram-bot|${script_esc}|g" "${SCRIPT_DIR}/gammurc"
    sed -i "s|/path/to/home/sms|${sms_esc}|g" "${SCRIPT_DIR}/gammurc"
    apply_gammu_device "${SCRIPT_DIR}/gammurc" || true
    chmod 600 "${SCRIPT_DIR}/gammurc"

    cp "${SCRIPT_DIR}/gammu-smsd.sysconfig.example" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
    sed -i "s|GAMMU_CONFIG_FILE=/etc/gammurc|GAMMU_CONFIG_FILE=${gammurc_esc}|g" \
        "${SCRIPT_DIR}/gammu-smsd.sysconfig"

    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local user_name group_name user_esc group_esc
        mkdir -p "${SCRIPT_DIR}/log"
        user_name="${USER:-$(whoami)}"
        group_name="$(id -gn "$user_name")"
        user_esc="$(escape_sed "$user_name")"
        group_esc="$(escape_sed "$group_name")"
        gammu_log_esc="$(escape_sed "${SCRIPT_DIR}/log/gammu-smsd.log")"
        gammu_err_log_esc="$(escape_sed "${SCRIPT_DIR}/log/gammu-smsd-error.log")"
        sed -i "s|^GAMMU_USER=.*|GAMMU_USER=${user_esc}|g" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
        sed -i "s|^GAMMU_GROUP=.*|GAMMU_GROUP=${group_esc}|g" "${SCRIPT_DIR}/gammu-smsd.sysconfig"
        sed -i "s|^logfile = .*|logfile = ${gammu_log_esc}|g" "${SCRIPT_DIR}/gammurc"
    else
        # System mode runs as GAMMU_USER (typically 'gammu'); log to syslog instead of /smsdlog.
        sed -i "s|^logfile = .*|logfile = syslog|g" "${SCRIPT_DIR}/gammurc"
    fi

    cp "${SCRIPT_DIR}/gammu-smsd.service.example" "${SCRIPT_DIR}/gammu-smsd.service"
    sed -i "s|EnvironmentFile=-/etc/sysconfig/gammu-smsd|EnvironmentFile=-${sysconfig_esc}|g" \
        "${SCRIPT_DIR}/gammu-smsd.service"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        # User systemd has no multi-user.target; default.target is the session default.
        sed -i 's|WantedBy=multi-user.target|WantedBy=default.target|g' \
            "${SCRIPT_DIR}/gammu-smsd.service"
        # User service: Type=simple, no --daemon (foreground test showed fork/PIDFile issues).
        local pid_file pid_esc
        pid_file="${SCRIPT_DIR}/gammu-smsd.pid"
        pid_esc="$(escape_sed "$pid_file")"
        sed -i 's|^Type=forking|Type=simple|' "${SCRIPT_DIR}/gammu-smsd.service"
        sed -i '/^PIDFile=/d' "${SCRIPT_DIR}/gammu-smsd.service"
        sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/gammu-smsd -l -c \${GAMMU_CONFIG_FILE} --pid=${pid_esc}|" \
            "${SCRIPT_DIR}/gammu-smsd.service"
        sed -i "s|^ExecStopPost=.*|ExecStopPost=/bin/rm -f ${pid_esc}|" \
            "${SCRIPT_DIR}/gammu-smsd.service"
        sed -i "/^\[Service\]/a StandardError=append:${gammu_err_log_esc}" \
            "${SCRIPT_DIR}/gammu-smsd.service"
    fi

    chmod +x "${SCRIPT_DIR}/gammu-smsd-watchdog.sh"
    cp "${SCRIPT_DIR}/gammu-smsd-watchdog.service.example" "${SCRIPT_DIR}/gammu-smsd-watchdog.service"
    sed -i "s|/path/to/home/sms-telegram-bot|${script_esc}|g" "${SCRIPT_DIR}/gammu-smsd-watchdog.service"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        sed -i "s|^ExecStart=.*|ExecStart=${script_esc}/gammu-smsd-watchdog.sh --user --gammurc ${gammurc_esc} --log ${gammu_log_esc}|" \
            "${SCRIPT_DIR}/gammu-smsd-watchdog.service"
    fi
    cp "${SCRIPT_DIR}/gammu-smsd-watchdog.timer.example" "${SCRIPT_DIR}/gammu-smsd-watchdog.timer"

    generate_udev_rule

    if grep -qE '\$SCRIPT_DIR|\$\{SCRIPT_DIR\}|/path/to/home/' \
        "${SCRIPT_DIR}/gammurc" \
        "${SCRIPT_DIR}/gammu-smsd.sysconfig" \
        "${SCRIPT_DIR}/gammu-smsd.service" \
        "${SCRIPT_DIR}/gammu-smsd-watchdog.service" 2>/dev/null; then
        error "Generated configs still contain unresolved placeholder variables."
    fi
}

create_sms_dirs() {
    mkdir -p \
        "${SCRIPT_DIR}/sms/inbox" \
        "${SCRIPT_DIR}/sms/read" \
        "${SCRIPT_DIR}/sms/outbox" \
        "${SCRIPT_DIR}/sms/sent" \
        "${SCRIPT_DIR}/sms/error"
}

stop_gammu_smsd_if_active() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        systemctl --user stop gammu-smsd-watchdog.timer 2>/dev/null || true
    else
        "${SUDO_CMD[@]}" systemctl stop gammu-smsd-watchdog.timer 2>/dev/null || true
    fi
    if ! gammu_smsd_is_active; then
        return 0
    fi
    info "Stopping gammu-smsd for install cleanup..."
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        systemctl --user stop gammu-smsd.service 2>/dev/null || true
    else
        "${SUDO_CMD[@]}" systemctl stop gammu-smsd.service 2>/dev/null || true
    fi
}

cleanup_conflicting_systemd_unit() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local has_conflict=false
        if [[ -e /etc/systemd/system/gammu-smsd.service \
            || -e /etc/systemd/system/gammu-smsd-watchdog.timer \
            || -e /etc/systemd/system/gammu-smsd-watchdog.service ]] \
            || systemctl is-enabled --quiet gammu-smsd.service 2>/dev/null \
            || systemctl is-active --quiet gammu-smsd.service 2>/dev/null; then
            has_conflict=true
        fi
        [[ "$has_conflict" == true ]] || return 0

        warn "System-level gammu-smsd.service is also installed/enabled."
        warn "Running both system and --user services causes SysV shared-memory conflicts (Error 13: Permission denied)."

        local do_cleanup=false
        if [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then
            do_cleanup=true
        elif [[ -t 0 ]]; then
            local reply
            read -r -p "Disable and remove the conflicting system unit(s) with sudo now? [Y/n] " reply
            reply="${reply:-Y}"
            if [[ "$reply" =~ ^[Yy]$ ]]; then
                do_cleanup=true
            fi
        fi

        if [[ "$do_cleanup" == true ]]; then
            info "Disabling and removing conflicting system gammu-smsd unit(s)..."
            "${SUDO_CMD[@]}" systemctl disable --now \
                gammu-smsd.service \
                gammu-smsd-watchdog.timer \
                gammu-smsd-watchdog.service 2>/dev/null || true
            "${SUDO_CMD[@]}" rm -f \
                /etc/systemd/system/gammu-smsd.service \
                /etc/systemd/system/gammu-smsd-watchdog.service \
                /etc/systemd/system/gammu-smsd-watchdog.timer
            "${SUDO_CMD[@]}" systemctl daemon-reload
            return 0
        fi

        error "Conflicting system unit left enabled. Run these commands first, then re-run ./install.sh --user:
  sudo systemctl disable --now gammu-smsd.service gammu-smsd-watchdog.timer gammu-smsd-watchdog.service
  sudo rm -f /etc/systemd/system/gammu-smsd.service /etc/systemd/system/gammu-smsd-watchdog.service /etc/systemd/system/gammu-smsd-watchdog.timer
  sudo systemctl daemon-reload"
    else
        local user_home user_unit_dir
        user_home="$(getent passwd "$RUN_AS_USER" 2>/dev/null | cut -d: -f6 || true)"
        [[ -n "$user_home" ]] || return 0
        user_unit_dir="${user_home}/.config/systemd/user"
        if [[ ! -e "${user_unit_dir}/gammu-smsd.service" \
            && ! -e "${user_unit_dir}/gammu-smsd-watchdog.timer" \
            && ! -e "${user_unit_dir}/gammu-smsd-watchdog.service" ]]; then
            return 0
        fi

        warn "Found conflicting user-level gammu-smsd unit(s) for ${RUN_AS_USER}; disabling and removing them..."
        "${SUDO_CMD[@]}" systemctl --machine="${RUN_AS_USER}@.host" --user disable --now \
            gammu-smsd.service \
            gammu-smsd-watchdog.timer \
            gammu-smsd-watchdog.service 2>/dev/null || true
        "${SUDO_CMD[@]}" rm -f \
            "${user_unit_dir}/gammu-smsd.service" \
            "${user_unit_dir}/gammu-smsd-watchdog.service" \
            "${user_unit_dir}/gammu-smsd-watchdog.timer" \
            "${user_unit_dir}"/*.wants/gammu-smsd.service \
            "${user_unit_dir}"/*.wants/gammu-smsd-watchdog.timer \
            "${user_unit_dir}"/*.wants/gammu-smsd-watchdog.service
        "${SUDO_CMD[@]}" systemctl --machine="${RUN_AS_USER}@.host" --user daemon-reload 2>/dev/null || true
    fi
}

archive_log_files() {
    local log_dir="${SCRIPT_DIR}/log"
    local epoch log_file base archived

    mkdir -p "$log_dir"
    epoch="$(date +%s)"

    shopt -s nullglob
    for log_file in "${log_dir}"/*.log; do
        base="$(basename "$log_file" .log)"
        archived="${log_dir}/${base}.${epoch}.log.old"
        info "Archiving ${log_file} -> ${archived}"
        mv "$log_file" "$archived"
    done
    shopt -u nullglob
}

clear_inbox_spool() {
    local inbox="${SCRIPT_DIR}/sms/inbox"
    local count=0 f

    mkdir -p "$inbox"
    shopt -s nullglob
    for f in "${inbox}"/*.txt; do
        rm -f "$f"
        count=$((count + 1))
    done
    shopt -u nullglob
    if [[ "$count" -gt 0 ]]; then
        info "Removed ${count} file(s) from sms/inbox/"
    fi
}

prepare_install_state() {
    cleanup_conflicting_systemd_unit
    stop_gammu_smsd_if_active
    archive_log_files
    clear_inbox_spool
}

# Print path to a non-empty config.pkl at repo root, or return 1 if none exists.
config_pkl_path() {
    local config_pkl="${SCRIPT_DIR}/config.pkl"
    if [[ -s "$config_pkl" ]]; then
        echo "$config_pkl"
        return 0
    fi
    return 1
}

setup_config_pkl() {
    local config_pkl="${SCRIPT_DIR}/config.pkl"
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
            info "  .venv/bin/python src/models/configuration.py ${SCRIPT_DIR}/config.pkl"
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

install_udev_rule() {
    local rule_src="${SCRIPT_DIR}/${UDEV_RULE_NAME}"
    [[ -f "$rule_src" ]] || return 0

    local do_install=false
    if [[ "$INSTALL_USER_MODE" != true ]]; then
        do_install=true
    elif [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then
        do_install=true
    elif [[ -t 0 ]]; then
        local reply
        read -r -p "Install udev rule to ${UDEV_RULE_DST} for automatic USB reconnect recovery (requires sudo)? [Y/n] " reply
        reply="${reply:-Y}"
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            do_install=true
        fi
    fi

    if [[ "$do_install" == true ]]; then
        info "Installing udev rule to ${UDEV_RULE_DST}..."
        "${SUDO_CMD[@]}" cp "$rule_src" "$UDEV_RULE_DST"
        "${SUDO_CMD[@]}" udevadm control --reload-rules
        info "Reloaded udev rules."
    else
        warn "udev rule generated at ${rule_src} but not installed (requires sudo)."
        info "Install it for automatic USB disconnect recovery:"
        info "  sudo cp ${rule_src} ${UDEV_RULE_DST} && sudo udevadm control --reload-rules"
    fi
}

install_systemd_unit() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        info "Installing user systemd units (gammu-smsd + watchdog timer)..."
        mkdir -p "$user_unit_dir"
        cp "${SCRIPT_DIR}/gammu-smsd.service" "${user_unit_dir}/gammu-smsd.service"
        cp "${SCRIPT_DIR}/gammu-smsd-watchdog.service" "${user_unit_dir}/gammu-smsd-watchdog.service"
        cp "${SCRIPT_DIR}/gammu-smsd-watchdog.timer" "${user_unit_dir}/gammu-smsd-watchdog.timer"
        systemctl --user daemon-reload
        systemctl --user enable gammu-smsd.service
        systemctl --user enable --now gammu-smsd-watchdog.timer
        info "Reloaded user systemd units."
    else
        info "Installing system systemd units (gammu-smsd + watchdog timer)..."
        "${SUDO_CMD[@]}" cp "${SCRIPT_DIR}/gammu-smsd.service" \
            /etc/systemd/system/gammu-smsd.service
        "${SUDO_CMD[@]}" cp "${SCRIPT_DIR}/gammu-smsd-watchdog.service" \
            /etc/systemd/system/gammu-smsd-watchdog.service
        "${SUDO_CMD[@]}" cp "${SCRIPT_DIR}/gammu-smsd-watchdog.timer" \
            /etc/systemd/system/gammu-smsd-watchdog.timer
        "${SUDO_CMD[@]}" systemctl daemon-reload
        "${SUDO_CMD[@]}" systemctl enable gammu-smsd.service
        "${SUDO_CMD[@]}" systemctl enable --now gammu-smsd-watchdog.timer
        info "Reloaded system systemd units."
    fi
    start_gammu_smsd
    install_udev_rule
}

print_linger_warning() {
    local yellow cyan bold reset user_name
    user_name="${USER:-$(whoami)}"
    if use_color; then
        yellow=$'\033[1;33m'
        cyan=$'\033[0;36m'
        bold=$'\033[1m'
        reset=$'\033[0m'
    else
        yellow="" cyan="" bold="" reset=""
    fi
    echo ""
    echo "${yellow}================================================================${reset}"
    echo "${bold}${yellow} IMPORTANT: Enable user lingering for gammu-smsd after logout${reset}"
    echo ""
    echo "   ${cyan}sudo loginctl enable-linger ${user_name}${reset}"
    echo ""
    echo "${yellow} Without this, the user-level gammu-smsd service stops when${reset}"
    echo "${yellow} you log out.${reset}"
    echo "${yellow}================================================================${reset}"
    echo ""
}

uninstall_systemd_unit() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        local user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        info "Stopping and removing user systemd units..."
        systemctl --user disable --now \
            gammu-smsd-watchdog.timer \
            gammu-smsd-watchdog.service \
            gammu-smsd.service 2>/dev/null || true
        rm -f \
            "${user_unit_dir}/gammu-smsd.service" \
            "${user_unit_dir}/gammu-smsd-watchdog.service" \
            "${user_unit_dir}/gammu-smsd-watchdog.timer"
        systemctl --user daemon-reload
        info "Removed user systemd units (if installed)."
        if [[ -e "$UDEV_RULE_DST" ]]; then
            if [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then
                "${SUDO_CMD[@]}" rm -f "$UDEV_RULE_DST"
                "${SUDO_CMD[@]}" udevadm control --reload-rules
                info "Removed ${UDEV_RULE_DST}."
            else
                warn "${UDEV_RULE_DST} is still installed. Remove it with:"
                info "  sudo rm -f ${UDEV_RULE_DST} && sudo udevadm control --reload-rules"
            fi
        fi
    else
        require_sudo
        info "Stopping and removing system systemd units..."
        "${SUDO_CMD[@]}" systemctl disable --now \
            gammu-smsd-watchdog.timer \
            gammu-smsd-watchdog.service \
            gammu-smsd.service 2>/dev/null || true
        "${SUDO_CMD[@]}" rm -f \
            /etc/systemd/system/gammu-smsd.service \
            /etc/systemd/system/gammu-smsd-watchdog.service \
            /etc/systemd/system/gammu-smsd-watchdog.timer
        "${SUDO_CMD[@]}" systemctl daemon-reload
        if [[ -e "$UDEV_RULE_DST" ]]; then
            "${SUDO_CMD[@]}" rm -f "$UDEV_RULE_DST"
            "${SUDO_CMD[@]}" udevadm control --reload-rules
            info "Removed ${UDEV_RULE_DST}."
        fi
        info "Removed system systemd units (if installed)."
    fi
}

remove_install_artifacts() {
    info "Removing project install artifacts..."
    rm -rf "${SCRIPT_DIR}/.venv"
    rm -f \
        "${SCRIPT_DIR}/gammurc" \
        "${SCRIPT_DIR}/gammu-smsd.sysconfig" \
        "${SCRIPT_DIR}/gammu-smsd.service" \
        "${SCRIPT_DIR}/gammu-smsd-watchdog.service" \
        "${SCRIPT_DIR}/gammu-smsd-watchdog.timer" \
        "${SCRIPT_DIR}/${UDEV_RULE_NAME}" \
        "${SCRIPT_DIR}/gammu-smsd.pid"
}

print_uninstall_summary() {
    echo ""
    info "Uninstall complete."
    info "  Directory: ${SCRIPT_DIR}"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        info "  Mode:        user (systemctl --user)"
    else
        info "  Mode:        system"
    fi
    info "  Left in place: config.pkl, sms/, log/ (if present)"
    info "  Not removed:   python3, gammu, gammu-smsd (system packages)"
    echo ""
}

uninstall_main() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        if ! systemctl --user status >/dev/null 2>&1; then
            error "systemd user session unavailable. Cannot use --user."
        fi
    else
        require_sudo
    fi

    uninstall_systemd_unit
    remove_install_artifacts
    print_uninstall_summary
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
    info "  watchdog:      ${SCRIPT_DIR}/gammu-smsd-watchdog.timer (every 2m)"
    info "  udev rule:     ${SCRIPT_DIR}/${UDEV_RULE_NAME}"
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        info "  Mode:          user (systemctl --user)"
        info "  GAMMU_USER:    ${USER:-$(whoami)}"
        print_linger_warning
        info "  Status:        systemctl --user status gammu-smsd gammu-smsd-watchdog.timer"
    else
        info "  Mode:          system (sudo systemctl)"
        info "  Status:        sudo systemctl status gammu-smsd gammu-smsd-watchdog.timer"
    fi
    info "  Modem device:  ${DETECTED_DEVICE:-see device= in gammurc} (prefers /dev/serial/by-id/...)"
    if [[ "$CONFIG_PKL_READY" != true ]]; then
        warn "  config.pkl: not created — run configuration.py before relying on SMS → Telegram."
    fi
    echo ""
}

install_main() {
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
    prepare_install_state
    setup_venv "$py"
    generate_configs
    create_sms_dirs
    setup_config_pkl

    install_systemd_unit

    print_summary
}

main() {
    require_linux

    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_main
    else
        install_main
    fi
}

main "$@"
