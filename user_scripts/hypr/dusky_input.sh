#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Input - Optimized v5.0
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: Tabbed TUI to modify input.conf.
# Changelog v5.0:
#   - LC_NUMERIC=C (Locale Bomb fix)
#   - Nested block brace-counting (Range Trap fix)
#   - EOF safety (|| break)
#   - stty state preservation
#   - Scrolling viewport with indicators
#   - Pattern escaping for sed
# -----------------------------------------------------------------------------

set -euo pipefail

# CRITICAL FIX: The "Locale Bomb"
# Force standard C locale for numeric operations.
# Prevents awk from outputting commas (0,5) in non-US locales.
export LC_NUMERIC=C

# --- Configuration ---
readonly CONFIG_FILE="${HOME}/.config/hypr/edit_here/source/input.conf"
readonly APP_TITLE="Dusky Input"
readonly APP_VERSION="v5.0"

# UI Layout Constants
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=40
declare -ri ITEM_PADDING=32

# Timeout for reading escape sequences (in seconds)
readonly ESC_READ_TIMEOUT=0.02

# --- Pre-computed Constants ---
declare _H_LINE_BUF
printf -v _H_LINE_BUF '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE=${_H_LINE_BUF// /─}

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
readonly -a TABS=("Keyboard" "Mouse" "Touchpad" "Cursor" "Gestures")
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()

# --- Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    # Restore terminal state (Mouse, Cursor, Colors)
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    
    # Robustly restore original stty settings
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    
    printf '\n'
}

# Escape special characters for sed REPLACEMENT string
escape_sed_replacement() {
    local _s=$1
    local -n _out=$2
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//&/\\&}
    _s=${_s//$'\n'/\\$'\n'}
    _out=$_s
}

# Escape special characters for sed PATTERN (Basic Regex)
escape_sed_pattern() {
    local _s=$1
    local -n _out=$2
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//./\\.}
    _s=${_s//\*/\\*}
    _s=${_s//\[/\\[}
    _s=${_s//^/\\^}
    _s=${_s//\$/\\\$}
    _out=$_s
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Registration ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3

    if (( tab_idx < 0 || tab_idx >= TAB_COUNT )); then
        printf '%s[FATAL]%s Invalid tab index %d for "%s"\n' \
            "$C_RED" "$C_RESET" "$tab_idx" "$label" >&2
        exit 1
    fi

    ITEM_MAP["$label"]=$config
    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    tab_ref+=("$label")
}

# --- DEFINITIONS ---

# Tab 0: Keyboard (Block: 'input')
register 0 "Layout"             "kb_layout|cycle|input|us,uk,de,fr,es|us|"
register 0 "Numlock Default"    "numlock_by_default|bool|input|||"
register 0 "Repeat Rate"        "repeat_rate|int|input|10|100|5"
register 0 "Repeat Delay"       "repeat_delay|int|input|100|1000|50"
register 0 "Resolve Binds Sym"  "resolve_binds_by_sym|bool|input|||"

# Tab 1: Mouse (Block: 'input')
register 1 "Sensitivity"        "sensitivity|float|input|-1.0|1.0|0.1"
register 1 "Accel Profile"      "accel_profile|cycle|input|flat,adaptive,custom|adaptive|"
register 1 "Force No Accel"     "force_no_accel|bool|input|||"
register 1 "Left Handed"        "left_handed|bool|input|||"
register 1 "Follow Mouse"       "follow_mouse|int|input|0|3|1"
register 1 "Mouse Refocus"      "mouse_refocus|bool|input|||"
register 1 "Mouse Nat Scroll"   "natural_scroll|bool|input|||"
register 1 "Scroll Method"      "scroll_method|cycle|input|2fg,edge,on_button_down,no_scroll|2fg|"

# Tab 2: Touchpad (Block: 'touchpad')
register 2 "TP Nat Scroll"      "natural_scroll|bool|touchpad|||"
register 2 "Tap to Click"       "tap-to-click|bool|touchpad|||"
register 2 "Disable While Typing" "disable_while_typing|bool|touchpad|||"
register 2 "Clickfinger Behav"  "clickfinger_behavior|bool|touchpad|||"
register 2 "Drag Lock"          "drag_lock|bool|touchpad|||"

# Tab 3: Cursor (Block: 'cursor')
register 3 "No HW Cursors"      "no_hardware_cursors|int|cursor|0|2|1"
register 3 "Use CPU Buffer"     "use_cpu_buffer|int|cursor|0|2|1"
register 3 "Hide On Key"        "hide_on_key_press|bool|cursor|||"
register 3 "Inactive Timeout"   "inactive_timeout|int|cursor|0|60|5"
register 3 "Warp On Change"     "warp_on_change_workspace|int|cursor|0|2|1"
register 3 "No Break VRR"       "no_break_fs_vrr|int|cursor|0|2|1"
register 3 "Zoom Factor"        "zoom_factor|float|cursor|1.0|5.0|0.1"

# Tab 4: Gestures (Block: 'gestures')
register 4 "Swipe Distance"     "workspace_swipe_distance|int|gestures|100|1000|50"
register 4 "Swipe Cancel Ratio" "workspace_swipe_cancel_ratio|float|gestures|0.0|1.0|0.1"
register 4 "Swipe Invert"       "workspace_swipe_invert|bool|gestures|||"
register 4 "Swipe Create New"   "workspace_swipe_create_new|bool|gestures|||"
register 4 "Swipe Forever"      "workspace_swipe_forever|bool|gestures|||"

# --- DEFAULTS ---
DEFAULTS=(
    # Keyboard
    ["Layout"]="us"
    ["Numlock Default"]="true"
    ["Repeat Rate"]="35"
    ["Repeat Delay"]="250"
    ["Resolve Binds Sym"]="false"
    # Mouse
    ["Sensitivity"]="0"
    ["Accel Profile"]="adaptive"
    ["Force No Accel"]="false"
    ["Left Handed"]="true"
    ["Follow Mouse"]="1"
    ["Mouse Refocus"]="true"
    ["Mouse Nat Scroll"]="false"
    ["Scroll Method"]="2fg"
    # Touchpad
    ["TP Nat Scroll"]="true"
    ["Tap to Click"]="true"
    ["Disable While Typing"]="true"
    ["Clickfinger Behav"]="false"
    ["Drag Lock"]="false"
    # Cursor
    ["No HW Cursors"]="2"
    ["Use CPU Buffer"]="2"
    ["Hide On Key"]="false"
    ["Inactive Timeout"]="0"
    ["Warp On Change"]="0"
    ["No Break VRR"]="2"
    ["Zoom Factor"]="1.0"
    # Gestures
    ["Swipe Distance"]="300"
    ["Swipe Cancel Ratio"]="0.5"
    ["Swipe Invert"]="true"
    ["Swipe Create New"]="true"
    ["Swipe Forever"]="false"
)

# --- Core Logic ---

populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part; do
        [[ -z $key_part ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        key_name=${key_part%%|*}
        if [[ -z ${CONFIG_CACHE["$key_name|"]:-} ]]; then
            CONFIG_CACHE["$key_name|"]=$value_part
        fi
    done < <(awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/#.*/, "", line)

            if (match(line, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(line, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                depth++
                block_stack[depth] = block_str
            }

            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    
    # Dirty check: skip write if value unchanged
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_key safe_block
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_key

    if [[ -n $block ]]; then
        escape_sed_pattern "$block" safe_block
        
        # CRITICAL FIX: The "Nested Block Range Trap"
        # Count braces to find exact block boundaries instead of stopping at first }
        local start_line
        start_line=$(grep -n "^[[:space:]]*${safe_block}[[:space:]]*{" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
        
        if [[ -n $start_line ]]; then
            local end_line_offset
            
            end_line_offset=$(tail -n "+$start_line" "$CONFIG_FILE" | awk '
                BEGIN { depth=0; found=0 }
                {
                    txt = $0
                    sub(/#.*/, "", txt)

                    n_open = gsub(/{/, "&", txt)
                    n_close = gsub(/}/, "&", txt)
                    
                    depth += n_open - n_close
                    
                    if (NR == 1) found=1
                    
                    if (found && depth <= 0) {
                        print NR
                        exit
                    }
                }
            ')
            
            if [[ -n $end_line_offset ]]; then
                local -i real_end_line=$(( start_line + end_line_offset - 1 ))
                
                sed --follow-symlinks -i \
                    "${start_line},${real_end_line}s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)\([^#]*\)|\1${safe_val} |" \
                    "$CONFIG_FILE"
            fi
        fi
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)\([^#]*\)|\1${safe_val} |" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    if [[ -z $block ]]; then
        CONFIG_CACHE["$key|"]=$new_val
    fi
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        val=${CONFIG_CACHE["$key|$block"]:-}
        VALUE_CACHE["$item"]=${val:-unset}
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    [[ $current == "unset" ]] && current=""

    case $type in
        int)
            if [[ ! $current =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1} int_val=$current
            (( int_val += direction * int_step )) || :
            
            if [[ -n $min ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n $max ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        float)
            if [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]]; then current=${min:-0.0}; fi
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn) val = mn
                if (mx != "" && val > mx) val = mx
                printf "%.4g", val
            }')
            ;;
        bool)
            [[ $current == "true" ]] && new_val="false" || new_val="true"
            ;;
        cycle)
            local options_str=$min
            IFS=',' read -r -a opts <<< "$options_str"
            local -i idx=0 found=0 count=${#opts[@]}
            
            for (( i=0; i<count; i++ )); do
                [[ "${opts[i]}" == "$current" ]] && { idx=$i; found=1; break; }
            done
            
            [[ $found -eq 0 ]] && idx=0
            (( idx += direction )) || :
            if (( idx < 0 )); then idx=$(( count - 1 )); fi
            if (( idx >= count )); then idx=0; fi
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block

    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val

    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad
    local -i visible_start visible_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    # Header - Dynamic Centering
    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    # Tab bar
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=$current_col

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || :
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # Items Rendering with scroll support
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#items_ref[@]}

    # Bounds checking & Scroll Calculation
    if (( count == 0 )); then
        SELECTED_ROW=0
        SCROLL_OFFSET=0
    else
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))

        # Auto-scroll to keep selection visible
        if (( SELECTED_ROW < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$SELECTED_ROW
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
        fi

        # Clamp scroll offset
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
        local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
        (( max_scroll < 0 )) && max_scroll=0
        (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    # Top Scroll Indicator
    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Render Visible Items
    for (( i = visible_start; i < visible_end; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-unset}

        case $val in
            true)     display="${C_GREEN}ON${C_RESET}" ;;
            false)    display="${C_RED}OFF${C_RESET}" ;;
            unset)    display="${C_RED}unset${C_RESET}" ;;
            *'$'*)    display="${C_MAGENTA}Dynamic${C_RESET}" ;;
            *)        display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:$ITEM_PADDING}"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    # Pad remaining rows to maintain stable height
    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # Bottom Scroll Indicator
    if (( visible_end < count )); then
        buf+="${C_GREY}    ▼ (more below)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}

    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || :

    if (( SELECTED_ROW < 0 )); then
        SELECTED_ROW=$(( count - 1 ))
    elif (( SELECTED_ROW >= count )); then
        SELECTED_ROW=0
    fi
}

adjust() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"

    (( ${#items_ref[@]} == 0 )) && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}

    (( CURRENT_TAB += dir )) || :

    if (( CURRENT_TAB >= TAB_COUNT )); then
        CURRENT_TAB=0
    elif (( CURRENT_TAB < 0 )); then
        CURRENT_TAB=$(( TAB_COUNT - 1 ))
    fi

    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1

    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end

    if [[ $input =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)([Mm])$ ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        [[ $type != "M" ]] && return 0

        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then
                    set_tab "$i"
                    return 0
                fi
            done
        fi

        # Item click detection (accounting for scroll indicator offset)
        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}
        local -i item_row_start=$(( ITEM_START_ROW + 1 ))

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
                if (( x > ADJUST_THRESHOLD )); then
                    (( button == 0 )) && adjust 1 || adjust -1
                fi
            fi
        fi
    fi
}

# --- Main ---

main() {
    # 1. Config Validation
    [[ ! -f $CONFIG_FILE ]] && { log_err "Config not found: $CONFIG_FILE"; exit 1; }
    [[ ! -r $CONFIG_FILE ]] && { log_err "Config not readable: $CONFIG_FILE"; exit 1; }
    [[ ! -w $CONFIG_FILE ]] && { log_err "Config not writable: $CONFIG_FILE"; exit 1; }

    # 2. Dependency Check
    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    # 3. Initialization
    populate_config_cache

    # 4. Save Terminal State
    if command -v stty &>/dev/null; then
        ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    fi

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key seq char

    # 5. Event Loop
    while true; do
        draw_ui

        # Safety: break on EOF to prevent 100% CPU loops
        IFS= read -rsn1 key || break

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
                seq+="$char"
            done

            case $seq in
                '[Z')          switch_tab -1 ;;
                '[A'|'OA')     navigate -1 ;;
                '[B'|'OB')     navigate 1 ;;
                '[C'|'OC')     adjust 1 ;;
                '[D'|'OD')     adjust -1 ;;
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           adjust 1 ;;
                h|H)           adjust -1 ;;
                $'\t')         switch_tab 1 ;;
                r|R)           reset_defaults ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

main "$@"
