#!/usr/bin/env bash
# Shared globals are consumed by the installer/deployment.
# shellcheck disable=SC2034
# Shared stage display. Commands deliberately run in the calling shell, outside
# conditionals/pipelines: Bash must retain errexit inside nested stage functions.

ui_init() {
    UI_TTY=false
    [[ -t 1 && ${TERM:-dumb} != dumb && ${TERM:-} != '' ]] && UI_TTY=true
    exec 3>&1
    UI_STTY=$(stty -g 2>/dev/null || true)
    COMPLETED=()
    CURRENT_STAGE='Setup'
    LOG_DIR=${LOG_DIR:-/var/log/debianzfs-install}
    install -d -m 700 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/install-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    WORK_DIR=$(mktemp -d)
    STAGE_OUTPUT="$WORK_DIR/stage.log"
    : > "$STAGE_OUTPUT"
    VT_STATUS='File logging only (no unused Linux VT available)'
    allocate_log_vt
}

allocate_log_vt() {
    # openvt without -f/-s uses VT_OPENQRY, refuses occupied VTs and never
    # switches focus. Let it retain the allocated console until tail exits.
    command -v openvt >/dev/null || return 0
    command -v fgconsole >/dev/null || return 0
    fgconsole >/dev/null 2>&1 || return 0
    # The script arguments are expanded by the new VT shell.
    # shellcheck disable=SC2016
    openvt -w -- bash -c '
        tty > "$1"
        exec tail -n +1 -f -- "$2"
    ' bash "$WORK_DIR/log-vt" "$LOG_FILE" 2>"$WORK_DIR/vt-error" &
    VT_PID=$!
    local attempt
    for attempt in {1..20}; do
        [[ -s "$WORK_DIR/log-vt" ]] && break
        kill -0 "$VT_PID" 2>/dev/null || break
        sleep .05
    done
    if [[ -s "$WORK_DIR/log-vt" ]]; then
        local device
        read -r device < "$WORK_DIR/log-vt"
        VT_STATUS="Full log: ${device} — Ctrl+Alt+F${device##*/tty} (return to your installer TTY)"
    fi
}

screen_header() {
    "$UI_TTY" && printf '\033[H\033[2J' >&3
    printf 'Debian ZFS installer | Boot mode: %s\n%s\nLog: %s\n\n' \
        "$BOOT_MODE" "$VT_STATUS" "$LOG_FILE" >&3
}

render_stage() {
    local rows cols count window step visible start index
    # Ignore exported shell dimensions; query the actual terminal after resize.
    rows=$(env -u LINES -u COLUMNS tput lines <&3 2>/dev/null || echo 24)
    cols=$(env -u LINES -u COLUMNS tput cols <&3 2>/dev/null || echo 80)
    count=${#COMPLETED[@]}
    visible=$((rows / 3))
    ((visible <= count)) || visible=$count
    ((visible >= 0)) || visible=0
    start=$((count - visible))
    window=$((rows - visible - 10))
    ((window >= 2)) || window=2
    screen_header
    if ((start)); then printf '[passed] %s earlier stages (full list in log)\n' "$start" >&3; fi
    for ((index=start; index<count; index++)); do
        step=${COMPLETED[index]}
        printf '[passed] %.*s\n' "$((cols > 10 ? cols - 10 : 1))" "$step" >&3
    done
    if [[ ${CURRENT_STATE:-running} == running ]]; then
        printf '[running] %s\n\n' "$CURRENT_STAGE" >&3
    else
        printf '\n' >&3
    fi
    # Strip terminal controls from package output and bound both dimensions.
    tail -n "$window" "$STAGE_OUTPUT" | LC_ALL=C sed -E 's/\x1B\[[0-?]*[ -/]*[@-~]//g; s/[^[:print:]\t]//g' | cut -c "1-$cols" >&3
}

stop_renderer() {
    if [[ -n ${RENDER_PID:-} ]]; then
        kill "$RENDER_PID" 2>/dev/null || true
        wait "$RENDER_PID" 2>/dev/null || true
        unset RENDER_PID
    fi
}

drain_stage() {
    if [[ -n ${LOGGER_PID:-} ]]; then
        wait "$LOGGER_PID" || true
        unset LOGGER_PID
    fi
    stop_renderer
}

run_stage() {
    CURRENT_STATE=running
    CURRENT_STAGE=$1
    shift
    : > "$STAGE_OUTPUT"
    printf '[%s] [running] %s\n' "$(date -u +%FT%TZ)" "$CURRENT_STAGE" >> "$LOG_FILE"
    local fifo="$WORK_DIR/output.fifo"
    [[ ! -p $fifo ]] || rm -- "$fifo"
    mkfifo -m 600 "$fifo"
    (
        trap - ERR EXIT INT TERM
        while IFS= read -r line || [[ -n $line ]]; do
            printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$line" >> "$LOG_FILE"
            printf '%s\n' "$line" >> "$STAGE_OUTPUT"
            "$UI_TTY" || printf '%s\n' "$line" >&3
        done < "$fifo"
    ) &
    LOGGER_PID=$!
    if "$UI_TTY"; then
        printf '\033[?25l' >&3
        (
            trap - ERR EXIT INT TERM
            while :; do render_stage; sleep .2; done
        ) &
        RENDER_PID=$!
    else
        printf '[running] %s\n' "$CURRENT_STAGE" >&3
    fi
    "$@" > "$fifo" 2>&1
    # Never wrap the command above in `if`, `!`, `||` or a subshell. EXIT
    # performs drain/cleanup on errors; successful variable changes survive.
    drain_stage
    CURRENT_STATE=passed
    COMPLETED+=("$CURRENT_STAGE")
    printf '[%s] [passed] %s\n' "$(date -u +%FT%TZ)" "$CURRENT_STAGE" >> "$LOG_FILE"
    if "$UI_TTY"; then render_stage; printf '\033[?25h' >&3; fi
    printf '[passed] %s\n' "$CURRENT_STAGE" >&3
}

ui_restore() {
    stop_renderer
    if [[ -n ${VT_PID:-} ]]; then
        # openvt -w waits for its child; stop the tail before the parent.
        pkill -TERM -P "$VT_PID" 2>/dev/null || true
        kill "$VT_PID" 2>/dev/null || true
        wait "$VT_PID" 2>/dev/null || true
    fi
    if "$UI_TTY"; then
        printf '\033[?25h\033[0m\n' >&3
        [[ -z $UI_STTY ]] || stty "$UI_STTY" 2>/dev/null || true
    fi
}
