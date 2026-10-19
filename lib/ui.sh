#!/usr/bin/env bash
# Shared globals are consumed by the installer/deployment.
# shellcheck disable=SC2034
# Match voidzfs-install's palette and helpers. Commands still run in the calling
# shell, outside conditionals/pipelines, so nested failures and state survive.

init_colors() {
    R='' G='' Y='' P='' LG='' LB='' NC=''
    if [[ ${UI_TTY:-false} == true && ! -v NO_COLOR ]]; then
        R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[0;33m'
        P=$'\033[0;35m' LG=$'\033[1;32m' LB=$'\033[1;34m' NC=$'\033[0m'
    fi
}
init_colors

info() {
    if [[ -t 1 ]]; then printf '%b%s%b\n' "$P" "$*" "$NC"; else printf '%s\n' "$*"; fi
}
note() {
    if [[ -t 1 ]]; then printf '  %b%s%b\n' "$LB" "$*" "$NC"; else printf '  %s\n' "$*"; fi
}
ok() {
    if [[ -t 1 ]]; then printf '  %b✔%b %s\n' "$G" "$NC" "$*"; else printf '[passed] %s\n' "$*"; fi
}
failhard() {
    if [[ -t 2 ]]; then printf '  %b✘ %s%b\n' "$R" "$*" "$NC" >&2; else printf '[failed] %s\n' "$*" >&2; fi
}

ui_init() {
    UI_TTY=false
    [[ -t 1 && ${TERM:-dumb} != dumb && ${TERM:-} != '' ]] && UI_TTY=true
    init_colors
    exec 3>&1
    UI_STTY=$(stty -g <&3 2>/dev/null || true)
    CURRENT_STAGE='Setup'
    LOG_DIR=${LOG_DIR:-/var/log/debianzfs-install}
    install -d -m 700 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/install-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    WORK_DIR=$(mktemp -d)
    STAGE_OUTPUT="$WORK_DIR/stage.log"
    : > "$STAGE_OUTPUT"
}

frame_line() {
    local LC_ALL=C.UTF-8 color=$1 text=$2
    # Clip visible text BEFORE applying our own colour. Package escape codes
    # are sanitized separately; they must not strip the installer's palette.
    if [[ -n ${FRAME_WIDTH:-} ]]; then text=${text:0:FRAME_WIDTH}; fi
    printf '%b%s%b\n' "${!color}" "$text" "$NC"
}

separator() { frame_line NC '────────────────────────────────────────────'; }
header_content() {
    separator
    frame_line G "Debian-ZFS-Installer | Boot mode: $BOOT_MODE"
    separator
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
    # Keep those controls out of the preview; the original stays in the log.
    LC_ALL=C sed -E 's/\x1B\][^\x07]*(\x07|\x1B\\)//g; s/\x1B\[[0-?]*[ -/]*[@-~]//g; s/\t/    /g; s/[^[:print:]]//g'
}

screen_header() {
    restore_terminal_mode
    "$UI_TTY" && printf '\033[H\033[2J' >&3
    header_content >&3
}

stage_preview() { tail -n 5 "$STAGE_OUTPUT" | sanitize_output; }

paint_frame() {
    local line row=0 painted=$'\033[H\033[?7l'
    while IFS= read -r line; do
        ((row+=1))
        # Position and erase EVERY row, including blank rows. Newlines depend
        # on termios flags that package scripts may change while we render.
        printf -v painted '%s\033[%s;1H\033[2K%s' "$painted" "$row" "$line"
    done <<< "$1"
    printf '%s\033[J\033[?7h' "$painted" >&3
}

render_stage() {
    local frame window line FRAME_WIDTH
    terminal_size
    FRAME_WIDTH=$((UI_COLS - 1))
    window=$((UI_ROWS - 8))
    if ((UI_ROWS < 9)); then window=$((UI_ROWS - 4)); fi
    if ((UI_ROWS < 6)); then window=$((UI_ROWS - 2)); fi
    ((window <= 5)) || window=5
    ((window >= 1)) || window=1
    frame=$(
        if ((UI_ROWS >= 9)); then
            header_content
            frame_line LB "Log: $LOG_FILE"
            printf '\n'
        elif ((UI_ROWS >= 6)); then
            frame_line G "Debian-ZFS-Installer | Boot mode: $BOOT_MODE"
        fi
        if ((UI_ROWS >= 6)); then
            frame_line P "[$CURRENT_STAGE]"
            printf '\n'
        else
            frame_line P "[$BOOT_MODE] $CURRENT_STAGE"
        fi
        while IFS= read -r line; do frame_line NC "$line"; done < <(tail -n "$window" "$STAGE_OUTPUT" | sanitize_output)
    )
    # One atomic frame, with no trailing LF. Leave the last row/column unused
    # so auto-wrap and bottom-row scrolling cannot corrupt the layout.
    paint_frame "$frame"
}

stop_renderer() {
    if [[ -n ${RENDER_PID:-} ]]; then
        # Wait for any in-flight pipeline before the parent draws another screen.
        : > "$WORK_DIR/render-stop"
        wait "$RENDER_PID" 2>/dev/null || true
        unset RENDER_PID
    fi
}

drain_stage() {
    if [[ -n ${STAGE_READ_FD:-} ]]; then
        exec {STAGE_READ_FD}<&-
        unset STAGE_READ_FD
    fi
    if [[ -n ${STAGE_FIFO_FD:-} ]]; then
        exec {STAGE_FIFO_FD}>&-
        unset STAGE_FIFO_FD
    fi
    if [[ -n ${LOGGER_PID:-} ]]; then
        wait "$LOGGER_PID" || true
        unset LOGGER_PID
    fi
    stop_renderer
}

run_stage() {
    CURRENT_STAGE=$1
    shift
    : > "$STAGE_OUTPUT"
    printf '[%s] [running] %s\n' "$(date -u +%FT%TZ)" "$CURRENT_STAGE" >> "$LOG_FILE"
    local fifo="$WORK_DIR/output.fifo"
    [[ ! -p $fifo ]] || rm -- "$fifo"
    mkfifo -m 600 "$fifo"
    # Keep the FIFO open until command launch. Interrupts during the initial
    # redraw must not leave the logger stuck opening a FIFO with no writer.
    exec {STAGE_FIFO_FD}<> "$fifo"
    # Open its read end before forking too: a fast command can finish before
    # the logger is scheduled. The logger inherits only this read-only end.
    exec {STAGE_READ_FD}< "$fifo"
    (
        trap - ERR EXIT INT TERM
        exec 0<&"$STAGE_READ_FD"
        exec {STAGE_READ_FD}<&-
        exec {STAGE_FIFO_FD}>&-
        while IFS= read -r line || [[ -n $line ]]; do
            printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$line" >> "$LOG_FILE"
            printf '%s\n' "$line" >> "$STAGE_OUTPUT"
        done
    ) &
    LOGGER_PID=$!
    exec {STAGE_READ_FD}<&-
    unset STAGE_READ_FD
    if "$UI_TTY"; then
        rm -f -- "$WORK_DIR/render-stop"
        printf '\033[?25l' >&3
        render_stage
        (
            trap - ERR EXIT INT TERM
            exec {STAGE_FIFO_FD}>&-
            while [[ ! -e $WORK_DIR/render-stop ]]; do sleep .2; render_stage; done
        ) &
        RENDER_PID=$!
    else
        info "[$CURRENT_STAGE]" >&3
    fi
    "$@" < /dev/null > "$fifo" 2>&1
    # Never wrap the command above in `if`, `!`, `||` or a subshell. EXIT
    # performs drain/cleanup on errors; successful variable changes survive.
    drain_stage
    restore_terminal_mode
    printf '[%s] [passed] %s\n' "$(date -u +%FT%TZ)" "$CURRENT_STAGE" >> "$LOG_FILE"
    if "$UI_TTY"; then
        render_stage
        printf '\033[?25h' >&3
    else
        stage_preview >&3
    fi
}

restore_terminal_mode() {
    if "$UI_TTY"; then
        [[ -z $UI_STTY ]] || stty "$UI_STTY" <&3 2>/dev/null || true
    fi
}

ui_restore() {
    stop_renderer
    restore_terminal_mode
    if "$UI_TTY"; then printf '\033[?7h\033[?25h%b\r\n' "$NC" >&3; fi
}
