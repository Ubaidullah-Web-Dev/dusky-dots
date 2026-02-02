#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Appearances
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: Tabbed TUI to modify hyprland appearance.conf.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
readonly CONFIG_FILE="${HOME}/.config/hypr/edit_here/source/appearance.conf"

# UI Layout Constants
declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=64
declare -ri ITEM_START_ROW=5
declare -ri ADJUST_THRESHOLD=30

# --- Pre-computed Constants ---
# Optimization: Generate horizontal line once at startup to avoid subshells in render loop
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
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
readonly -a TABS=("Layout" "Decoration" "Blur" "Shadow" "Snap")
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()

# --- Data Structures ---
declare -A ITEM_MAP
declare -A VALUE_CACHE
declare -A CONFIG_CACHE
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()

# --- Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
}

# Optimization: Use Nameref to pass value back without spawning subshell
escape_sed_replacement() {
    local _s=$1
    local -n _out=$2
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}
    _s=${_s//&/\\&}
    _s=${_s//$'\n'/\\$'\n'}
    _out=$_s
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Registration ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3

    # Safety: Prevent crash if index is out of bounds
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

# Tab 0: Layout & General
register 0 "Gaps In"            "gaps_in|int||0|100|1"
register 0 "Gaps Out"           "gaps_out|int||0|100|1"
register 0 "Gaps Workspaces"    "gaps_workspaces|int|general|0|100|1"
register 0 "Border Size"        "border_size|int||0|10|1"
register 0 "Resize on Border"   "resize_on_border|bool|general|||"
register 0 "Allow Tearing"      "allow_tearing|bool|general|||"

# Tab 1: Decoration
register 1 "Rounding"           "rounding|int||0|30|1"
register 1 "Rounding Power"     "rounding_power|float||0.0|10.0|0.1"
register 1 "Active Opacity"     "active_opacity|float||0.1|1.0|0.05"
register 1 "Inactive Opacity"   "inactive_opacity|float||0.1|1.0|0.05"
register 1 "Fullscreen Opacity" "fullscreen_opacity|float||0.1|1.0|0.05"
register 1 "Dim Inactive"       "dim_inactive|bool||||"
register 1 "Dim Strength"       "dim_strength|float||0.0|1.0|0.05"
register 1 "Dim Special"        "dim_special|float||0.0|1.0|0.05"

# Tab 2: Blur
register 2 "Blur Enabled"       "enabled|bool|blur|||"
register 2 "Blur Size"          "size|int|blur|1|20|1"
register 2 "Blur Passes"        "passes|int|blur|1|10|1"
register 2 "Blur Xray"          "xray|bool|blur|||"
register 2 "Blur Noise"         "noise|float|blur|0.0|1.0|0.01"
register 2 "Blur Contrast"      "contrast|float|blur|0.0|2.0|0.05"
register 2 "Blur Brightness"    "brightness|float|blur|0.0|2.0|0.05"
register 2 "Blur Popups"        "popups|bool|blur|||"
register 2 "Blur Vibrancy"      "vibrancy|float|blur|0.0|1.0|0.05"

# Tab 3: Shadow
register 3 "Shadow Enabled"     "enabled|bool|shadow|||"
register 3 "Shadow Range"       "range|int|shadow|0|100|1"
register 3 "Shadow Power"       "render_power|int|shadow|1|4|1"
register 3 "Shadow Sharp"       "sharp|bool|shadow|||"
register 3 "Shadow Scale"       "scale|float|shadow|0.0|1.1|0.05"
register 3 "Shadow Ignore Win"  "ignore_window|bool|shadow|||"
# FIX: Use single quotes to prevent variable expansion of $primary
register 3 "Shadow Color"       'color|cycle|shadow|rgba(1a1a1aee),$primary||'

# Tab 4: Snap
register 4 "Snap Enabled"       "enabled|bool|snap|||"
register 4 "Snap Window Gap"    "window_gap|int|snap|0|50|1"
register 4 "Snap Monitor Gap"   "monitor_gap|int|snap|0|50|1"
register 4 "Snap Border Overlap" "border_overlap|bool|snap|||"

# --- DEFAULTS ---
declare -A DEFAULTS=(
    ["Gaps In"]=6
    ["Gaps Out"]=12
    ["Gaps Workspaces"]=0
    ["Border Size"]=2
    ["Resize on Border"]=false
    ["Allow Tearing"]=true
    ["Rounding"]=6
    ["Rounding Power"]=6.0
    ["Active Opacity"]=1.0
    ["Inactive Opacity"]=1.0
    ["Fullscreen Opacity"]=1.0
    ["Dim Inactive"]=true
    ["Dim Strength"]=0.2
    ["Dim Special"]=0.8
    ["Blur Enabled"]=false
    ["Blur Size"]=4
    ["Blur Passes"]=2
    ["Blur Xray"]=false
    ["Blur Noise"]=0.0117
    ["Blur Contrast"]=0.8916
    ["Blur Brightness"]=0.8172
    ["Blur Popups"]=false
    ["Blur Vibrancy"]=0.1696
    ["Shadow Enabled"]=false
    ["Shadow Range"]=35
    ["Shadow Power"]=2
    ["Shadow Sharp"]=false
    ["Shadow Scale"]=1.0
    ["Shadow Ignore Win"]=true
    ["Shadow Color"]='rgba(1a1a1aee)'
    ["Snap Enabled"]=false
    ["Snap Window Gap"]=10
    ["Snap Monitor Gap"]=10
    ["Snap Border Overlap"]=false
)

# --- Core Logic ---

populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part; do
        [[ -z $key_part ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        # Fallback for "First Match Anywhere"
        key_name=${key_part%%|*}
        # FIX: Use 'if' instead of '&&' to prevent set -e failure
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
    
    # --- OPTIMIZATION: Dirty Check ---
    # Check if the value in memory matches the new value.
    # If they are identical, we skip the disk write (sed) entirely.
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    if [[ "$current_val" == "$new_val" ]]; then
        return 0
    fi
    # ---------------------------------

    local safe_val
    local -n safe_val_ref=safe_val  # Use nameref for your existing helper
    escape_sed_replacement "$new_val" safe_val_ref

    if [[ -n $block ]]; then
        sed --follow-symlinks -i \
            "/^[[:space:]]*${block}[[:space:]]*{/,/^[[:space:]]*}/ {
                s|^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[^#[:space:]]*|\1${safe_val}|
            }" "$CONFIG_FILE"
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[^#[:space:]]*|\1${safe_val}|" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    
    # FIX: Use 'if' to avoid return code 1 if block is set
    if [[ -z $block ]]; then
        CONFIG_CACHE["$key|"]=$new_val
    fi
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        # UPGRADE: Removed 'color_toggle' special check. Loading is now standard.
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
            # FIX: Use 'if' for robust set -e compliance
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
        # UPGRADE: Replaced hardcoded 'action' with data-driven 'cycle' logic
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

    # UPGRADE: Removed 'color_toggle' special check.
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
    local buf="" pad_buf="" padded_item=""
    local -i i current_col=3

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    # Header - Dynamic Centering (printf -v to avoid subshell)
    local raw_title="Dusky Appearances v7.2.3"
    local -i title_len=${#raw_title}
    local -i left_pad=$(( (BOX_INNER_WIDTH - title_len) / 2 ))
    local -i right_pad=$(( BOX_INNER_WIDTH - title_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}Dusky Appearances ${C_CYAN}v7.2.3${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    # Tab bar
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        local -i len=${#name}
        local -i zone_start=$current_col

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || :
    done

    local -i pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # Items
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    local item val display

    if (( count == 0 )); then
        SELECTED_ROW=0
    elif (( SELECTED_ROW >= count )); then
        SELECTED_ROW=$(( count - 1 ))
    elif (( SELECTED_ROW < 0 )); then
        SELECTED_ROW=0
    fi

    for (( i = 0; i < count; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-unset}

        case $val in
            true)         display="${C_GREEN}ON${C_RESET}" ;;
            false)        display="${C_RED}OFF${C_RESET}" ;;
            unset)        display="${C_RED}unset${C_RESET}" ;;
            # Updated display logic for consistency, though 'Dynamic' was a nice touch for action.
            # We preserve specific display logic for variables if needed, or let them fall through.
            *'$primary'*) display="${C_MAGENTA}Dynamic${C_RESET}" ;;
            *)            display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item '%-22s' "$item"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    for (( i = count; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

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
    load_tab_values
}

set_tab() {
    local -i idx=$1

    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
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

        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}

        if (( y >= ITEM_START_ROW && y < ITEM_START_ROW + count )); then
            SELECTED_ROW=$(( y - ITEM_START_ROW ))
            if (( x > ADJUST_THRESHOLD )); then
                (( button == 0 )) && adjust 1 || adjust -1
            fi
        fi
    fi
}

# --- Main ---

main() {
    [[ ! -f $CONFIG_FILE ]] && { log_err "Config not found: $CONFIG_FILE"; exit 1; }
    [[ ! -r $CONFIG_FILE ]] && { log_err "Config not readable: $CONFIG_FILE"; exit 1; }
    [[ ! -w $CONFIG_FILE ]] && { log_err "Config not writable: $CONFIG_FILE"; exit 1; }

    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    populate_config_cache
    printf '%s%s' "$MOUSE_ON" "$CURSOR_HIDE"
    load_tab_values
    clear

    local key seq char

    while true; do
        draw_ui

        IFS= read -rsn1 key || continue

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.02 char; do
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

main
