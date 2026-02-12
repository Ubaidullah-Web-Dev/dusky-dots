#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SwayNC Position Controller - TUI v3.9.2
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
#
# Interactive TUI for toggling SwayNC notification panel position (Left/Right)
# and synchronizing the Hyprland slide animation direction.
#
# Usage: swaync_toggle.sh [OPTION]
#   -l, --left      Set position to Left
#   -r, --right     Set position to Right
#   -t, --toggle    Toggle (flip) position
#   -s, --status    Show current position
#   -h, --help      Show this help
#   (no args)       Launch interactive TUI
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

readonly SWAYNC_CONFIG="${HOME:?HOME is not set}/.config/swaync/config.json"
readonly HYPR_RULES="${HOME}/.config/hypr/source/window_rules.conf"

readonly APP_TITLE="SwayNC Position Controller"
readonly APP_VERSION="v3.9.2"

# Dimensions & Layout
declare -ri BOX_INNER_WIDTH=52
declare -ri MAX_DISPLAY_ROWS=10

declare -ri HEADER_ROWS=4
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

# =============================================================================
# ▲ END OF CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

declare -r ESC_READ_TIMEOUT=0.10

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare ORIGINAL_STTY=""
declare CURRENT_POSITION=""
declare STATUS_MSG=""
declare STATUS_COLOR=""
declare -i NEEDS_REDRAW=1
declare -i TUI_RUNNING=0

# Menu items — the actions the user can take
declare -ra MENU_ITEMS=(
    "Set Position: Left"
    "Set Position: Right"
    "Toggle Position"
    "Refresh Status"
    "Quit"
)
declare -ri MENU_COUNT=${#MENU_ITEMS[@]}

# Icons mapped to each menu item for visual clarity
declare -ra MENU_ICONS=(
    "◀"
    "▶"
    "⇄"
    "↻"
    "✕"
)

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

# CLI-mode logging helpers (only used outside TUI)
cli_die()     {
    if (( TUI_RUNNING )); then
        set_status "ERROR" "$1" "red"
    else
        printf '%s[ERROR]%s %s\n' "${C_RED}" "$C_RESET" "$1" >&2
        exit 1
    fi
}
cli_info()    { printf '%s[INFO]%s %s\n' "${C_CYAN}" "$C_RESET" "$1"; }
cli_warn()    { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "$C_RESET" "$1" >&2; }
cli_success() { printf '%s[SUCCESS]%s %s\n' "${C_GREEN}" "$C_RESET" "$1"; }

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- String Helpers ---

strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

# --- Pre-flight Checks ---

check_dependencies() {
    command -v jq &>/dev/null || cli_die "'jq' is not installed"

    [[ -f "$SWAYNC_CONFIG" ]] || cli_die "SwayNC config not found: $SWAYNC_CONFIG"
    [[ -r "$SWAYNC_CONFIG" ]] || cli_die "SwayNC config not readable: $SWAYNC_CONFIG"
    [[ -w "$SWAYNC_CONFIG" ]] || cli_die "SwayNC config not writable: $SWAYNC_CONFIG"

    [[ -f "$HYPR_RULES" ]] || cli_die "Hyprland rules not found: $HYPR_RULES"
    [[ -r "$HYPR_RULES" ]] || cli_die "Hyprland rules not readable: $HYPR_RULES"
    [[ -w "$HYPR_RULES" ]] || cli_die "Hyprland rules not writable: $HYPR_RULES"
}

# --- Core Logic (Preserved from original) ---

get_current_position() {
    local pos
    pos=$(jq -re '.positionX // empty' "$SWAYNC_CONFIG" 2>/dev/null) || {
        if (( TUI_RUNNING )); then
            set_status "ERROR" "Failed to read positionX from config" "red"
            CURRENT_POSITION="unknown"
            return 1
        else
            cli_die "Failed to read 'positionX' from $SWAYNC_CONFIG"
        fi
    }
    CURRENT_POSITION="$pos"
    printf '%s' "$pos"
}

reload_services() {
    local target_side="$1"
    local -a warnings=()

    if command -v swaync-client &>/dev/null; then
        swaync-client --reload-config &>/dev/null || warnings+=("SwayNC config reload failed")
        swaync-client --reload-css &>/dev/null    || warnings+=("SwayNC CSS reload failed")
    else
        warnings+=("swaync-client not found")
    fi

    if command -v hyprctl &>/dev/null; then
        hyprctl reload &>/dev/null || warnings+=("Hyprland reload failed")
    else
        warnings+=("hyprctl not found")
    fi

    if (( ${#warnings[@]} > 0 )); then
        if (( TUI_RUNNING )); then
            set_status "WARN" "${warnings[0]}" "yellow"
        else
            local w
            for w in "${warnings[@]}"; do
                cli_warn "$w"
            done
        fi
    fi

    if (( ! TUI_RUNNING )); then
        cli_success "Position updated to ${target_side^^}"
    fi
}

apply_changes() {
    local target_side="${1:-}"

    # Validation
    if [[ ! "$target_side" =~ ^(left|right)$ ]]; then
        if (( TUI_RUNNING )); then
            set_status "ERROR" "Invalid side: '$target_side'" "red"
            return 1
        else
            cli_die "Invalid side: '$target_side'. Use 'left' or 'right'"
        fi
    fi

    # Check if already at target position
    local current
    current=$(get_current_position) || return 1
    if [[ "$current" == "$target_side" ]]; then
        if (( TUI_RUNNING )); then
            set_status "INFO" "Already set to ${target_side^}" "cyan"
            return 0
        else
            cli_info "Already set to ${target_side^}"
            return 0
        fi
    fi

    if (( ! TUI_RUNNING )); then
        cli_info "Switching to ${target_side^^}..."
    fi

    # 1. Update SwayNC config
    sed -i 's/\("positionX"[[:space:]]*:[[:space:]]*\)"[^"]*"/\1"'"$target_side"'"/' "$SWAYNC_CONFIG" || {
        if (( TUI_RUNNING )); then
            set_status "ERROR" "Failed to update SwayNC config" "red"
            return 1
        else
            cli_die "Failed to update SwayNC config"
        fi
    }

    # 2. Verify the change
    local actual
    actual=$(jq -re '.positionX // empty' "$SWAYNC_CONFIG" 2>/dev/null) || actual=""
    if [[ "$actual" != "$target_side" ]]; then
        if (( TUI_RUNNING )); then
            set_status "ERROR" "Verification failed! Config did not update" "red"
            return 1
        else
            cli_die "Verification failed! Config did not update."
        fi
    fi

    # 3. Update Hyprland animation rules
    if grep -q 'name = swaync_slide' "$HYPR_RULES" 2>/dev/null; then
        sed -i "/name = swaync_slide/,/}/ s/animation = slide .*/animation = slide $target_side/" "$HYPR_RULES" || {
            if (( TUI_RUNNING )); then
                set_status "WARN" "Failed to update Hyprland animation rule" "yellow"
            else
                cli_warn "Failed to update Hyprland animation rule"
            fi
        }
    else
        if (( TUI_RUNNING )); then
            set_status "WARN" "swaync_slide block not found in rules" "yellow"
        else
            cli_warn "Block 'swaync_slide' not found in $HYPR_RULES. Animation not updated."
        fi
    fi

    # 4. Update cached state
    CURRENT_POSITION="$target_side"

    # 5. Reload services
    reload_services "$target_side"

    if (( TUI_RUNNING )); then
        set_status "OK" "Position set to ${target_side^}" "green"
    fi

    return 0
}

toggle_position() {
    local current
    current=$(get_current_position) || return 1
    case "$current" in
        left)  apply_changes "right" ;;
        right) apply_changes "left" ;;
        *)
            if (( TUI_RUNNING )); then
                set_status "ERROR" "Unknown current position: '$current'" "red"
                return 1
            else
                cli_die "Unknown current position: '$current'"
            fi
            ;;
    esac
}

# --- TUI Status Management ---

set_status() {
    local level="$1" msg="$2" color="${3:-cyan}"
    case "$color" in
        red)    STATUS_COLOR="$C_RED" ;;
        green)  STATUS_COLOR="$C_GREEN" ;;
        yellow) STATUS_COLOR="$C_YELLOW" ;;
        cyan)   STATUS_COLOR="$C_CYAN" ;;
        *)      STATUS_COLOR="$C_WHITE" ;;
    esac
    STATUS_MSG="${level}: ${msg}"
    NEEDS_REDRAW=1
}

# --- TUI Rendering Engine ---

compute_scroll_window() {
    local -i count=$1
    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
        _vis_start=0; _vis_end=0
        return
    fi

    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    if (( max_scroll < 0 )); then max_scroll=0; fi
    if (( SCROLL_OFFSET > max_scroll )); then SCROLL_OFFSET=$max_scroll; fi

    _vis_start=$SCROLL_OFFSET
    _vis_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    if (( _vis_end > count )); then _vis_end=$count; fi
}

draw_ui() {
    local buf="" pad_buf=""
    local -i left_pad right_pad vis_len pad_needed
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"

    # ┌─ Top border ─┐
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    # │ Title + Version │
    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$APP_VERSION"; local -i v_len=${#REPLY}
    vis_len=$(( t_len + v_len + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))
    if (( left_pad < 0 )); then left_pad=0; fi
    if (( right_pad < 0 )); then right_pad=0; fi

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # │ Current Position │
    local pos_display pos_color pos_icon
    case "$CURRENT_POSITION" in
        left)    pos_color="$C_CYAN";   pos_icon="◀ " ;;
        right)   pos_color="$C_GREEN";  pos_icon="▶ " ;;
        *)       pos_color="$C_RED";    pos_icon="? " ;;
    esac
    local pos_line=" Current: ${pos_icon}${CURRENT_POSITION^}"
    strip_ansi "$pos_line"; local -i p_len=${#REPLY}
    pad_needed=$(( BOX_INNER_WIDTH - p_len ))
    if (( pad_needed < 0 )); then pad_needed=0; fi
    printf -v pad_buf '%*s' "$pad_needed" ''
    buf+="${C_MAGENTA}│${pos_color}${pos_line}${C_RESET}${pad_buf}${C_MAGENTA}│${C_RESET}${CLR_EOL}"$'\n'

    # └─ Bottom border ─┘
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # Scroll computation
    compute_scroll_window "$MENU_COUNT"

    # Scroll indicator: above
    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Menu items
    local -i ri rows_rendered
    local item icon padded_item item_color

    for (( ri = _vis_start; ri < _vis_end; ri++ )); do
        item="${MENU_ITEMS[ri]}"
        icon="${MENU_ICONS[ri]}"

        # Color-code items by type
        case "$ri" in
            0) item_color="$C_CYAN" ;;      # Left
            1) item_color="$C_GREEN" ;;      # Right
            2) item_color="$C_YELLOW" ;;     # Toggle
            3) item_color="$C_WHITE" ;;      # Refresh
            4) item_color="$C_RED" ;;        # Quit
            *) item_color="$C_WHITE" ;;
        esac

        # Show active indicator for current position
        local active_mark=""
        if [[ "$ri" == "0" && "$CURRENT_POSITION" == "left" ]]; then
            active_mark=" ${C_GREEN}●${C_RESET}"
        elif [[ "$ri" == "1" && "$CURRENT_POSITION" == "right" ]]; then
            active_mark=" ${C_GREEN}●${C_RESET}"
        fi

        local display_text="${icon} ${item}${active_mark}"

        if (( ri == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE} ${item} ${C_RESET}${active_mark}${CLR_EOL}"$'\n'
        else
            buf+="    ${item_color}${icon}${C_RESET} ${item}${active_mark}${CLR_EOL}"$'\n'
        fi
    done

    # Fill empty rows
    rows_rendered=$(( _vis_end - _vis_start ))
    for (( ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # Scroll indicator: below
    if (( MENU_COUNT > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${MENU_COUNT}]"
        if (( _vis_end < MENU_COUNT )); then
            buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Status line
    buf+=$'\n'
    if [[ -n "$STATUS_MSG" ]]; then
        buf+=" ${STATUS_COLOR}${STATUS_MSG}${C_RESET}${CLR_EOL}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Help line
    buf+=$'\n'"${C_CYAN} [↑/↓ j/k] Navigate  [Enter] Select  [l] Left  [r] Right  [t] Toggle  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} Config: ${C_WHITE}${SWAYNC_CONFIG}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- TUI Input Handling ---

navigate() {
    local -i dir=$1
    if (( MENU_COUNT == 0 )); then return 0; fi
    SELECTED_ROW=$(( (SELECTED_ROW + dir + MENU_COUNT) % MENU_COUNT ))
    NEEDS_REDRAW=1
}

navigate_page() {
    local -i dir=$1
    if (( MENU_COUNT == 0 )); then return 0; fi
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= MENU_COUNT )); then SELECTED_ROW=$(( MENU_COUNT - 1 )); fi
    NEEDS_REDRAW=1
}

navigate_end() {
    local -i target=$1
    if (( MENU_COUNT == 0 )); then return 0; fi
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( MENU_COUNT - 1 )); fi
    NEEDS_REDRAW=1
}

execute_selection() {
    case "$SELECTED_ROW" in
        0) apply_changes "left" ;;
        1) apply_changes "right" ;;
        2) toggle_position ;;
        3) refresh_status ;;
        4) exit 0 ;;
    esac
    NEEDS_REDRAW=1
}

refresh_status() {
    get_current_position >/dev/null 2>&1 || :
    set_status "OK" "Status refreshed — Position: ${CURRENT_POSITION^}" "cyan"
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then
        return 1
    fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

handle_mouse() {
    local input="$1"
    local -i button x y
    local type zone

    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    # Scroll wheel
    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi

    # Only process press events
    if [[ "$terminator" != "M" ]]; then return 0; fi

    # Click on menu items
    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))
        if (( clicked_idx >= 0 && clicked_idx < MENU_COUNT )); then
            SELECTED_ROW=$clicked_idx
            NEEDS_REDRAW=1
            # Double-purpose: click selects AND executes
            if (( button == 0 )); then
                execute_selection
            fi
        fi
    fi
    return 0
}

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
        else
            # Bare Escape — no action in single-view TUI
            return
        fi
    fi

    # Escape sequences
    case "$key" in
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC')           execute_selection; return ;;
        '[D'|'OD')           ;; # Left arrow — no action needed
        '[5~')               navigate_page -1; return ;;
        '[6~')               navigate_page 1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    # Regular keys
    case "$key" in
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        g)              navigate_end 0 ;;
        G)              navigate_end 1 ;;
        l|L)            apply_changes "left"; NEEDS_REDRAW=1 ;;
        r|R)            apply_changes "right"; NEEDS_REDRAW=1 ;;
        t|T)            toggle_position; NEEDS_REDRAW=1 ;;
        s|S)            refresh_status ;;
        ''|$'\n')       execute_selection ;;
        $'\x7f'|$'\x08') ;; # Backspace — no action
        q|Q|$'\x03')    exit 0 ;;
    esac
}

# --- CLI Functions (Non-TUI) ---

show_status() {
    local current
    current=$(get_current_position)
    printf 'Current position: %s%s%s\n' "${C_GREEN}" "${current^}" "$C_RESET"
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTION]

Options:
  -l, --left      Set position to Left
  -r, --right     Set position to Right
  -t, --toggle    Toggle (flip) position
  -s, --status    Show current position
  -h, --help      Show this help

Running without arguments opens the Interactive TUI.

TUI Controls:
  ↑/↓, j/k      Navigate menu
  Enter, →       Execute selected action
  l              Set Left directly
  r              Set Right directly
  t              Toggle position
  s              Refresh status
  Mouse          Click to select & execute, scroll to navigate
  q, Ctrl+C      Quit
EOF
}

# --- Main Entry Points ---

show_tui() {
    if (( BASH_VERSINFO[0] < 5 )); then log_err "Bash 5.0+ required"; exit 1; fi
    if [[ ! -t 0 ]]; then log_err "TTY required for TUI mode"; exit 1; fi

    TUI_RUNNING=1

    # Read initial position
    get_current_position >/dev/null 2>&1 || CURRENT_POSITION="unknown"

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    set_status "OK" "Ready — Select an action" "cyan"

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done
}

main() {
    check_dependencies

    # If no arguments, show TUI
    if (( $# == 0 )); then
        show_tui
        return
    fi

    # CLI mode — process flags
    case "$1" in
        -l|--left)   apply_changes "left" ;;
        -r|--right)  apply_changes "right" ;;
        -t|--toggle) toggle_position ;;
        -s|--status) show_status ;;
        -h|--help)   show_help ;;
        *)           cli_die "Unknown option: '$1'. Use --help." ;;
    esac
}

main "$@"
