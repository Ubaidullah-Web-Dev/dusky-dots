#!/usr/bin/env bash
# ==============================================================================
# Script: hyprwindow.sh (Window Rule Manager v3.2)
# Purpose: Interactive TUI to generate, copy, and append Hyprland window rules.
#          * Fix: Replaced broken Escape codes with calculated padding.
#          * Fix: Perfect box alignment handling colors correctly.
# ==============================================================================

set -euo pipefail
export LC_NUMERIC=C

# --- Configuration ---
readonly TARGET_FILE="${HOME}/.config/hypr/edit_here/source/window_rules.conf"
readonly APP_TITLE="Window Rule Manager"
readonly APP_VERSION="v3.2"

# Dimensions
declare -ri BOX_WIDTH=100        # Fixed width for the UI box
declare -ri MAX_DISPLAY_ROWS=10  # Rows in the list
declare -ri PREVIEW_HEIGHT=14    # Rows in the preview
declare -ri HEADER_HEIGHT=3      # Border(1) + Title(1) + Sep(1)

# --- ANSI Colors ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m' # Border Color
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[90m'
readonly C_INVERSE=$'\033[7m'
readonly C_COMMENT=$'\033[36m'   # Cyan for Comments
readonly C_DIVIDER=$'\033[1;95m' # Bold Magenta for Dividers

# Term Controls
readonly ALT_SCREEN_ON=$'\033[?1049h'
readonly ALT_SCREEN_OFF=$'\033[?1049l'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly CLR_SCREEN=$'\033[2J'
readonly CLR_EOL=$'\033[K'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State ---
declare -a WINDOW_TITLES=()
declare -a WINDOW_CLASSES=()
declare -a GENERATED_RULES=()
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare -i ITEM_COUNT=0
declare STATUS_MSG=""

# --- Helpers ---

cleanup() {
    # Restore terminal state (Alt screen off, mouse off, cursor on)
    printf '%s%s%s%s' "$MOUSE_OFF" "$ALT_SCREEN_OFF" "$CURSOR_SHOW" "$C_RESET"
    stty echo 2>/dev/null || :
}
trap cleanup EXIT INT TERM

# Strip ANSI codes to calculate visual length
get_visual_length() {
    local s="$1"
    # Remove ANSI escape sequences (colors, cursor movements, etc.)
    s=$(echo "$s" | sed "s/"$'\033'"\[[0-9;]*[a-zA-Z]//g")
    echo "${#s}"
}

# Print a line with proper box borders
# Usage: append_box_line "Content" "BorderColor" "TargetBufferVar"
# Note: Since bash pass-by-reference is tricky with locals, we return the string.
format_box_line() {
    local content="$1"
    local b_color="$2"
    
    local vis_len
    vis_len=$(get_visual_length "$content")
    
    # Calculate padding needed to reach BOX_WIDTH
    # BOX_WIDTH - vis_len - 2 (left/right borders)
    local pad_len=$(( BOX_WIDTH - vis_len - 2 ))
    
    if (( pad_len < 0 )); then 
        # Content too long, truncate it
        # This is rough because we can't easily chop mid-ANSI code
        # We assume content is already mostly sized correctly
        pad_len=0 
    fi
    
    local padding=""
    if (( pad_len > 0 )); then
        printf -v padding "%*s" "$pad_len" ""
    fi
    
    echo "${b_color}│${C_RESET}${content}${padding}${b_color}│${C_RESET}"
}

escape_regex() {
    local s="$1" c
    for c in '\' '.' '[' ']' '*' '^' '$' '(' ')' '+' '?' '{' '}' '|'; do
        s="${s//"$c"/\\$c}"
    done
    printf '%s' "$s"
}

sanitize_name() {
    local input="$1" output="" i char
    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        if [[ $char == [[:alnum:]_-] ]]; then output+="$char"; fi
    done
    printf '%s' "${output:-unnamed}"
}

# --- Core Logic ---

scan_windows() {
    for cmd in jq hyprctl awk wl-copy; do
        if ! command -v "$cmd" &>/dev/null; then 
            printf "%s[ERROR] Missing dependency: %s%s\n" "$C_RED" "$cmd" "$C_RESET"
            exit 1
        fi
    done

    # 1. Gather Monitor Data
    declare -A MON_MAP=()
    while IFS='|' read -r m_id m_w m_h m_scale m_x m_y; do
        [[ -z $m_id ]] && continue
        read -r log_w log_h < <(
            awk -v w="$m_w" -v h="$m_h" -v s="${m_scale:-1}" \
            'BEGIN { s = (s == 0) ? 1 : s; printf "%.0f %.0f\n", w/s, h/s }'
        )
        MON_MAP["$m_id"]="$log_w $log_h $m_x $m_y"
    done < <(hyprctl monitors -j | jq -r '.[] | "\(.id)|\(.width)|\(.height)|\(.scale)|\(.x)|\(.y)"')

    if ((${#MON_MAP[@]} == 0)); then printf "No monitors found.\n"; exit 1; fi

    # 2. Process Clients
    local raw_clients
    raw_clients=$(hyprctl clients -j)

    while IFS=$'\t' read -r title initialClass mon_id w_w w_h w_x w_y w_float w_mapped; do
        [[ -z $initialClass ]] && continue
        if [[ $w_mapped != "true" ]]; then continue; fi
        if [[ ! -v MON_MAP["$mon_id"] ]]; then continue; fi

        read -r m_w m_h m_off_x m_off_y <<< "${MON_MAP["$mon_id"]}"
        [[ ! $m_w =~ ^[1-9][0-9]*$ ]] && continue

        # Calculations
        local rule_block=""
        read -r r_w r_h r_x r_y local_x local_y < <(
            awk -v ww="$w_w" -v wh="$w_h" -v wx="$w_x" -v wy="$w_y" \
                -v mw="$m_w" -v mh="$m_h" -v mx="$m_off_x" -v my="$m_off_y" \
            'BEGIN { 
                lx = wx - mx; ly = wy - my;
                printf "%.4f %.4f %.4f %.4f %.0f %.0f\n", ww/mw, wh/mh, lx/mw, ly/mh, lx, ly
            }'
        )

        local safe_class safe_name
        safe_class=$(escape_regex "$initialClass")
        safe_name=$(sanitize_name "$initialClass")

        # Build Block (Using real newlines)
        rule_block+="${C_DIVIDER}# -----------------------------------------------------${C_RESET}"$'\n'
        rule_block+="# ${title}"$'\n'
        
        rule_block+="${C_GREEN}windowrule {${C_RESET}"$'\n'
        rule_block+="    name = ${safe_name}"$'\n'
        rule_block+="    match:class = ^(${safe_class})$"$'\n'
        rule_block+="    float = on"$'\n'
        rule_block+="    size = (monitor_w * ${r_w}) (monitor_h * ${r_h})"$'\n'
        rule_block+="    ${C_COMMENT}# size = ${w_w} ${w_h}${C_RESET}"$'\n'
        rule_block+="    ${C_COMMENT}# move = (monitor_w * ${r_x}) (monitor_h * ${r_y})${C_RESET}"$'\n'
        rule_block+="    center = on"$'\n'
        
        rule_block+=$'\n'"    ${C_COMMENT}# --- Visuals & Effects ---${C_RESET}"$'\n'
        rule_block+="    ${C_COMMENT}# opacity = 0.9 0.9${C_RESET}"$'\n'
        rule_block+="    ${C_COMMENT}# animation = popin${C_RESET}"$'\n'
        rule_block+="    ${C_COMMENT}# border_color = rgb(ff0000)${C_RESET}"$'\n'
        
        rule_block+="${C_GREEN}}${C_RESET}"$'\n'
        rule_block+="${C_YELLOW}# [One-Liner] windowrule = match:class ^(${safe_class})$, float on, center on, size (monitor_w * ${r_w}) (monitor_h * ${r_h})${C_RESET}"$'\n'

        WINDOW_TITLES+=("${title:0:60}") # Cap title length
        WINDOW_CLASSES+=("$initialClass")
        GENERATED_RULES+=("$rule_block")
        
    done < <(echo "$raw_clients" | jq -r '.[] | [.title, .initialClass, .monitor, .size[0], .size[1], .at[0], .at[1], .floating, .mapped] | @tsv')

    ITEM_COUNT=${#WINDOW_TITLES[@]}
    if (( ITEM_COUNT == 0 )); then printf "No visible windows found.\n"; exit 0; fi
}

# --- TUI Engine ---

draw_ui() {
    local buf="" i line
    local -i visible_start visible_end

    # --- TOP BORDER ---
    buf+="${CURSOR_HOME}${C_MAGENTA}┌"
    for ((i=0; i<BOX_WIDTH-2; i++)); do buf+="─"; done
    buf+="┐${C_RESET}"$'\n'

    # --- HEADER ---
    local title_str=" ${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_RESET} "
    buf+=$(format_box_line "$title_str" "$C_MAGENTA")
    buf+=$'\n'
    
    # --- SEPARATOR ---
    buf+="${C_MAGENTA}├"
    for ((i=0; i<BOX_WIDTH-2; i++)); do buf+="─"; done
    buf+="┤${C_RESET}"$'\n'

    # --- SCROLL LOGIC ---
    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > ITEM_COUNT )) && visible_end=$ITEM_COUNT

    # --- LIST ITEMS ---
    for (( i = visible_start; i < visible_end; i++ )); do
        local title="${WINDOW_TITLES[i]}"
        local class="${WINDOW_CLASSES[i]}"
        local line_content
        
        # Safe Truncate for display logic (Text - Borders - Separator - Class - Arrow)
        local avail=$(( BOX_WIDTH - 15 - ${#class} ))
        if (( ${#title} > avail )); then title="${title:0:$avail}…"; fi
        
        if (( i == SELECTED_ROW )); then
            line_content=" ${C_CYAN}➤ ${C_INVERSE} ${class} ${C_RESET}${C_GREY} :: ${C_WHITE}${title}${C_RESET}"
        else
            line_content="    ${C_CYAN}${class} ${C_GREY}:: ${C_WHITE}${title}${C_RESET}"
        fi
        
        buf+=$(format_box_line "$line_content" "$C_MAGENTA")
        buf+=$'\n'
    done

    # --- EMPTY ROWS ---
    for (( i = visible_end; i < visible_start + MAX_DISPLAY_ROWS; i++ )); do
        buf+=$(format_box_line " " "$C_MAGENTA")
        buf+=$'\n'
    done

    # --- SEPARATOR ---
    buf+="${C_MAGENTA}├"
    for ((i=0; i<BOX_WIDTH-2; i++)); do buf+="─"; done
    buf+="┤${C_RESET}"$'\n'

    # --- PREVIEW HEADER ---
    buf+=$(format_box_line " ${C_WHITE}PREVIEW:${C_RESET}" "$C_MAGENTA")
    buf+=$'\n'
    
    # --- PREVIEW CONTENT ---
    local preview_content="${GENERATED_RULES[$SELECTED_ROW]}"
    local -i line_count=0
    
    while IFS= read -r line; do
        (( ++line_count )) || :
        
        if (( line_count <= PREVIEW_HEIGHT )); then
            # Add left margin
            local display_line=" ${line}"
            # Soft truncate to prevent wrap break
            local vis_len=$(get_visual_length "$display_line")
            if (( vis_len > BOX_WIDTH - 2 )); then
               # Truncation logic is hard with ansi, assume standard width is fine
               : 
            fi
            
            buf+=$(format_box_line "$display_line" "$C_MAGENTA")
            buf+=$'\n'
        fi
    done <<< "$preview_content"

    # --- EMPTY PREVIEW ROWS ---
    for (( i = line_count; i < PREVIEW_HEIGHT; i++ )); do
        buf+=$(format_box_line " " "$C_MAGENTA")
        buf+=$'\n'
    done

    # --- BOTTOM BORDER ---
    buf+="${C_MAGENTA}└"
    for ((i=0; i<BOX_WIDTH-2; i++)); do buf+="─"; done
    buf+="┘${C_RESET}"$'\n'

    # --- FOOTER ---
    buf+="${C_CYAN} [↑/↓] Select  [Enter] Append  [c] Copy  [q] Quit${C_RESET}"$'\n'
    if [[ -n "$STATUS_MSG" ]]; then
        buf+="${C_YELLOW} ${STATUS_MSG}${C_RESET}${CLR_EOL}"$'\n'
    else
        buf+="${C_CYAN} Target: ${C_WHITE}${TARGET_FILE}${C_RESET}${CLR_EOL}"$'\n'
    fi

    printf '%s' "$buf"
}

get_clean_rule() {
    local rule_ansi="${GENERATED_RULES[$SELECTED_ROW]}"
    # Strip ANSI codes for file writing/copying
    echo -e "$rule_ansi" | sed "s/"$'\033'"\[[0-9;]*[a-zA-Z]//g"
}

copy_clipboard() {
    local rule_clean
    rule_clean=$(get_clean_rule)
    
    if echo "$rule_clean" | wl-copy; then
        STATUS_MSG="[SUCCESS] Copied to clipboard!"
    else
        STATUS_MSG="[ERROR] Failed to copy (wl-copy missing?)"
    fi
}

append_selection() {
    local rule_clean
    rule_clean=$(get_clean_rule)

    if [[ ! -f "$TARGET_FILE" ]]; then
        STATUS_MSG="[ERROR] Target file not found!"
        return
    fi

    # Ensure newline at EOF before appending
    if [[ -s "$TARGET_FILE" ]] && [[ "$(tail -c 1 "$TARGET_FILE" | wc -l)" -eq 0 ]]; then
        printf "\n" >> "$TARGET_FILE"
    fi

    echo "$rule_clean" >> "$TARGET_FILE"
    STATUS_MSG="[SUCCESS] Rule appended to config!"
}

# --- Main ---
main() {
    scan_windows
    
    # Enable Alternate Screen Buffer (Clears screen, restores on exit)
    # Enable Mouse Tracking
    stty -echo
    printf '%s%s%s%s' "$ALT_SCREEN_ON" "$MOUSE_ON" "$CURSOR_HIDE" "$CURSOR_HOME"
    
    local key seq char btn x y

    while true; do
        draw_ui
        IFS= read -rsn1 key || break

        # Clear status message on interaction
        if [[ -n "$STATUS_MSG" && "$key" != "" ]]; then STATUS_MSG=""; fi

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.02 char; do seq+="$char"; done
            case $seq in
                '[A'|'OA') (( SELECTED_ROW-- )) || : ;;
                '[B'|'OB') (( SELECTED_ROW++ )) || : ;;
                '['*'<'*)
                   # Mouse Handling SGR 1006
                   if [[ $seq =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)([Mm]) ]]; then
                       btn=${BASH_REMATCH[1]}
                       x=${BASH_REMATCH[2]}
                       y=${BASH_REMATCH[3]}
                       
                       # Scroll Wheel
                       if (( btn == 64 )); then (( SELECTED_ROW-- )) || :; fi
                       if (( btn == 65 )); then (( SELECTED_ROW++ )) || :; fi
                       
                       # Left Click (btn 0)
                       if (( btn == 0 )); then
                           # Calculate clicked row relative to list
                           local list_start_y=$(( HEADER_HEIGHT + 1 ))
                           local list_end_y=$(( list_start_y + MAX_DISPLAY_ROWS - 1 ))
                           
                           if (( y >= list_start_y && y <= list_end_y )); then
                               local clicked_idx=$(( y - list_start_y + SCROLL_OFFSET ))
                               if (( clicked_idx >= 0 && clicked_idx < ITEM_COUNT )); then
                                   SELECTED_ROW=$clicked_idx
                               fi
                           fi
                       fi
                   fi ;;
            esac
        else
            case $key in
                k|K) (( SELECTED_ROW-- )) || : ;;
                j|J) (( SELECTED_ROW++ )) || : ;;
                q|Q) break ;;
                c|C) copy_clipboard ;;
                "")  append_selection ;;
            esac
        fi

        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= ITEM_COUNT )) && SELECTED_ROW=$(( ITEM_COUNT - 1 ))

        if (( SELECTED_ROW < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$SELECTED_ROW
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
        fi
    done
}

main
