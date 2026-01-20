#!/usr/bin/env bash
# ==============================================================================
# Description: Advanced TUI for Hyprland Keybinds.
#              - Single-Line "Power Edit" Mode.
#              - Auto-correction of bind/bindd based on comma count.
#              - Stacked Conflict Resolution (Edit chains).
#              - Auto-Reloads Hyprland on success.
# Author:      - Dusky 
# Version      - v17.0
# Reference:   https://wiki.hypr.land/Configuring/Binds/
# ==============================================================================

set -euo pipefail
shopt -s extglob  # Required for *([[:space:]]) extended glob patterns

# --- ANSI Colors ---
readonly BLUE=$'\033[0;34m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly RED=$'\033[0;31m'
readonly CYAN=$'\033[0;36m'
readonly PURPLE=$'\033[0;35m'
readonly BOLD=$'\033[1m'
readonly RESET=$'\033[0m'
readonly BRIGHT_WHITE=$'\033[0;97m' 

# --- Paths ---
readonly SOURCE_CONF="${HOME}/.config/hypr/source/keybinds.conf"
readonly CUSTOM_CONF="${HOME}/.config/hypr/edit_here/source/keybinds.conf"

# --- Globals ---
TEMP_FILE=""
PENDING_CONTENT="" # Stores stashed edits during conflict resolution

# ==============================================================================
# Helpers
# ==============================================================================

cleanup() {
    # Added '|| true' to prevent exit code 1 when TEMP_FILE is already gone/empty
    [[ -n "${TEMP_FILE:-}" && -f "$TEMP_FILE" ]] && rm -f -- "$TEMP_FILE" || true
}
trap cleanup EXIT INT TERM HUP

die() {
    printf '%s[ERR]%s %s\n' "${RED}" "${RESET}" "$1" >&2
    exit 1
}

_trim() {
    local -n _ref="$1"
    _ref="$2"
    _ref="${_ref#"${_ref%%[![:space:]]*}"}"
    _ref="${_ref%"${_ref##*[![:space:]]}"}"
}

# --- Conflict Detection ---
check_conflict() {
    local check_mods_raw="$1"
    local check_key_raw="$2"
    local file="$3"

    local check_mods check_key
    _trim check_mods "$check_mods_raw"
    _trim check_key "$check_key_raw"
    check_mods="${check_mods,,}"
    check_key="${check_key,,}"

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *([[:space:]])"#"* ]] && continue
        [[ "$line" != *([[:space:]])bind* ]] && continue

        local after_equals="${line#*=}"
        local part0 part1

        IFS=',' read -r part0 part1 _ <<< "$after_equals"

        local line_mods line_key
        _trim line_mods "$part0"
        _trim line_key "$part1"
        line_mods="${line_mods,,}"
        line_key="${line_key,,}"

        if [[ "$line_mods" == "$check_mods" && "$line_key" == "$check_key" ]]; then
            printf '%s' "$line"
            return 0
        fi
    done < "$file"
    return 1
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    command -v fzf &>/dev/null || die "'fzf' is required."
    [[ -f "$SOURCE_CONF" ]] || die "Source config missing: $SOURCE_CONF"
    
    local custom_dir="${CUSTOM_CONF%/*}"
    mkdir -p "$custom_dir" || die "Failed to create directory: $custom_dir"
    [[ -f "$CUSTOM_CONF" ]] || : > "$CUSTOM_CONF" || die "Cannot create file: $CUSTOM_CONF"

    # 1. Select Original Bind
    local selected_line
    if ! selected_line=$(grep -E '^\s*bind[a-z]*\s*=' "$SOURCE_CONF" | \
        fzf --header="SELECT BIND TO EDIT" --info=inline --layout=reverse --border --prompt="Select > "); then
        exit 0
    fi
    [[ -z "$selected_line" ]] && exit 0

    # 2. Extract Original Mods/Key
    local orig_content="${selected_line#*=}"
    local orig_part0 orig_part1
    IFS=',' read -r orig_part0 orig_part1 _ <<< "$orig_content"
    
    local orig_mods orig_key
    _trim orig_mods "$orig_part0"
    _trim orig_key "$orig_part1"

    # 3. Edit Loop
    local current_input="$selected_line"
    local conflict_unbind_cmd=""
    local user_line=""

    while true; do
        clear
        printf '%s┌──────────────────────────────────────────────┐%s\n' "$BLUE" "$RESET"
        printf '%s│ %sEDITING KEYBIND (One-Line)%s                   │%s\n' "$BLUE" "$RESET"
        printf '%s└──────────────────────────────────────────────┘%s\n' "$BLUE" "$RESET"
        printf ' %sOriginal:%s %s\n\n' "$YELLOW" "$RESET" "$selected_line"
        
        # Display Pending Stack info if deep in recursion
        if [[ -n "$PENDING_CONTENT" ]]; then
             printf '%s[INFO]%s You have pending edits that will be saved after this.\n\n' "$PURPLE" "$RESET"
        fi
        
        printf '%sINSTRUCTIONS:%s\n' "$CYAN" "$RESET"
        printf ' - Edit the line below directly. Keep the commas!\n'
        printf ' - Default Format: %sbindd = MODS, KEY, DESC, DISPATCHER, ARG%s\n' "$GREEN" "$RESET"
        
        printf '\n%sFLAGS REFERENCE (Append to bind, e.g. binddl, binddel):%s\n' "$PURPLE" "$RESET"
        printf '  %sd%s  has description  %s(Easier for discerning what the keybind does)%s\n' "$BOLD" "$RESET" "$BRIGHT_WHITE" "$RESET"
        printf '  %sl%s  locked           %s(Works over lockscreen)%s\n' "$BOLD" "$RESET" "$BRIGHT_WHITE" "$RESET"
        printf '  %se%s  repeat           %s(Repeats when held)%s\n' "$BOLD" "$RESET" "$BRIGHT_WHITE" "$RESET"
        printf '  %so%s  long press       %s(Triggers on hold)%s\n' "$BOLD" "$RESET" "$BRIGHT_WHITE" "$RESET"
        printf '  %sm%s  mouse            %s(For mouse clicks)%s\n\n' "$BOLD" "$RESET" "$BRIGHT_WHITE" "$RESET"

        # --- The Power Edit Prompt ---
        if ! IFS= read -e -r -p "${PURPLE}> ${RESET}" -i "$current_input" user_line; then
            printf '\n%s[INFO]%s Edit cancelled.\n' "$YELLOW" "$RESET"
            exit 0
        fi

        if [[ -z "$user_line" ]]; then
            printf '\n%s[WARN]%s Input cannot be empty. Press Enter to continue...\n' "$YELLOW" "$RESET"
            read -r
            current_input="$selected_line"
            continue
        fi

        # 4. Analyze User Input
        local type="${user_line%%=*}"
        _trim type "$type"
        
        local content="${user_line#*=}"
        local -a parts
        # Appended a space to content so read counts empty trailing args (e.g. 'killactive,')
        IFS=',' read -ra parts <<< "$content "
        local part_count="${#parts[@]}"

        local new_mods new_key
        _trim new_mods "${parts[0]:-}"
        _trim new_key "${parts[1]:-}"

        # --- Smart Type Correction ---
        local base_keyword="bind"
        local flags="${type#bind}"
        local fixed_type="$type"
        local type_was_corrected=false
        
        if (( part_count >= 5 )); then
            if [[ "$flags" != *d* ]]; then
                fixed_type="${base_keyword}${flags}d"
                type_was_corrected=true
            fi
        elif (( part_count == 4 )); then
            if [[ "$flags" == *d* && "$type" != "bindm" ]]; then
                flags="${flags//d/}"
                fixed_type="${base_keyword}${flags}"
                type_was_corrected=true
            fi
        fi

        if [[ "$type_was_corrected" == true ]]; then
            printf '\n%s[AUTO-FIX]%s Bind type corrected: "%s" → "%s"\n' "$CYAN" "$RESET" "$type" "$fixed_type"
            current_input="${fixed_type} = ${content}"
            user_line="${fixed_type} = ${content}"
            printf '           Press Enter to continue with the corrected line...\n'
            read -r
        fi

        # 5. Conflict Check
        printf '\n%sChecking for conflicts...%s ' "$CYAN" "$RESET"
        local conflict_line=""
        local conflict_source=""
        
        if [[ "${new_mods,,}" != "${orig_mods,,}" || "${new_key,,}" != "${orig_key,,}" ]]; then
            if conflict_line="$(check_conflict "$new_mods" "$new_key" "$CUSTOM_CONF")"; then
                conflict_source="CUSTOM"
            elif conflict_line="$(check_conflict "$new_mods" "$new_key" "$SOURCE_CONF")"; then
                conflict_source="SOURCE"
            fi
        fi

        if [[ -n "$conflict_line" ]]; then
            printf '%sFOUND!%s\n' "$RED" "$RESET"
            printf '  [%s] %s\n' "$conflict_source" "$conflict_line"
            printf '\n%sOPTIONS:%s\n' "$BOLD" "$RESET"
            printf '  %s[y]%s Overwrite conflict (Unbind it)\n' "$RED" "$RESET"
            printf '  %s[e]%s Edit the conflicting line instead (Saves current edit to stack)\n' "$YELLOW" "$RESET"
            printf '  %s[n]%s Edit my line again\n' "$GREEN" "$RESET"
            
            local choice
            read -r -p "Select > " choice
            
            if [[ "${choice,,}" == y* ]]; then
                conflict_unbind_cmd="unbind = ${new_mods}, ${new_key}"
                break
                
            elif [[ "${choice,,}" == e* ]]; then
                # --- STACKED EDIT LOGIC ---
                local p_timestamp
                printf -v p_timestamp '%(%Y-%m-%d %H:%M)T' -1
                
                local current_step_block
                current_step_block=$(
                    printf '\n# [%s] Stacked Edit (Saved from conflict)\n' "$p_timestamp"
                    printf '# Original: %s\n' "$selected_line"
                    printf 'unbind = %s, %s\n' "$orig_mods" "$orig_key"
                    printf '%s\n' "$user_line"
                )
                
                if [[ -z "$PENDING_CONTENT" ]]; then
                    PENDING_CONTENT="$current_step_block"
                else
                    PENDING_CONTENT="${current_step_block}"$'\n'"${PENDING_CONTENT}"
                fi

                selected_line="$conflict_line"
                current_input="$conflict_line"
                
                local c_content="${selected_line#*=}"
                local c_part0 c_part1
                IFS=',' read -r c_part0 c_part1 _ <<< "$c_content"
                _trim orig_mods "$c_part0"
                _trim orig_key "$c_part1"
                
                continue
                
            else
                current_input="$user_line"
                continue
            fi
        else
            printf '%sOK%s\n' "$GREEN" "$RESET"
            break
        fi
    done

    # 6. Final Write (Atomic)
    local timestamp
    printf -v timestamp '%(%Y-%m-%d %H:%M)T' -1

    TEMP_FILE="$(mktemp "${CUSTOM_CONF}.XXXXXX")" || die "Failed to create temp file."
    
    {
        [[ -s "$CUSTOM_CONF" ]] && cat -- "$CUSTOM_CONF"
        
        printf '\n# [%s] Edit\n' "$timestamp"
        printf '# Original: %s\n' "$selected_line"
        printf 'unbind = %s, %s\n' "$orig_mods" "$orig_key"
        [[ -n "$conflict_unbind_cmd" ]] && printf '# Resolving Conflict:\n%s\n' "$conflict_unbind_cmd"
        printf '%s\n' "$user_line"

        if [[ -n "${PENDING_CONTENT:-}" ]]; then
            printf '%s\n' "$PENDING_CONTENT"
        fi

    } > "$TEMP_FILE" || die "Failed to write to temp file."

    mv -f -- "$TEMP_FILE" "$CUSTOM_CONF" || die "Failed to finalize config file."
    TEMP_FILE=""

    printf '\n%s[SUCCESS]%s Saved to %s\n' "$GREEN" "$RESET" "$CUSTOM_CONF"
    if [[ -n "$PENDING_CONTENT" ]]; then
        printf '%s[NOTE]%s Stacked edits were also applied.\n' "$PURPLE" "$RESET"
    fi

    # 7. Auto-Reload
    if command -v hyprctl &>/dev/null; then
        printf '%sReloading Hyprland...%s ' "$BLUE" "$RESET"
        if hyprctl reload >/dev/null; then
             printf '%sDONE%s\n' "$GREEN" "$RESET"
        else
             printf '%sFAILED%s\n' "$RED" "$RESET"
        fi
    else
         printf 'Run %shyprctl reload%s to apply.\n' "$BOLD" "$RESET"
    fi
}

main "$@"
