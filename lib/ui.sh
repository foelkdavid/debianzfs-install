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
    VT_STATUS='Full log VT will be allocated after Start.'
}

allocate_log_vt() {
    VT_STATUS='File logging only (no unused Linux VT available)'
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
        VT_STATUS="Full log: Ctrl+Alt+F${device##*/tty}; return to your installer TTY."
    fi
}

header_content() {
    printf 'Debian ZFS installer | Boot mode: %s\n%s\nLog: %s\n\n' \
        "$BOOT_MODE" "$VT_STATUS" "$LOG_FILE"
}

terminal_size() {
    # Ignore exported shell dimensions; query the actual terminal after resize.
    UI_ROWS=$(env -u LINES -u COLUMNS tput lines <&3 2>/dev/null || echo 24)
    UI_COLS=$(env -u LINES -u COLUMNS tput cols <&3 2>/dev/null || echo 80)
    [[ $UI_ROWS =~ ^[0-9]+$ && $UI_ROWS -ge 3 ]] || UI_ROWS=24
    [[ $UI_COLS =~ ^[0-9]+$ && $UI_COLS -ge 2 ]] || UI_COLS=80
}

sanitize_output() {
    # Package progress may contain CRs, tabs, colour codes and OSC sequences.
    # Keep those controls out of the UI; the complete original stays in the log.
    LC_ALL=C sed -E 's/\x1B\][^\x07]*(\x07|\x1B\\)//g; s/\x1B\[[0-?]*[ -/]*[@-~]//g; s/\t/    /g; s/[^[:print:]]//g'
}

draw_frame() {
    local frame
    # Leave the last column and row unused: auto-wrap and a bottom-row newline
    # otherwise scroll the terminal. Emit one frame, without a trailing LF.
    frame=$(sanitize_output | LC_ALL=C awk -v width="$((UI_COLS - 1))" -v height="$((UI_ROWS - 1))" \
        'NR <= height { print substr($0, 1, width) }')
    printf '\033[H%s\033[J' "$frame" >&3
}

screen_header() {
    if "$UI_TTY"; then
        terminal_size
        local header
        header=$(header_content)
        printf '\033[H\033[2J%s\n\n' "$header" >&3
    else
        header_content >&3
    fi
}

render_stage() {
    local count window visible start index
    terminal_size
    count=${#COMPLETED[@]}
    visible=$((UI_ROWS / 3))
    ((visible <= UI_ROWS - 10)) || visible=$((UI_ROWS > 10 ? UI_ROWS - 10 : 0))
    ((visible <= count)) || visible=$count
    ((visible >= 0)) || visible=0
    start=$((count - visible))
    window=$((UI_ROWS - visible - 8 - (start > 0)))
    ((window >= 1)) || window=1
    {
        header_content
        if ((start)); then printf '[passed] %s earlier stages (full list in log)\n' "$start"; fi
        for ((index=start; index<count; index++)); do
            printf '[passed] %s\n' "${COMPLETED[index]}"
        done
        if [[ ${CURRENT_STATE:-running} == running ]]; then
            printf '[running] %s\n' "$CURRENT_STAGE"
        fi
        printf '\n'
        tail -n "$window" "$STAGE_OUTPUT"
    } | draw_frame
}

stop_renderer() {
    if [[ -n ${RENDER_PID:-} ]]; then
        # Let an in-flight frame finish before the parent draws another screen.
        # Killing only the loop could leave its pipeline writing a stale frame.
        : > "$WORK_DIR/render-stop"
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
        done < "$fifo"
    ) &
    LOGGER_PID=$!
    if "$UI_TTY"; then
        rm -f -- "$WORK_DIR/render-stop"
        printf '\033[?25l' >&3
        (
            trap - ERR EXIT INT TERM
            while [[ ! -e $WORK_DIR/render-stop ]]; do render_stage; sleep .2; done
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
    if "$UI_TTY"; then
        render_stage
        printf '\033[?25h' >&3
    else
        printf '[passed] %s\n' "$CURRENT_STAGE" >&3
    fi
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
