#!/usr/bin/env bash
# Watchdog for gammu-smsd: restarts gammu-smsd.service when Gammu gets wedged
# in a device-error loop (e.g. DEVICEWRITEERROR[11], DEVICENOTEXIST[4], TIMEOUT[14])
# after a USB modem disconnect/reset.
set -euo pipefail

USER_MODE=false
GAMMURC=""
LOG_SOURCE=""
THRESHOLD=3
WINDOW_MINUTES=5
GRACE_SECONDS=90

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            USER_MODE=true
            shift
            ;;
        --gammurc)
            GAMMURC="${2:?--gammurc requires a path}"
            shift 2
            ;;
        --log)
            LOG_SOURCE="${2:?--log requires a path}"
            shift 2
            ;;
        --threshold)
            THRESHOLD="${2:?--threshold requires a number}"
            shift 2
            ;;
        --window-minutes)
            WINDOW_MINUTES="${2:?--window-minutes requires a number}"
            shift 2
            ;;
        --grace-seconds)
            GRACE_SECONDS="${2:?--grace-seconds requires a number}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

CTL=(systemctl)
if [[ "$USER_MODE" == true ]]; then
    CTL=(systemctl --user)
fi

log_msg() {
    echo "gammu-smsd-watchdog: $*" >&2
}

state="$("${CTL[@]}" is-active gammu-smsd.service 2>/dev/null || true)"
if [[ "$state" == "failed" ]]; then
    log_msg "gammu-smsd.service is in failed state — restarting."
    "${CTL[@]}" restart gammu-smsd.service
    exit 0
fi
if [[ "$state" != "active" ]]; then
    # Respect manual stop or in-progress activation/restart.
    exit 0
fi

main_pid="$("${CTL[@]}" show -p MainPID --value gammu-smsd.service 2>/dev/null || echo 0)"
if [[ -z "$main_pid" || "$main_pid" == "0" ]]; then
    exit 0
fi

active_mono_us="$("${CTL[@]}" show -p ActiveEnterTimestampMonotonic --value gammu-smsd.service 2>/dev/null || echo 0)"
if [[ -n "$active_mono_us" && "$active_mono_us" =~ ^[0-9]+$ && "$active_mono_us" -gt 0 && -r /proc/uptime ]]; then
    uptime_s="$(awk '{printf "%d\n", $1}' /proc/uptime)"
    active_s=$((active_mono_us / 1000000))
    age_s=$((uptime_s - active_s))
    if [[ "$age_s" -lt "$GRACE_SECONDS" ]]; then
        exit 0
    fi
fi

if [[ -z "$LOG_SOURCE" && -n "$GAMMURC" && -r "$GAMMURC" ]]; then
    LOG_SOURCE="$(awk -F= '/^[[:space:]]*logfile[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$GAMMURC" || true)"
fi

if [[ -z "$LOG_SOURCE" ]]; then
    exit 0
fi

ERROR_RE='DEVICEWRITEERROR[[]11[]]|DEVICEREADERROR[[]12[]]|DEVICENOTEXIST[[]4[]]|DEVICEOPENERROR[[]2[]]|TIMEOUT[[]14[]]'
SUCCESS_RE='Soft reset return code: No error|Received |Process finished successfully|Read [0-9]+ messages'

count_errors() {
    local count=0
    if [[ "$LOG_SOURCE" == "syslog" ]]; then
        count="$(
            journalctl -t gammu-smsd --since "${WINDOW_MINUTES} minutes ago" --no-pager -o short 2>/dev/null \
                | awk -v pid="$main_pid" -v err_re="$ERROR_RE" -v ok_re="$SUCCESS_RE" '
                    index($0, "gammu-smsd[" pid "]:") {
                        if ($0 ~ ok_re) { errors = 0 }
                        else if ($0 ~ err_re) { errors++ }
                    }
                    END { print errors + 0 }
                '
        )"
    elif [[ -r "$LOG_SOURCE" ]]; then
        local cutoff
        cutoff="$(date -d "${WINDOW_MINUTES} minutes ago" '+%Y/%m/%d %H:%M:%S')"
        count="$(
            tail -n 500 "$LOG_SOURCE" \
                | awk -v pid="$main_pid" -v cutoff="$cutoff" -v err_re="$ERROR_RE" -v ok_re="$SUCCESS_RE" '
                    $4 == ("gammu-smsd[" pid "]:") && ($2 " " $3) >= cutoff {
                        if ($0 ~ ok_re) { errors = 0 }
                        else if ($0 ~ err_re) { errors++ }
                    }
                    END { print errors + 0 }
                '
        )"
    fi
    echo "${count:-0}"
}

errors="$(count_errors)"
if [[ "$errors" -ge "$THRESHOLD" ]]; then
    log_msg "detected ${errors} recent device error(s) for gammu-smsd[${main_pid}] — restarting gammu-smsd.service."
    "${CTL[@]}" restart gammu-smsd.service
fi
