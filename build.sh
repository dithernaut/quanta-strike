#!/bin/bash

# Interactive Font Generator
# Processes font families with metadata patcher and optionally generates nerd fonts

set -e  # Exit on any error

# Colors for output. Real escape characters ($'...'), not backslash sequences, so
# they can be dropped into a printf format as-is — the progress bar composes its
# line with printf rather than echo -e.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m' # No Color

# Run from the repo root regardless of where the user invoked us, so the
# relative paths below resolve. Pipeline scripts live in scripts/.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# Default directories
SRC_DIR="./src"
BUILD_DIR="./build"
VERSION_FILE="./VERSION"
TTF_DIR="$BUILD_DIR/ttf"
TTF_GROUP_DIR="$TTF_DIR/quanta-strike"

# Metadata defaults. When this file exists the build reads names/license/URLs
# from it and skips the questions; remove it to get the interactive prompts.
DEFAULTS_FILE="$SCRIPTS_DIR/default-metadata.json"

# The licence text. OFL requires it to be distributed WITH the fonts, so it gets
# copied into every output folder that holds fonts.
LICENSE_FILE="./OFL.txt"

# Staged sources. scripts/png-to-ttf.py builds each strike's TTF in here, mirroring the
# src/<family>/<style>/ layout the metadata patcher expects, so that src/ only
# ever holds the real sources (PNG + JSON) and never a build artifact.
# Lives under build/ — wiped at the start of every run, and already gitignored.
STAGE_DIR="$BUILD_DIR/tmp/src"

# Metadata patcher flags, as an array — spliced into the patcher's argument list
# verbatim, so values with spaces (the licence text) survive intact.
METADATA_OPTS=()

# The build always emits TWO variants per strike: a monospace one (PFM type
# always "monospace") and a proportional one. PROP_TYPE is the PFM family type
# for the proportional variant — "sans" or "serif". Set by get_metadata_options.
PROP_TYPE="sans"

# Proportional inter-glyph gap: the proportional advance is (ink-width + gap) ×
# 128. A pixel count, or "auto" (scale with strike size N: 1px N<11, 2px 11..18,
# 3px N>18). EMPTY = "let each strike decide" — png-to-ttf then reads the strike
# JSON's `spacing` key, falling back to "auto". Precedence: --spacing V (forces
# every strike, skips the prompt) > a "spacing" key in scripts/default-metadata.json >
# the per-strike JSON `spacing` key > "auto". Empty is the default so the JSON
# stays in control; a build-level value here forces all strikes. PROP_GAP_SET
# records whether --spacing already fixed it.
PROP_GAP=""
PROP_GAP_SET=false

# Non-interactive mode (--defaults / -y): every prompt takes its default answer
# instead of asking. NB "default" is not always "yes" — the version default is
# "keep", Nerd Fonts are OPT-IN (default no) — which is why this isn't called
# --yes. Prompts still print, with the answer that was assumed, so the log shows
# exactly what was chosen.
NON_INTERACTIVE=false

# Nerd Fonts are opt-in (they're the slow step, and only useful for the mono
# variant). --nerd-fonts / --nerd forces them on and skips the prompt; otherwise
# the prompt defaults to no, so a plain --defaults build skips them.
NERD_FORCED=false

# Console PSF fonts (Linux/Raspberry Pi fbcon): OPT-IN, like Nerd Fonts. The main
# release zip skips them. Clones build locally with --psf or the prompt.
# Default allowlist is console-charset.json (tracked). Local variants like
# console-charset-hr.json are gitignored. --no-psf forces a skip.
DEFAULT_CHARSET_FILE="./console-charset.json"
PSF_DIR="$BUILD_DIR/psf/quanta-strike"
PSF_SKIP=false
PSF_FORCED=false        # --psf / --psf-fonts
PSF_CHARSET=""          # resolved path; empty until choose_psf_charset runs
PSF_CHARSET_SET=false   # true when --charset already pinned it
PSF_SCALE=1             # integer nearest-neighbor upscale for PSF only
PSF_SCALE_SET=false     # true when --psf-scale already pinned it

# The staging dir ($BUILD_DIR/tmp) holds png-to-ttf's intermediate TTFs that the
# metadata patcher reads; nothing needs it once the build finishes, so it's
# removed at the end. --keep-tmp leaves it in place for inspecting a bad build.
KEEP_TMP=false

# ─── Output mode ─────────────────────────────────────────────────────────────
# Quiet (the default): every sub-command's chatter is captured to a log and
# replaced by a single animated line — braille spinner, progress bar, and the
# strike currently being worked on. Only phase headers, warnings, errors and the
# final summary are printed for real; a step that FAILS dumps its captured
# output, so nothing is lost when it matters.
# --verbose restores the old firehose, running each step inline.
# A non-TTY stdout (pipe, CI log) never animates — steps print as plain lines.
VERBOSE=false
IS_TTY=false
[ -t 1 ] && IS_TTY=true

# Where a quiet-mode step's stdout+stderr is parked until we know whether it
# failed. One file, reused per step; removed by the EXIT trap.
STEP_LOG="${TMPDIR:-/tmp}/quanta-strike-build.$$.log"

TERM_COLS=$(tput cols 2>/dev/null || echo 80)
[ -n "$TERM_COLS" ] || TERM_COLS=80

SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPINNER_I=0
BAR_WIDTH=22

# Progress is counted in steps — one per run_step call. main() precomputes the
# total from the selected strikes and options (see plan_progress) so the bar is
# a real fraction of the build rather than a guess.
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_PHASE=""
PROGRESS_LABEL=""
BAR_ON_SCREEN=false

bar_enabled() {
    [ "$VERBOSE" != true ] && [ "$IS_TTY" = true ] && [ "$PROGRESS_TOTAL" -gt 0 ]
}

# Wipe the bar off the current line so a permanent message can take it. Every
# print_* helper clears, prints, then redraws — the bar stays pinned at the
# bottom while the real log scrolls above it.
bar_clear() {
    if [ "$BAR_ON_SCREEN" = true ]; then
        printf '\r\033[2K'
        BAR_ON_SCREEN=false
    fi
}

bar_draw() {
    bar_enabled || return 0

    # Clamped: a miscounted budget must never overflow the bar or print >100%.
    local ticks=$PROGRESS_DONE
    [ "$ticks" -gt "$PROGRESS_TOTAL" ] && ticks=$PROGRESS_TOTAL
    local pct=$(( ticks * 100 / PROGRESS_TOTAL ))
    local filled=$(( ticks * BAR_WIDTH / PROGRESS_TOTAL ))

    local fill="" empty="" i
    for ((i = 0; i < BAR_WIDTH; i++)); do
        # Braces are required: bash 3.2 reads the bytes of a multibyte literal
        # that directly follows an unbraced $var as part of the variable name,
        # and the append silently yields nothing.
        if [ "$i" -lt "$filled" ]; then fill="${fill}█"; else empty="${empty}░"; fi
    done

    # Kept free of escape codes so it can be truncated by character count.
    local text="$PROGRESS_LABEL"
    if [ -n "$PROGRESS_PHASE" ] && [ -n "$PROGRESS_LABEL" ]; then
        text="$PROGRESS_PHASE · $PROGRESS_LABEL"
    elif [ -n "$PROGRESS_PHASE" ]; then
        text="$PROGRESS_PHASE"
    fi

    # Never let the line wrap — a wrapped line breaks the \r redraw. The strike
    # name is the point of this line, so it gets whatever room is left.
    local avail=$(( TERM_COLS - BAR_WIDTH - 10 ))
    [ "$avail" -lt 12 ] && avail=12
    if [ "${#text}" -gt "$avail" ]; then
        text="${text:0:$((avail - 1))}…"
    fi

    printf '\r\033[2K%s %s%s%s%s%s %3d%%  %s' \
        "${CYAN}${SPINNER[$SPINNER_I]}${NC}" \
        "$GREEN" "$fill" "$DIM" "$empty" "$NC" \
        "$pct" "$text"

    SPINNER_I=$(( (SPINNER_I + 1) % ${#SPINNER[@]} ))
    BAR_ON_SCREEN=true
}

# Restore the terminal whatever way we leave — multi_select hides the cursor and
# the bar owns a line, both of which would otherwise survive a Ctrl-C.
cleanup_ui() {
    bar_clear
    tput cnorm 2>/dev/null || true
    rm -f "$STEP_LOG"
}
trap cleanup_ui EXIT

# Function to print colored output
print_info() {
    bar_clear; echo -e "${BLUE}ℹ${NC} $1"; bar_draw
}

print_success() {
    bar_clear; echo -e "${GREEN}✓${NC} $1"; bar_draw
}

print_warning() {
    bar_clear; echo -e "${YELLOW}⚠${NC} $1"; bar_draw
}

print_error() {
    bar_clear; echo -e "${RED}✗${NC} $1"; bar_draw
}

print_header() {
    bar_clear; echo -e "${CYAN}▶${NC} $1"; bar_draw
}

# Bar-safe blank line / raw line, for the spots that used a bare echo.
print_line() {
    bar_clear; echo -e "$1"; bar_draw
}

# Run one build step with its output captured, ticking the progress bar.
# Quiet mode animates the bar and stays silent unless the step fails, in which
# case the captured output is dumped. Verbose runs it inline, unfiltered.
# Usage: run_step "<label>" <command> [args...]
run_step() {
    local label="$1"; shift
    PROGRESS_LABEL="$label"
    local rc=0 out_line

    if [ "$VERBOSE" = true ]; then
        print_info "$label"
        "$@" || rc=$?
        PROGRESS_DONE=$((PROGRESS_DONE + 1))
        if [ "$rc" -ne 0 ]; then
            print_error "$label — failed"
        fi
        return "$rc"
    fi

    : > "$STEP_LOG"

    if [ "$IS_TTY" = true ]; then
        # Background it so the spinner can animate while it works. set -e does
        # not fire on a background job, and `wait` is guarded by ||.
        "$@" >"$STEP_LOG" 2>&1 &
        local pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            bar_draw
            sleep 0.08
        done
        wait "$pid" || rc=$?
    else
        "$@" >"$STEP_LOG" 2>&1 || rc=$?
        echo "  · $label"
    fi

    PROGRESS_DONE=$((PROGRESS_DONE + 1))
    bar_draw

    if [ "$rc" -ne 0 ]; then
        bar_clear
        print_error "$label"
        echo -e "${DIM}┈┈┈ captured output ┈┈┈${NC}"
        while IFS= read -r out_line; do
            echo "  $out_line"
        done < "$STEP_LOG"
        echo -e "${DIM}┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈${NC}"
    fi
    return "$rc"
}

# ─── Prompts ─────────────────────────────────────────────────────────────────
# The questions are grouped into numbered sections so it's obvious at a glance
# which part of the build each one is steering.
RULE=""
for ((_i = 0; _i < 60; _i++)); do RULE="${RULE}─"; done
unset _i

SECTION_N=0
SECTION_TOTAL=5

section() {
    local title="$1" hint="$2"
    SECTION_N=$((SECTION_N + 1))
    echo
    if [ -n "$hint" ]; then
        echo -e "${CYAN}${BOLD}$SECTION_N/$SECTION_TOTAL${NC}  ${BOLD}$title${NC}  ${DIM}$hint${NC}"
    else
        echo -e "${CYAN}${BOLD}$SECTION_N/$SECTION_TOTAL${NC}  ${BOLD}$title${NC}"
    fi
    echo -e "${DIM}${RULE}${NC}"
}

# Read a line into the named variable, or leave it empty (the "enter to skip"
# default) when running non-interactively.
read_or_skip() {
    local __var="$1"
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}(skipped)${NC}"
        printf -v "$__var" '%s' ""
    else
        read -r "$__var"
    fi
}

# One question, one dim hint, hints aligned down the column. Padded by CHARACTER
# count rather than with printf's %-46s, which pads by bytes and so mis-aligns
# any question containing a multibyte character (→, ×, …).
PROMPT_COL=46
prompt_line() {
    local question="$1" hint="$2"
    local pad=$(( PROMPT_COL - ${#question} ))
    [ "$pad" -lt 1 ] && pad=1
    printf '  %s?%s %s%*s %s%s%s ' "$YELLOW" "$NC" "$question" "$pad" "" "$DIM" "$hint" "$NC"
}

# Function to ask yes/no question
ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local response
    local hint="[y/N]"

    [ "$default" = "y" ] && hint="[Y/n]"
    prompt_line "$question" "$hint"

    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}$default${NC}"
        response="$default"
    else
        read -r response
        response=${response:-$default}
    fi

    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Numbered single-choice prompt, so every "pick one of these" question in the
# build looks and behaves the same. Options are "value|label|hint" triples; the
# chosen value lands in CHOICE.
# Usage: ask_choice <default_value> <question> "val|label|hint" ...
CHOICE=""
ask_choice() {
    local default="$1" question="$2"; shift 2
    local opts=("$@")
    local count=${#opts[@]}
    local i val label hint
    local default_n=1 default_label="$default"

    echo -e "  ${BOLD}$question${NC}"
    for i in "${!opts[@]}"; do
        IFS='|' read -r val label hint <<< "${opts[$i]}"
        if [ "$val" = "$default" ]; then
            default_n=$((i + 1))
            default_label="$label"
        fi
        printf '     %s%d%s  %-12s %s%s%s\n' "$CYAN" "$((i + 1))" "$NC" "$label" "$DIM" "$hint" "$NC"
    done

    prompt_line "choose" "[1-$count, enter = $default_label]"

    local ans=""
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}$default_n${NC}"
        ans="$default_n"
    else
        read -r ans
        ans="${ans:-$default_n}"
    fi

    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$count" ]; then
        IFS='|' read -r val label hint <<< "${opts[$((ans - 1))]}"
        CHOICE="$val"
    else
        CHOICE="$default"
    fi
}

# Multi-select menu with space to toggle, enter to confirm
# Usage: multi_select "prompt" option1 option2 ...
# Sets global MULTI_SELECT_RESULT with selected indices (0-based)
MULTI_SELECT_RESULT=()
multi_select() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local selected=()
    local cursor=0

    # Non-interactive: the default for "which families?" is all of them.
    if [ "$NON_INTERACTIVE" = true ]; then
        echo
        print_header "$prompt"
        MULTI_SELECT_RESULT=()
        for ((i=0; i<count; i++)); do
            MULTI_SELECT_RESULT+=($i)
            echo -e "    ${GREEN}◉${NC} ${options[$i]}"
        done
        echo -e "  ${DIM}(all — non-interactive)${NC}"
        echo
        return 0
    fi

    # Initialize all as unselected
    for ((i=0; i<count; i++)); do
        selected[$i]=0
    done

    # Hide cursor
    tput civis 2>/dev/null || true

    # Print header
    echo
    print_header "$prompt"
    echo -e "  ${DIM}↑/↓ move • space toggle • a select all • enter confirm${NC}"
    echo

    # Draw initial menu
    for ((i=0; i<count; i++)); do
        if [ $i -eq $cursor ]; then
            if [ ${selected[$i]} -eq 1 ]; then
                echo -e "  ${CYAN}❯${NC} ${GREEN}◉${NC} ${BOLD}${options[$i]}${NC}"
            else
                echo -e "  ${CYAN}❯${NC} ○ ${BOLD}${options[$i]}${NC}"
            fi
        else
            if [ ${selected[$i]} -eq 1 ]; then
                echo -e "    ${GREEN}◉${NC} ${options[$i]}"
            else
                echo -e "    ○ ${options[$i]}"
            fi
        fi
    done

    # Read input
    while true; do
        # Read a single keypress
        IFS= read -rsn1 key

        # Handle escape sequences (arrow keys)
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') # Up arrow
                    ((cursor > 0)) && ((cursor--))
                    ;;
                '[B') # Down arrow
                    ((cursor < count - 1)) && ((cursor++))
                    ;;
            esac
        elif [[ "$key" == ' ' ]]; then
            # Toggle selection
            if [ ${selected[$cursor]} -eq 1 ]; then
                selected[$cursor]=0
            else
                selected[$cursor]=1
            fi
        elif [[ "$key" == 'a' || "$key" == 'A' ]]; then
            # Select all / deselect all
            local all_selected=1
            for ((i=0; i<count; i++)); do
                if [ ${selected[$i]} -eq 0 ]; then
                    all_selected=0
                    break
                fi
            done
            for ((i=0; i<count; i++)); do
                if [ $all_selected -eq 1 ]; then
                    selected[$i]=0
                else
                    selected[$i]=1
                fi
            done
        elif [[ "$key" == '' ]]; then
            # Enter pressed — confirm
            break
        fi

        # Redraw menu (move cursor up)
        for ((i=0; i<count; i++)); do
            tput cuu1 2>/dev/null || printf '\033[1A'
            tput el 2>/dev/null || printf '\033[2K'
        done

        # Redraw
        for ((i=0; i<count; i++)); do
            if [ $i -eq $cursor ]; then
                if [ ${selected[$i]} -eq 1 ]; then
                    echo -e "  ${CYAN}❯${NC} ${GREEN}◉${NC} ${BOLD}${options[$i]}${NC}"
                else
                    echo -e "  ${CYAN}❯${NC} ○ ${BOLD}${options[$i]}${NC}"
                fi
            else
                if [ ${selected[$i]} -eq 1 ]; then
                    echo -e "    ${GREEN}◉${NC} ${options[$i]}"
                else
                    echo -e "    ○ ${options[$i]}"
                fi
            fi
        done
    done

    # Show cursor again
    tput cnorm 2>/dev/null || true

    # Collect selected indices into global
    MULTI_SELECT_RESULT=()
    for ((i=0; i<count; i++)); do
        if [ ${selected[$i]} -eq 1 ]; then
            MULTI_SELECT_RESULT+=($i)
        fi
    done

    echo
}

# Build each strike's TTF from its source pair (PNG + JSON) — the step that used
# to be done by hand as an export. The TTF is a build artifact, so it goes
# to $STAGE_DIR rather than back into src/; everything downstream reads it from
# there. A strike with no PNG+JSON falls back to a prebuilt TTF in src/, which is
# copied into the staging area so the patcher sees one uniform layout.
# Style folders under one strike: src/<family>/<style>/. `regular` is the default
# weight and is listed first; every sibling folder (bold, light, semibold, ...) is
# another weight of the SAME family. The folder name is the only weight signal —
# it flows through to the OS/2 weight class and the CSS font-weight — so it must
# be a real style word (see WEIGHT_MAP in scripts/font-metadata-patcher.py).
# Usage: discover_styles <family>   → one style name per line
discover_styles() {
    local family_name="$1"
    local dir style
    local has_regular=false
    local rest=()

    for dir in "$SRC_DIR/$family_name"/*/; do
        [ -d "$dir" ] || continue          # unmatched glob stays literal
        style="$(basename "$dir")"
        if [ "$style" = "regular" ]; then
            has_regular=true
        else
            rest+=("$style")
        fi
    done

    [ "$has_regular" = true ] && echo "regular"
    for style in "${rest[@]}"; do echo "$style"; done
    return 0
}

# Pick the sheet one variant should build from, inside one style folder.
#
# The weight may be spelled out in the filename or left off — bold/quanta-strike-12-bold
# and bold/quanta-strike-12 are the same sheet, since the FOLDER already says bold.
# A variant suffix (-mono) on top of either wins, because that names genuinely
# different art rather than just restating the folder.
#
# Tried most specific first:
#   quanta-strike-12-bold-mono  quanta-strike-12-mono  quanta-strike-12-bold  quanta-strike-12
#
# Echoes the chosen stem, or nothing if no complete PNG+JSON pair is there.
# Usage: pick_sheet <dir> <family> <style> <suffix>
pick_sheet() {
    local dir="$1" family="$2" style="$3" suffix="$4"
    local stem
    local stems=()

    if [ -n "$suffix" ]; then
        stems+=("${family}-${style}${suffix}" "${family}${suffix}")
    fi
    stems+=("${family}-${style}" "${family}")

    for stem in "${stems[@]}"; do
        if [ -f "$dir/$stem.json" ] && [ -f "$dir/$stem.png" ]; then
            echo "$stem"
            return 0
        fi
    done
    return 0
}

# The source is read from src/<family>/<style>/ but STAGED under a folder named
# <family><suffix> — that folder name becomes the internal family name (the
# metadata patcher takes it from the folder), which is how the mono variant gets
# its "-mono" family. The STYLE folder is kept as-is under it, because the
# patcher reads the weight from that folder name. prop_flag is passed straight to
# scripts/png-to-ttf.py (empty, or "--proportional --prop-gap ...").
#
# A variant may have its OWN hand-drawn sheet: if a <family><suffix> pair exists
# (e.g. quanta-strike-14-mono.{png,json}) it is used for that variant; otherwise
# the variant falls back to the plain <family> source. So mono uses a dedicated
# mono sheet when present, and both variants share the plain source otherwise.
# This is per style folder: bold/ can ship a mono sheet whether or not regular/ does.
# Usage: run_png_to_ttf "<prop_flag>" "<suffix>" family1 family2 ...
run_png_to_ttf() {
    local prop_flag="$1"; shift
    local suffix="$1"; shift
    local families=("$@")

    rm -rf "$STAGE_DIR"

    local built=0
    local reused=0
    local dedicated=()
    local family_name style styles
    for family_name in "${families[@]}"; do
        styles=()
        while IFS= read -r style; do
            [ -n "$style" ] && styles+=("$style")
        done < <(discover_styles "$family_name")

        if [ ${#styles[@]} -eq 0 ]; then
            print_error "$family_name: no style folders in $SRC_DIR/$family_name (expected at least regular/)"
            return 1
        fi

        for style in "${styles[@]}"; do
            local dir="$SRC_DIR/$family_name/$style"
            local stage="$STAGE_DIR/${family_name}${suffix}/$style"

            # Which sheet in this style folder? See pick_sheet for the order.
            local src_name
            src_name="$(pick_sheet "$dir" "$family_name" "$style" "$suffix")"
            local json="$dir/$src_name.json"
            local png="$dir/$src_name.png"
            # TTF fallback: the style-specific one, else plain.
            local prebuilt="$dir/${family_name}-${style}.ttf"
            [ -f "$prebuilt" ] || prebuilt="$dir/$family_name.ttf"

            mkdir -p "$stage"

            if [ -f "$SCRIPTS_DIR/png-to-ttf.py" ] && [ -n "$src_name" ] && [ -f "$json" ] && [ -f "$png" ]; then
                # $prop_flag splits into separate words on purpose (it is
                # "--proportional [--prop-gap N]"), before run_step sees them.
                # shellcheck disable=SC2086
                if run_step "png→ttf · $family_name/$style" \
                        python3 "$SCRIPTS_DIR/png-to-ttf.py" $prop_flag "$json" "$stage"; then
                    if [ "$src_name" != "$family_name" ]; then
                        dedicated+=("$family_name/$style")
                    fi
                    built=$((built + 1))
                else
                    return 1
                fi
            elif [ -f "$prebuilt" ]; then
                # No source pair (or no converter) — fall back to the checked-in TTF.
                cp "$prebuilt" "$stage/"
                print_warning "$family_name/$style: no PNG+JSON source — using the existing TTF"
                reused=$((reused + 1))
            else
                local want="${family_name}-${style}.{png,json} or ${family_name}.{png,json}"
                [ -n "$suffix" ] && want="${family_name}-${style}${suffix}.{png,json}, ${family_name}${suffix}.{png,json}, $want"
                print_error "$family_name/$style: no PNG+JSON source and no TTF to fall back on"
                print_error "  in $dir, wanted a MATCHING pair: $want"
                print_error "  found: $(ls "$dir" 2>/dev/null | tr '\n' ' ')"
                return 1
            fi
        done
    done

    if [ $built -gt 0 ]; then
        print_success "Built $built source TTF(s) from PNG + JSON"
    fi
    if [ ${#dedicated[@]} -gt 0 ]; then
        # For the plain variant a non-default stem just means the sheet is named
        # after its style; for mono it means a hand-drawn mono sheet exists.
        local sheet_kind="style-specific"
        [ -n "$suffix" ] && sheet_kind="${suffix#-}"
        print_line "  ${DIM}$sheet_kind sheets: ${dedicated[*]}${NC}"
    fi
    if [ $reused -gt 0 ]; then
        print_success "Reused $reused prebuilt TTF(s)"
    fi
    return 0
}

# The OFL requires the licence to travel with the fonts ("must be distributed
# entirely under this license"), so drop OFL.txt into every output folder that
# ended up containing fonts. The staging dir is skipped — it isn't shipped.
run_copy_license() {
    if [ ! -f "$LICENSE_FILE" ]; then
        print_warning "$LICENSE_FILE not found — fonts would ship without their licence"
        return 0
    fi

    local copied=0
    local dir f has
    while IFS= read -r dir; do
        # Does this folder actually hold fonts? (An unmatched glob stays literal,
        # so -e is the reliable test — `ls a/*.ttf a/*.otf` would report failure
        # whenever ANY one of the patterns matches nothing.)
        has=0
        for f in "$dir"/*.ttf "$dir"/*.otf "$dir"/*.woff2 "$dir"/*.psfu "$dir"/*.psfu.gz "$dir"/*.psf "$dir"/*.psf.gz; do
            if [ -e "$f" ]; then has=1; break; fi
        done
        if [ $has -eq 0 ]; then continue; fi

        cp "$LICENSE_FILE" "$dir/"
        copied=$((copied + 1))
        if [ "$VERBOSE" = true ]; then
            print_line "  ${DIM}$dir/$(basename "$LICENSE_FILE")${NC}"
        fi
    done < <(find "$BUILD_DIR" -mindepth 1 -type d ! -path "$BUILD_DIR/tmp*" 2>/dev/null)

    if [ $copied -eq 0 ]; then
        print_warning "No font output folders found to place the licence in"
    else
        print_success "Licence copied into $copied folder(s)"
    fi
    return 0
}

# Output-name suffix for a charset file:
#   console-charset.json     → (none)
#   console-charset-hr.json  → hr
#   custom.json              → custom  (avoids clobbering the default output)
charset_suffix_of() {
    local base
    base="$(basename "$1" .json)"
    if [ "$base" = "console-charset" ]; then
        echo ""
    elif [[ "$base" == console-charset-* ]]; then
        echo "${base#console-charset-}"
    else
        echo "$base"
    fi
}

# List charset choices at the repo root: default first, then console-charset-*.json.
# Echoes absolute-or-relative paths, one per line.
list_charset_files() {
    if [ -f "$DEFAULT_CHARSET_FILE" ]; then
        echo "$DEFAULT_CHARSET_FILE"
    fi
    local f
    for f in ./console-charset-*.json; do
        [ -f "$f" ] || continue
        echo "$f"
    done
}

# Pick which charset the PSF step will use. Console PSF is OPT-IN (default no),
# same idea as Nerd Fonts. The main release skips it. Honours:
#   --no-psf          → skip
#   --psf / --charset / --psf-scale → force on (skip the yes/no)
#   otherwise prompt (default n); --defaults takes that default and skips.
# Sets PSF_CHARSET or PSF_SKIP. Asks PSF scale afterwards when building.
choose_psf_charset() {
    if [ "$PSF_SKIP" = true ]; then
        print_info "Console PSF: skipped (--no-psf)."
        return 0
    fi

    # --charset / --psf-scale imply the user wants PSF even without --psf.
    local forced=false
    if [ "$PSF_FORCED" = true ] || [ "$PSF_CHARSET_SET" = true ] || [ "$PSF_SCALE_SET" = true ]; then
        forced=true
    fi

    if [ "$forced" = true ] && [ "$PSF_CHARSET_SET" = true ]; then
        if [ ! -f "$PSF_CHARSET" ]; then
            print_error "Charset not found: $PSF_CHARSET"
            return 1
        fi
        print_info "Console PSF charset: ${BOLD}$PSF_CHARSET${NC} (--charset)."
        choose_psf_scale
        return $?
    fi

    echo -e "  ${DIM}≤256-glyph .psfu.gz for Linux/Raspberry Pi consoles (setfont).${NC}"
    echo -e "  ${DIM}Opt-in — the release zip skips these; local/clone builds only.${NC}"

    if [ "$forced" != true ]; then
        if ! ask_yes_no "Build console PSF fonts?" "n"; then
            PSF_SKIP=true
            return 0
        fi
    else
        echo -e "  ${DIM}enabled via --psf / --charset / --psf-scale${NC}"
    fi

    local choices=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && choices+=("$line")
    done < <(list_charset_files)

    if [ ${#choices[@]} -eq 0 ] && [ "$NON_INTERACTIVE" = true ]; then
        print_warning "No $DEFAULT_CHARSET_FILE — skipping console PSF."
        PSF_SKIP=true
        return 0
    fi

    # Non-interactive: tracked default charset (only reached when forced or
    # ask_yes_no already said y — and with default n, -y alone never gets here
    # unless --psf / --charset / --psf-scale).
    if [ "$NON_INTERACTIVE" = true ]; then
        if [ ! -f "$DEFAULT_CHARSET_FILE" ]; then
            print_warning "No $DEFAULT_CHARSET_FILE — skipping console PSF."
            PSF_SKIP=true
            return 0
        fi
        PSF_CHARSET="$DEFAULT_CHARSET_FILE"
        echo -e "  ${DIM}charset: $PSF_CHARSET (default)${NC}"
        choose_psf_scale
        return $?
    fi

    # Interactive: numbered list + free-path entry. Kept hand-rolled rather than
    # using ask_choice because the options are discovered at runtime and a path
    # typed in full is also a valid answer.
    local i
    if [ ${#choices[@]} -gt 0 ]; then
        echo -e "  ${BOLD}Charset${NC} ${DIM}— or type a path to another JSON${NC}"
        for i in "${!choices[@]}"; do
            local label="${choices[$i]}"
            local tag=""
            [ "$label" = "$DEFAULT_CHARSET_FILE" ] && tag="  ${DIM}(default)${NC}"
            echo -e "     ${CYAN}$((i + 1))${NC}  $label$tag"
        done
    else
        echo -e "  ${DIM}No console-charset*.json found — type a path to a charset JSON.${NC}"
    fi

    local default_ans=1
    if [ ${#choices[@]} -eq 0 ]; then
        default_ans=""
    fi
    prompt_line "choose" "[enter = ${default_ans:-a path}]"
    local ans=""
    read -r ans
    ans="${ans:-$default_ans}"

    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le ${#choices[@]} ]; then
        PSF_CHARSET="${choices[$((ans - 1))]}"
    elif [ -n "$ans" ]; then
        PSF_CHARSET="$ans"
    else
        print_error "No charset selected."
        return 1
    fi

    if [ ! -f "$PSF_CHARSET" ]; then
        print_error "Charset not found: $PSF_CHARSET"
        return 1
    fi
    choose_psf_scale
    return $?
}

# Integer nearest-neighbor upscale for PSF cells only (not the TTF scale factor).
# Default 1 = native pixels. --psf-scale N pins it and skips the prompt.
choose_psf_scale() {
    if [ "$PSF_SKIP" = true ]; then
        return 0
    fi

    if [ "$PSF_SCALE_SET" = true ]; then
        if ! [[ "$PSF_SCALE" =~ ^[1-9][0-9]*$ ]]; then
            print_error "PSF scale must be an integer ≥ 1 (got '$PSF_SCALE')"
            return 1
        fi
        echo -e "  ${DIM}PSF scale ×$PSF_SCALE (--psf-scale)${NC}"
        return 0
    fi

    echo -e "  ${DIM}PSF scale is nearest-neighbor (1 = native, 2 = double, …), and is${NC}"
    echo -e "  ${DIM}separate from the TTF scale factor asked for under Typography.${NC}"
    prompt_line "PSF scale" "[enter = 1]"
    local ans=""
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}1${NC}"
        ans=1
    else
        read -r ans
        ans="${ans:-1}"
    fi
    if ! [[ "$ans" =~ ^[1-9][0-9]*$ ]]; then
        print_error "PSF scale must be an integer ≥ 1 (got '$ans')"
        return 1
    fi
    PSF_SCALE="$ans"
    return 0
}

# Linux console PSF fonts (Raspberry Pi Lite / fbcon). Reads the mono sheet
# (or the plain sheet when no -mono pair exists), trims to PSF_CHARSET,
# writes build/psf/quanta-strike/*.psfu.gz. Call choose_psf_charset first.
# Usage: run_png_to_psf family1 family2 ...
run_png_to_psf() {
    local families=("$@")

    if [ "$PSF_SKIP" = true ]; then
        return 0
    fi
    if [ -z "$PSF_CHARSET" ] || [ ! -f "$PSF_CHARSET" ]; then
        print_error "No PSF charset resolved (internal error — choose_psf_charset first)"
        return 1
    fi
    if [ ! -f "$SCRIPTS_DIR/png-to-psf.py" ]; then
        print_error "scripts/png-to-psf.py not found"
        return 1
    fi

    local charset_suffix suffix_flag="" scale_flag=""
    charset_suffix="$(charset_suffix_of "$PSF_CHARSET")"
    [ -n "$charset_suffix" ] && suffix_flag="--suffix $charset_suffix"
    scale_flag="--scale $PSF_SCALE"

    local psf_note="$PSF_CHARSET"
    [ -n "$charset_suffix" ] && psf_note="$psf_note, suffix -$charset_suffix"
    [ "$PSF_SCALE" != "1" ] && psf_note="$psf_note, ×$PSF_SCALE"
    print_header "Console PSF ${DIM}($psf_note) → $PSF_DIR${NC}"
    PROGRESS_PHASE="psf"

    rm -rf "$PSF_DIR"
    mkdir -p "$PSF_DIR"

    local built=0
    local family_name style styles src_name json
    for family_name in "${families[@]}"; do
        styles=()
        while IFS= read -r style; do
            [ -n "$style" ] && styles+=("$style")
        done < <(discover_styles "$family_name")

        for style in "${styles[@]}"; do
            local dir="$SRC_DIR/$family_name/$style"
            src_name="$(pick_sheet "$dir" "$family_name" "$style" "-mono")"
            if [ -z "$src_name" ]; then
                print_warning "$family_name/$style: no PNG+JSON sheet — skipping PSF"
                continue
            fi
            json="$dir/$src_name.json"
            # shellcheck disable=SC2086
            if run_step "psf · $family_name/$style" \
                    python3 "$SCRIPTS_DIR/png-to-psf.py" --charset "$PSF_CHARSET" \
                    $suffix_flag $scale_flag "$json" "$PSF_DIR"; then
                built=$((built + 1))
            else
                return 1
            fi
        done
    done

    if [ $built -eq 0 ]; then
        print_warning "No console PSF fonts were built"
        return 1
    fi
    print_success "Built $built console PSF font(s)"
    return 0
}

# Function to run metadata patcher. Extra patcher flags come in as real
# arguments (not a string to eval), so values containing spaces — the licence
# text, mostly — survive without a quoting round-trip.
# Usage: run_metadata_patcher <family> [patcher flags...]
run_metadata_patcher() {
    local family_name="$1"; shift

    # Reads the staged TTF that scripts/png-to-ttf.py just built, not src/.
    run_step "metadata · $family_name" \
        python3 "$SCRIPTS_DIR/font-metadata-patcher.py" \
            --src "$STAGE_DIR" --family "$family_name" \
            --output "$TTF_GROUP_DIR" --flat "$@"
}

# Function to run nerd fonts generator for selected families only
# Usage: run_nerd_fonts_generator family1 family2 ...
run_nerd_fonts_generator() {
    local families=("$@")

    if [ ! -f "$SCRIPTS_DIR/generate-nerd-fonts" ]; then
        print_error "scripts/generate-nerd-fonts script not found"
        return 1
    fi

    if [ ! -d "$TTF_GROUP_DIR" ]; then
        print_error "Build directory not found: $TTF_GROUP_DIR"
        return 1
    fi

    if [ ${#families[@]} -eq 0 ]; then
        print_error "No families specified for Nerd Font generation"
        return 1
    fi

    # One invocation per family rather than one for the lot: this is by far the
    # slowest step, and per-family calls let the progress bar name the strike
    # being patched. The generator only ever adds to its output dir (it diffs
    # the folder before/after each font), so splitting the run is safe.
    local nerd_dir="${TTF_GROUP_DIR}-nerd"
    print_header "Nerd Fonts ${DIM}(mono only) → $nerd_dir${NC}"
    PROGRESS_PHASE="nerd"

    local fam
    for fam in "${families[@]}"; do
        if ! run_step "nerd · $fam" \
                "$SCRIPTS_DIR/generate-nerd-fonts" "$TTF_GROUP_DIR" "$nerd_dir" "$fam"; then
            return 1
        fi
    done

    print_success "Patched ${#families[@]} strike(s) with Nerd Font icons"
    return 0
}

# Function to run small caps generator
run_small_caps() {
    local source="$1"
    local c2sc="$2"
    local args=(--src "$TTF_GROUP_DIR" --source "$source")

    if [ "$c2sc" != "true" ]; then
        args+=(--no-c2sc)
    fi

    run_step "small caps ($source)" \
        python3 "$SCRIPTS_DIR/add-small-caps.py" "${args[@]}"
}

# Function to run old-style figures generator
run_old_style_figures() {
    local source="$1"

    run_step "old-style figures ($source)" \
        python3 "$SCRIPTS_DIR/add-old-style-figures.py" \
            --src "$TTF_GROUP_DIR" --source "$source"
}

# Function to convert the built TTFs to WOFF2 web fonts
run_woff2() {
    local include_nerd="$1"
    local args=("$TTF_DIR" "$BUILD_DIR/woff2")
    local label="woff2"

    if [ "$include_nerd" = "true" ]; then
        args+=(--include-nerd)
        label="woff2 (with nerd)"
    fi

    run_step "$label" python3 "$SCRIPTS_DIR/convert-woff2.py" "${args[@]}"
}

# Emit the ready-to-use CSS next to the WOFF2 output. The classes it writes bind
# each strike's family to its size, which is the one thing a consumer must not
# get wrong. Needs the WOFF2 step to have run — it reads the built files.
run_generate_css() {
    run_step "css" python3 "$SCRIPTS_DIR/generate-css.py" "$BUILD_DIR/woff2"
}

# Verify the pixel-grid invariant (em == N*128, glyphs on the 128 grid) for one
# or more targets. Refuses to continue if any strike would render a pixel that
# is not exactly 1.0000px at its native size.
# Usage: run_verify "label" target1 [target2 ...]
run_verify() {
    local label="$1"; shift
    local targets=("$@")

    if [ ! -f "$SCRIPTS_DIR/verify-pixel-grid.py" ]; then
        print_warning "scripts/verify-pixel-grid.py not found — skipping invariant check"
        return 0
    fi

    if run_step "verify pixel grid · $label" \
            python3 "$SCRIPTS_DIR/verify-pixel-grid.py" "${targets[@]}"; then
        return 0
    fi
    print_error "Pixel-grid invariant violated ($label) — a pixel would not be 1.0000px at native size"
    return 1
}

# Function to uniformly scale the whole family bigger while keeping the pixel
# size identical across strikes (picotype-style line metrics, one shared factor)
run_pixel_scale() {
    local scale="$1"

    if [ ! -f "$SCRIPTS_DIR/pixel-scale.py" ]; then
        print_error "scripts/pixel-scale.py not found"
        return 1
    fi

    run_step "scale ×$scale" \
        python3 "$SCRIPTS_DIR/pixel-scale.py" "$TTF_GROUP_DIR" --scale "$scale"
}

# Function to anchor the em to N*128 (pixel-perfect) and set line metrics to the
# full ink extent, so accents drawn above the em (taller canvas) don't clip.
run_anchor_em() {
    if [ ! -f "$SCRIPTS_DIR/anchor-em.py" ]; then
        print_error "scripts/anchor-em.py not found"
        return 1
    fi

    run_step "anchor em" python3 "$SCRIPTS_DIR/anchor-em.py" "$TTF_GROUP_DIR"
}

# Ask user to choose a small cap glyph source. Answer lands in CHOICE.
ask_smcp_source() {
    ask_choice phonetic "Small-cap source" \
        "phonetic|phonetic|Unicode small capitals (ᴀ ʙ ᴄ … ꞯ)" \
        "lowercase|lowercase|reuse the lowercase glyphs" \
        "capital|capital|reuse the uppercase glyphs"
}

# Ask user to choose an old-style figure glyph source. Answer lands in CHOICE.
ask_onum_source() {
    ask_choice circled "Old-style figure source" \
        "circled|circled|⓿①②③④⑤⑥⑦⑧⑨" \
        "superscript|superscript|⁰¹²³⁴⁵⁶⁷⁸⁹" \
        "subscript|subscript|₀₁₂₃₄₅₆₇₈₉" \
        "lining|lining|same as the regular digits"
}

# Get current version of a font family from build folder
# Usage: get_family_version "picosans"  → prints version string (e.g. "0.2")
get_family_version() {
    local family="$1"
    python3 -c "
import fontforge, sys, os
fdir = '$TTF_GROUP_DIR'
if not os.path.isdir(fdir):
    sys.exit(0)
for fname in sorted(os.listdir(fdir)):
    if fname.startswith('$family') and fname.endswith(('.ttf', '.otf')):
        f = fontforge.open(os.path.join(fdir, fname))
        print(f.version or '')
        f.close()
        sys.exit(0)
" 2>/dev/null
}

# The release number lives in a tracked VERSION file, not in the fonts. The fonts
# are build artifacts under a git-ignored build/, so reading the version back out
# of them loses it the moment someone wipes the folder.
read_project_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    fi
}

# Record whatever version this build stamped, so it can be written back.
# Must be resolved in the parent shell (see resolve_project_version) — never
# inside a $(...) capture, or the assignment dies with the subshell and
# VERSION is left untouched even though the fonts were stamped correctly.
RESOLVED_VERSION=""

# Semver bump of one component. Missing parts count as 0, so a bare "1" bumps
# sanely. Usage: bump_version "0.5.1" patch  → 0.5.2
bump_version() {
    local current="$1" kind="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current"
    major=${major:-0}
    minor=${minor:-0}
    patch=${patch:-0}
    case "$kind" in
        patch) echo "$major.$minor.$((patch + 1))" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        major) echo "$((major + 1)).0.0" ;;
        *)     echo "$current" ;;
    esac
}

write_project_version() {
    [ -z "$RESOLVED_VERSION" ] && return 0
    local current
    current=$(read_project_version)
    [ "$current" = "$RESOLVED_VERSION" ] && return 0
    printf '%s\n' "$RESOLVED_VERSION" > "$VERSION_FILE"
    print_success "Version $current → $RESOLVED_VERSION (written to $VERSION_FILE)"
}

# Resolve VERSION_STRATEGY → RESOLVED_VERSION once, in the parent shell.
# Call after ask_version / get_metadata_options; before any build_variant.
resolve_project_version() {
    local current_version
    current_version=$(read_project_version)
    RESOLVED_VERSION=""

    case "$VERSION_STRATEGY" in
        patch|minor|major)
            if [ -z "$current_version" ]; then
                return
            fi
            RESOLVED_VERSION="$(bump_version "$current_version" "$VERSION_STRATEGY")"
            ;;
        custom)
            if [ -n "$VERSION_CUSTOM" ]; then
                RESOLVED_VERSION="$VERSION_CUSTOM"
            fi
            ;;
        *)
            # keep — still stamp it. png-to-ttf builds each TTF from scratch, so
            # without an explicit --version the font falls back to FontForge's
            # default of 1.0 and "keep" would silently reset the release number.
            if [ -n "$current_version" ]; then
                RESOLVED_VERSION="$current_version"
            fi
            ;;
    esac

    VERSION_FLAG=()
    if [ -n "$RESOLVED_VERSION" ]; then
        VERSION_FLAG=(--version "$RESOLVED_VERSION")
    fi
}

# The metadata-patcher flag carrying RESOLVED_VERSION, as an array so it can be
# spliced into the argument list (empty = nothing to stamp). Filled in by
# resolve_project_version; read by build_variant.
VERSION_FLAG=()

# Global version strategy (set by ask_version): keep|patch|minor|major|custom
VERSION_STRATEGY="keep"
VERSION_CUSTOM=""

# Turn scripts/default-metadata.json into patcher flags, ONE PER LINE — the
# caller reads them straight into an array, so a value with spaces (the licence
# text) needs no shell quoting and never goes through eval.
metadata_flags_from_defaults() {
    python3 - "$DEFAULTS_FILE" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1]))
flags = []
if cfg.get("lowercase"):
    flags.append("--lowercase")
if cfg.get("debug"):
    flags.append("--debug")
# NB: `type` is deliberately NOT emitted here — the PFM family type is per
# variant (mono = monospace, proportional = sans/serif), so build_variant
# appends its own --type. Emitting it here would let the defaults' value win.
for key, flag in (("extension", "--extension"),
                  ("designer", "--designer"), ("designerurl", "--designerurl"),
                  ("copyright", "--license"), ("license", "--licensedesc"),
                  ("licenseurl", "--licenseurl")):
    value = cfg.get(key)
    if value:
        flags += [flag, str(value)]
print("\n".join(flags))
PY
}

# Print a human summary of what the defaults will apply.
metadata_summary_from_defaults() {
    python3 - "$DEFAULTS_FILE" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1]))
for key in ("designer", "designerurl", "copyright", "license", "licenseurl",
            "extension"):
    value = cfg.get(key)
    if not value:
        continue
    text = str(value)
    if len(text) > 64:
        text = text[:61] + "..."
    print(f"  {key:12s} {text}")
PY
}

# Ask for the version bump. Deliberately always asked, never taken from
# scripts/default-metadata.json: it's a per-release decision, not a project constant.
# Sets VERSION_STRATEGY / VERSION_CUSTOM; resolved by resolve_project_version.
ask_version() {
    local current
    current=$(read_project_version)

    ask_choice keep "Version ${DIM}— currently ${current:-unset}, from $VERSION_FILE${NC}" \
        "keep|keep|stay on ${current:-1.0}" \
        "patch|patch|→ $(bump_version "$current" patch)" \
        "minor|minor|→ $(bump_version "$current" minor)" \
        "major|major|→ $(bump_version "$current" major)" \
        "custom|custom|type an exact version"
    VERSION_STRATEGY="$CHOICE"
    VERSION_CUSTOM=""

    if [ "$VERSION_STRATEGY" = "custom" ]; then
        prompt_line "exact version" ""
        read_or_skip VERSION_CUSTOM
        if [ -z "$VERSION_CUSTOM" ]; then
            VERSION_STRATEGY="keep"
        fi
    fi
}

# Gather metadata patcher options (stores in the global METADATA_OPTS array)
get_metadata_options() {
    METADATA_OPTS=()

    # Defaults file present → take everything from it EXCEPT the version bump.
    if [ -f "$DEFAULTS_FILE" ]; then
        local flag
        while IFS= read -r flag; do
            [ -n "$flag" ] && METADATA_OPTS+=("$flag")
        done < <(metadata_flags_from_defaults)

        PROP_TYPE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("prop-type") or "sans")' "$DEFAULTS_FILE")"
        # Only adopt a build-level spacing if the defaults file actually sets one;
        # otherwise leave it empty so each strike's JSON `spacing` key stays in charge.
        if [ "$PROP_GAP_SET" != true ]; then
            PROP_GAP="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["spacing"] if "spacing" in c else "")' "$DEFAULTS_FILE")"
        fi

        echo -e "  ${DIM}from ${DEFAULTS_FILE#$SCRIPT_DIR/} — edit it to change these, delete it to be asked:${NC}"
        metadata_summary_from_defaults
        echo -e "  ${DIM}proportional PFM type is ${PROP_TYPE}; mono is always monospace${NC}"
        return 0
    fi

    if ask_yes_no "Use lowercase font names?" "y"; then
        METADATA_OPTS+=(--lowercase)
    fi

    # The build always emits a monospace variant AND a proportional variant, so
    # there is no "is it mono?" question — mono is always PFM type monospace.
    # Ask only what the proportional variant should be classified as.
    if ask_yes_no "Proportional variant: serif (instead of sans)?"; then
        PROP_TYPE="serif"
    else
        PROP_TYPE="sans"
    fi

    local extension designer_url license_url license_text

    prompt_line "Output extension" "[ttf/otf, enter = keep]"
    read_or_skip extension
    if [ -n "$extension" ]; then
        METADATA_OPTS+=(--extension "$extension")
    fi

    prompt_line "Designer URL" "[enter = skip]"
    read_or_skip designer_url
    if [ -n "$designer_url" ]; then
        METADATA_OPTS+=(--designerurl "$designer_url")
    fi

    prompt_line "License URL" "[enter = skip]"
    read_or_skip license_url
    if [ -n "$license_url" ]; then
        METADATA_OPTS+=(--licenseurl "$license_url")
    fi

    prompt_line "License/copyright text" "[enter = skip]"
    read_or_skip license_text
    if [ -n "$license_text" ]; then
        METADATA_OPTS+=(--license "$license_text")
    fi

    if ask_yes_no "Enable debug logging?"; then
        METADATA_OPTS+=(--debug)
    fi
}

# Build one variant (mono or proportional) end-to-end into its own group dir:
# png-to-ttf → source guard → metadata → features → anchor → optional scale →
# output guard. Sets the STAGE_DIR / TTF_GROUP_DIR globals the run_* helpers use.
# Reads the feature/scale choices from main()'s locals (bash dynamic scope).
# Usage: build_variant "<label>" "<stage_dir>" "<group_dir>" "<pfm_type>" \
#                      "<prop_flag>" "<suffix>" src_family1 src_family2 ...
build_variant() {
    local label="$1" stage="$2" group="$3" pfm_type="$4" prop_flag="$5" suffix="$6"
    shift 6
    local src_families=("$@")

    STAGE_DIR="$stage"
    TTF_GROUP_DIR="$group"

    # Short tag for the progress line — the full label is far too long for it,
    # and the strike name matters more than restating the variant.
    local phase="prop"
    [ -n "$suffix" ] && phase="mono"
    PROGRESS_PHASE="$phase"

    echo
    print_header "${BOLD}$label${NC} ${DIM}→ $group${NC}"

    # Staged/internal family names carry the suffix (mono → "-mono"); the
    # metadata patcher reads the family name from the staging folder.
    local f
    local stage_families=()
    for f in "${src_families[@]}"; do stage_families+=("${f}${suffix}"); done

    # 1. Build the source TTFs (proportional or mono) into the staging dir.
    if ! run_png_to_ttf "$prop_flag" "$suffix" "${src_families[@]}"; then
        print_error "Could not build source TTFs for $label — aborting."
        return 1
    fi

    # 2. Fail fast: the freshly staged strikes must sit on the pixel grid.
    local src_targets=()
    for f in "${stage_families[@]}"; do src_targets+=("$STAGE_DIR/$f"); done
    if ! run_verify "source" "${src_targets[@]}"; then
        print_error "Fix the source strike(s) above before building — aborting."
        return 1
    fi

    # 3. Metadata for each strike (into this variant's group dir). --type is
    #    appended last so it wins over anything the defaults might carry.
    local sfam
    for sfam in "${stage_families[@]}"; do
        if ! run_metadata_patcher "$sfam" \
                "${METADATA_OPTS[@]}" --type "$pfm_type" "${VERSION_FLAG[@]}"; then
            return 1
        fi
    done
    print_success "Metadata patched (${#stage_families[@]} strikes)"

    # 4. Features on the base TTFs, then anchor + optional scale.
    if [ "$do_small_caps" = true ]; then
        if ! run_small_caps "$smcp_source" "$smcp_c2sc"; then return 1; fi
    fi
    if [ "$do_onum" = true ]; then
        if ! run_old_style_figures "$onum_source"; then return 1; fi
    fi

    if ! run_anchor_em; then return 1; fi
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        if ! run_pixel_scale "$scale_factor"; then return 1; fi
    fi

    # 5. Gate: the built strikes must still hold the pixel-grid invariant.
    if ! run_verify "build output" "$TTF_GROUP_DIR"; then
        print_error "Built $label fonts broke the pixel-grid invariant — aborting."
        return 1
    fi
    print_success "$label ready"
    return 0
}

# Main function
main() {
    echo
    echo -e "${CYAN}${BOLD}  quanta-strike${NC}${DIM} · font build${NC}"
    echo -e "${DIM}  ${RULE}${NC}"

    # Check if source directory exists
    if [ ! -d "$SRC_DIR" ]; then
        print_error "Source directory not found: $SRC_DIR"
        exit 1
    fi

    # Check if scripts/font-metadata-patcher.py exists
    if [ ! -f "$SCRIPTS_DIR/font-metadata-patcher.py" ]; then
        print_error "scripts/font-metadata-patcher.py not found in current directory"
        exit 1
    fi

    # Find all family directories
    local family_names=()
    for family_dir in $(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d | sort); do
        family_names+=("$(basename "$family_dir")")
    done

    if [ ${#family_names[@]} -eq 0 ]; then
        print_error "No font family directories found in $SRC_DIR"
        exit 1
    fi

    # ─── 1. Which strikes ─────────────────────────────────────────────
    section "Strikes" "which sizes and weights to build"
    multi_select "Select font families to build" "${family_names[@]}"
    local selected_indices=("${MULTI_SELECT_RESULT[@]}")

    if [ ${#selected_indices[@]} -eq 0 ]; then
        print_warning "No families selected. Exiting."
        exit 0
    fi

    # Show what was selected
    local selected_families=()
    for idx in "${selected_indices[@]}"; do
        selected_families+=("${family_names[$idx]}")
    done

    # Every style folder under a strike is another weight of it. Listed here so a
    # mis-named folder (or a missing one) is obvious before the build starts.
    # Doubles as the style count the progress total is derived from.
    local fam fam_styles
    local style_count=0
    for fam in "${selected_families[@]}"; do
        fam_styles=$(discover_styles "$fam" | tr '\n' ' ')
        fam_styles="${fam_styles% }"
        echo -e "  ${DIM}$fam${NC}  ${DIM}·${NC} $fam_styles"
        for _s in $fam_styles; do style_count=$((style_count + 1)); done
    done
    echo -e "  ${DIM}each strike is built twice: proportional (quanta-strike-N) + mono (…-N-mono)${NC}"

    # NB: the actual source build (png-to-ttf) + source guard now happen once per
    # variant inside build_variant, since each variant trims widths differently.
    # Here we only gather the shared options.

    # ─── 2. Release ───────────────────────────────────────────────────
    section "Release" "version + font metadata"
    ask_version
    resolve_project_version
    get_metadata_options

    # ─── 3. Typography ────────────────────────────────────────────────
    section "Typography" "optional features, spacing, sizing"

    local do_small_caps=false
    local smcp_source="phonetic"
    local smcp_c2sc=true
    if ask_yes_no "Add small caps (smcp/c2sc)?" "y"; then
        do_small_caps=true
        ask_smcp_source
        smcp_source="$CHOICE"
        if ! ask_yes_no "Also add c2sc (uppercase → small caps)?" "y"; then
            smcp_c2sc=false
        fi
    fi

    local do_onum=false
    local onum_source="circled"
    if ask_yes_no "Add old-style figures (onum)?" "y"; then
        do_onum=true
        ask_onum_source
        onum_source="$CHOICE"
    fi

    # Proportional inter-glyph spacing. --spacing (or a defaults-file value)
    # already pinned it if set; otherwise ask. Blank = let each strike's JSON
    # `spacing` key decide (falling back to auto). A value here forces every
    # strike. The mono variant is unaffected either way.
    if [ "$PROP_GAP_SET" != true ] && [ -z "$PROP_GAP" ]; then
        echo
        echo -e "  ${DIM}Proportional gap between glyphs (mono is unaffected). Blank lets each${NC}"
        echo -e "  ${DIM}strike's JSON \`spacing\` key decide, else auto (1/2/3px by size); a${NC}"
        echo -e "  ${DIM}pixel count or 'auto' here forces every strike.${NC}"
        prompt_line "Proportional spacing" "[enter = per-strike/auto]"
        local sp=""
        if [ "$NON_INTERACTIVE" = true ]; then
            echo -e "${DIM}(blank)${NC}"
        else
            read -r sp
        fi
        [ -n "$sp" ] && PROP_GAP="$sp"
    fi
    # Lowercase; validate: empty (defer), 'auto'/'smart', or a non-negative integer.
    PROP_GAP=$(printf '%s' "$PROP_GAP" | tr '[:upper:]' '[:lower:]')
    if [ -n "$PROP_GAP" ] && [ "$PROP_GAP" != "auto" ] && [ "$PROP_GAP" != "smart" ] && ! [[ "$PROP_GAP" =~ ^[0-9]+$ ]]; then
        print_error "Proportional spacing must be blank, 'auto', or a non-negative integer (got '$PROP_GAP')"
        exit 1
    fi

    # Vertical sizing: always anchor to pixel-perfect (em = N*128), then an
    # optional uniform scale-up on top. Default scale 1 = leave it pixel-perfect.
    echo
    echo -e "  ${DIM}Every strike is anchored to em = N×128 (pixel-perfect, 1px at native).${NC}"
    echo -e "  ${DIM}A factor here scales the whole family on top of that.${NC}"
    prompt_line "Scale factor" "[enter = 1, pixel-perfect]"
    local sf=""
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}1${NC}"
    else
        read -r sf
    fi
    local scale_factor="${sf:-1}"

    # ─── 4. Outputs ───────────────────────────────────────────────────
    section "Outputs" "what to emit besides the TTFs"

    # Nerd Fonts are for coding/TUIs, which is exactly where the mono variant is
    # used — so they're generated for the MONO variant only (and always last,
    # since patching is the slow part). The proportional variant gets none. They
    # are OPT-IN: --nerd-fonts forces them on; otherwise the prompt defaults to no.
    # Asked before WOFF2 because the WOFF2 question depends on the answer.
    local do_nerd=false
    if [ "$NERD_FORCED" = true ]; then
        do_nerd=true
        echo -e "  ${DIM}Nerd Fonts enabled via --nerd-fonts (mono variant only)${NC}"
    elif ask_yes_no "Generate Nerd Font variants? (mono only, slow)" "n"; then
        do_nerd=true
    fi

    local do_woff2=false
    local do_woff2_nerd=false
    if ask_yes_no "Export WOFF2 web fonts + CSS?" "y"; then
        do_woff2=true
        if [ "$do_nerd" = true ]; then
            if ask_yes_no "Include the Nerd Font variants in WOFF2? (large)"; then
                do_woff2_nerd=true
            fi
        fi
    fi

    # Console PSF charset (or --no-psf / --charset). Default = console-charset.json.
    echo
    if ! choose_psf_charset; then
        exit 1
    fi

    local prop_group="$TTF_DIR/quanta-strike"
    local mono_group="$TTF_DIR/quanta-strike-mono"

    # Pass a build-level --prop-gap only when one was set; otherwise png-to-ttf
    # reads each strike's JSON `spacing` key (falling back to auto).
    local prop_flag="--proportional"
    local gap_desc
    if [ -z "$PROP_GAP" ]; then
        gap_desc="per-strike/auto gap"
    elif [ "$PROP_GAP" = "auto" ] || [ "$PROP_GAP" = "smart" ]; then
        gap_desc="auto gap (all strikes)"
        prop_flag="$prop_flag --prop-gap $PROP_GAP"
    else
        gap_desc="${PROP_GAP}px gap (all strikes)"
        prop_flag="$prop_flag --prop-gap $PROP_GAP"
    fi

    # ─── 5. Review ────────────────────────────────────────────────────
    # Everything that was just decided, on one screen, before the slow part
    # starts — the answers are spread over four sections and this is the only
    # place they can be checked against each other.
    section "Review" "confirm and build"

    local strike_list="${selected_families[*]}"
    strike_list="${strike_list//quanta-strike-/}"

    local version_desc="${RESOLVED_VERSION:-unchanged}"
    if [ -n "$RESOLVED_VERSION" ] && [ "$RESOLVED_VERSION" != "$(read_project_version)" ]; then
        version_desc="$(read_project_version) → $RESOLVED_VERSION"
    fi

    # Built with plain ifs on purpose: an assignment whose value contains a
    # failing $(...) takes that non-zero status, and under set -e a one-liner
    # like `[ x ] && v="$(...)"` would end the run instead of the string.
    local feature_desc=""
    if [ "$do_small_caps" = true ]; then
        feature_desc="small caps ($smcp_source"
        if [ "$smcp_c2sc" = true ]; then
            feature_desc="$feature_desc +c2sc"
        fi
        feature_desc="$feature_desc)"
    fi
    if [ "$do_onum" = true ]; then
        if [ -n "$feature_desc" ]; then
            feature_desc="$feature_desc, "
        fi
        feature_desc="${feature_desc}old-style figures ($onum_source)"
    fi
    if [ -z "$feature_desc" ]; then
        feature_desc="none"
    fi

    local sizing_desc="pixel-perfect (em = N×128)"
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        sizing_desc="$sizing_desc, then ×$scale_factor"
    fi

    local output_desc="ttf"
    [ "$do_woff2" = true ] && output_desc="$output_desc, woff2 + css"
    if [ "$do_nerd" = true ]; then
        output_desc="$output_desc, nerd (mono)"
        [ "$do_woff2_nerd" = true ] && output_desc="$output_desc + its woff2"
    fi
    if [ "$PSF_SKIP" != true ] && [ -n "$PSF_CHARSET" ]; then
        output_desc="$output_desc, psf ($(basename "$PSF_CHARSET")"
        [ "$PSF_SCALE" != "1" ] && output_desc="$output_desc ×$PSF_SCALE"
        output_desc="$output_desc)"
    fi

    local rk
    for rk in \
        "strikes|${#selected_families[@]} · $strike_list ($style_count weights)" \
        "variants|proportional ($PROP_TYPE, $gap_desc) + mono" \
        "version|$version_desc" \
        "features|$feature_desc" \
        "sizing|$sizing_desc" \
        "outputs|$output_desc" \
        "into|$BUILD_DIR/"; do
        printf '  %s%-10s%s %s\n' "$DIM" "${rk%%|*}" "$NC" "${rk#*|}"
    done
    echo

    if ! ask_yes_no "Start the build?" "y"; then
        print_warning "Nothing built."
        exit 0
    fi

    # Budget the progress bar: every run_step below is one unit. Per variant —
    # one png-to-ttf per weight, a source verify, one metadata pass per strike,
    # optional features, anchor, optional scale, an output verify.
    local per_variant=$(( style_count + 1 + ${#selected_families[@]} + 1 + 1 ))
    [ "$do_small_caps" = true ] && per_variant=$((per_variant + 1))
    [ "$do_onum" = true ] && per_variant=$((per_variant + 1))
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        per_variant=$((per_variant + 1))
    fi
    PROGRESS_TOTAL=$(( per_variant * 2 ))
    [ "$PSF_SKIP" != true ] && PROGRESS_TOTAL=$(( PROGRESS_TOTAL + style_count ))
    [ "$do_woff2" = true ] && PROGRESS_TOTAL=$(( PROGRESS_TOTAL + 2 ))
    [ "$do_nerd" = true ] && PROGRESS_TOTAL=$(( PROGRESS_TOTAL + ${#selected_families[@]} ))
    if [ "$do_nerd" = true ] && [ "$do_woff2" = true ] && [ "$do_woff2_nerd" = true ]; then
        PROGRESS_TOTAL=$(( PROGRESS_TOTAL + 1 ))
    fi
    PROGRESS_DONE=0

    echo

    # Proportional variant — base name (quanta-strike-N), no Nerd pass.
    if ! build_variant "proportional ($PROP_TYPE, $gap_desc)" "$BUILD_DIR/tmp/src" \
            "$prop_group" "$PROP_TYPE" "$prop_flag" "" "${selected_families[@]}"; then
        exit 1
    fi

    # Mono variant — "-mono" family suffix; this is the one that gets Nerd icons.
    if ! build_variant "mono" "$BUILD_DIR/tmp/src-mono" \
            "$mono_group" "monospace" "" "-mono" "${selected_families[@]}"; then
        exit 1
    fi

    # Console PSF (mono cell bitmaps, trimmed to the chosen charset). Independent
    # of the TTF pipeline — reads src/ directly. Skipped via --no-psf / prompt.
    echo
    if ! run_png_to_psf "${selected_families[@]}"; then
        exit 1
    fi

    # Base WOFF2 first (mirrors the whole build/ttf tree → both variants at once,
    # pruning any -nerd groups) so normal web fonts are ready before the slow pass.
    if [ "$do_woff2" = true ]; then
        echo
        print_header "Web fonts ${DIM}→ $BUILD_DIR/woff2${NC}"
        PROGRESS_PHASE="web"
        run_woff2 false
        # Drop-in CSS for the web fonts. Cheap, so it always follows a WOFF2 run.
        run_generate_css
        print_success "WOFF2 + CSS written"
    fi

    # Nerd Fonts LAST, and for the MONO variant only. The mono family names carry
    # the "-mono" suffix, so the generator filters on those and writes into
    # build/ttf/quanta-strike-mono-nerd.
    if [ "$do_nerd" = true ]; then
        local mono_families=()
        for fam in "${selected_families[@]}"; do mono_families+=("${fam}-mono"); done
        TTF_GROUP_DIR="$mono_group"
        echo
        run_nerd_fonts_generator "${mono_families[@]}"
        if [ "$do_woff2" = true ] && [ "$do_woff2_nerd" = true ]; then
            PROGRESS_PHASE="web"
            run_woff2 true
        fi
    fi

    local processed_count=${#selected_families[@]}

    # ─── Version: persist what this build stamped, now that it succeeded ───────
    write_project_version

    # ─── Licence: must ship with the fonts (do this after every output exists) ──
    run_copy_license

    # ─── Clean up the staging dir — only png-to-ttf/metadata needed it ─────────
    if [ "$KEEP_TMP" = true ]; then
        print_line "  ${DIM}kept staging dir $BUILD_DIR/tmp (--keep-tmp)${NC}"
    else
        rm -rf "$BUILD_DIR/tmp"
    fi

    # ─── Summary ──────────────────────────────────────────────────────
    # The bar is done; take its line back before printing the final block.
    PROGRESS_TOTAL=0
    bar_clear

    echo
    echo -e "${GREEN}${BOLD}  Done${NC}  ${DIM}version $(read_project_version)${NC}"
    echo -e "${DIM}  ${RULE}${NC}"

    local out_lines=()
    out_lines+=("proportional|$processed_count strikes ($PROP_TYPE, $gap_desc) → $prop_group")
    out_lines+=("mono|$processed_count strikes → $mono_group")
    if [ "$do_nerd" = true ]; then
        out_lines+=("nerd|mono only → ${mono_group}-nerd")
    fi
    if [ "$do_woff2" = true ]; then
        local woff_note="both variants → $BUILD_DIR/woff2"
        [ "$do_woff2_nerd" = true ] && woff_note="$woff_note (incl. nerd)"
        out_lines+=("woff2|$woff_note")
        out_lines+=("css|$BUILD_DIR/woff2/quanta-strike.css")
    fi
    if [ "$PSF_SKIP" != true ] && [ -n "$PSF_CHARSET" ]; then
        local psf_note="$PSF_CHARSET"
        [ "$PSF_SCALE" != "1" ] && psf_note="$psf_note ×$PSF_SCALE"
        out_lines+=("psf|$psf_note → $PSF_DIR")
    fi

    local ol
    for ol in "${out_lines[@]}"; do
        printf '  %s%-13s%s %s\n' "$DIM" "${ol%%|*}" "$NC" "${ol#*|}"
    done

    local applied="em anchored to N×128"
    [ "$do_small_caps" = true ] && applied="$applied · small caps"
    [ "$do_onum" = true ] && applied="$applied · old-style figures"
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        applied="$applied · scaled ×$scale_factor"
    fi
    [ -f "$LICENSE_FILE" ] && applied="$applied · OFL.txt shipped"
    echo -e "  ${DIM}$applied${NC}"
    echo
}

show_help() {
    echo "Interactive Font Generator"
    echo
    echo "Usage: $0 [--verbose|-v] [--defaults|-y] [--spacing V] [--nerd-fonts] [--psf] [--charset PATH] [--psf-scale N] [--no-psf] [--keep-tmp]"
    echo
    echo "Options:"
    echo "  --verbose, -v    Print every sub-command's output as it runs. Without"
    echo "                   it the build shows a single progress line naming the"
    echo "                   strike being worked on, and only prints a step's"
    echo "                   output if that step FAILS. Piped output (not a TTY)"
    echo "                   never animates — one plain line per step instead."
    echo "  --defaults, -y   Non-interactive: take the DEFAULT answer to every"
    echo "                   prompt and don't ask. The defaults are not all \"yes\":"
    echo "                   version = keep, Nerd Fonts = no, console PSF = no."
    echo "                   That is why this isn't called --yes. Builds ALL"
    echo "                   strikes (both variants)."
    echo "  --spacing V      Force the proportional inter-glyph gap for ALL strikes:"
    echo "                   a pixel count, or 'auto' (scale with size: 1px N<11,"
    echo "                   2px 11–18, 3px N>18). Skips the prompt. If not given,"
    echo "                   each strike's JSON \`spacing\` key decides (else auto)."
    echo "                   Mono is unaffected."
    echo "  --nerd-fonts     Opt in to Nerd Font generation (mono variant only, the"
    echo "                   slow step). Aliases: --nerd. Off unless given."
    echo "  --psf            Opt in to console PSF fonts (Linux/Raspberry Pi fbcon)."
    echo "                   Aliases: --psf-fonts. Off unless given. The main"
    echo "                   release skips these. Use for local/clone builds, or"
    echo "                   an optional separate release asset. Also implied by"
    echo "                   --charset / --psf-scale."
    echo "  --charset PATH   Console PSF glyph allowlist JSON. Implies --psf. Default"
    echo "                   charset is console-charset.json. Local variants like"
    echo "                   console-charset-hr.json stay untracked."
    echo "  --psf-scale N    Integer nearest-neighbor upscale for console PSF only"
    echo "                   (default 1). Implies --psf. Separate from the TTF"
    echo "                   'Scale factor on top'. Example: --psf-scale 2 turns"
    echo "                   7×14 into 14×28 (file suffix -2x)."
    echo "  --no-psf         Skip console PSF fonts entirely (wins over --psf)."
    echo "  --keep-tmp       Keep the build/tmp staging dir after the build (for"
    echo "                   inspecting the intermediate TTFs). Removed by default."
    echo "  --help, -h       Show this help"
    echo
    echo "  e.g. $0 -y --spacing 2 --nerd-fonts   # release-style: no PSF"
    echo "       $0 -y --psf --charset console-charset-hr.json --psf-scale 2"
    echo
    echo "Flow (the prompts are grouped into these five):"
    echo "  1. Strikes      which sizes/weights to build (space toggles, a = all)"
    echo "  2. Release      version bump + font metadata (both variants)"
    echo "  3. Typography   small caps, old-style figures, spacing, scale"
    echo "  4. Outputs      Nerd Fonts, WOFF2 + CSS, console PSF"
    echo "  5. Review       every answer on one screen, then confirm"
    echo
    echo "  The build then makes EACH strike twice — a proportional variant"
    echo "  (quanta-strike-N) and a mono variant (quanta-strike-N-mono) — via"
    echo "  scripts/png-to-ttf.py into build/tmp; then console PSF if opted in;"
    echo "  then base WOFF2, then Nerd Fonts (mono variant only) last."
    echo
    echo "Requirements:"
    echo "  - scripts/png-to-ttf.py (builds each strike's TTF from its PNG + JSON)"
    echo "  - scripts/png-to-psf.py + console-charset.json (optional console PSF fonts)"
    echo "  - scripts/font-metadata-patcher.py"
    echo "  - FontForge with Python bindings (brew install fontforge)"
    echo "  - scripts/generate-nerd-fonts script (for nerd font variants)"
    echo "  - scripts/verify-pixel-grid.py (enforces em == N*128 / 1px-per-pixel invariant)"
    echo
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --defaults|-y|--yes|--non-interactive)
            NON_INTERACTIVE=true
            ;;
        --nerd-fonts|--nerd)
            NERD_FORCED=true
            ;;
        --psf|--psf-fonts)
            PSF_FORCED=true
            ;;
        --no-psf)
            PSF_SKIP=true
            ;;
        --charset)
            if [ $# -lt 2 ]; then
                print_error "--charset needs a path (e.g. --charset console-charset-hr.json)"
                exit 1
            fi
            PSF_CHARSET="$2"
            PSF_CHARSET_SET=true
            shift
            ;;
        --charset=*)
            PSF_CHARSET="${1#*=}"
            PSF_CHARSET_SET=true
            ;;
        --psf-scale)
            if [ $# -lt 2 ]; then
                print_error "--psf-scale needs an integer ≥ 1 (e.g. --psf-scale 2)"
                exit 1
            fi
            PSF_SCALE="$2"
            PSF_SCALE_SET=true
            shift
            ;;
        --psf-scale=*)
            PSF_SCALE="${1#*=}"
            PSF_SCALE_SET=true
            ;;
        --keep-tmp)
            KEEP_TMP=true
            ;;
        --spacing)
            if [ $# -lt 2 ]; then
                print_error "--spacing needs a value (e.g. --spacing 2)"
                exit 1
            fi
            PROP_GAP="$2"
            PROP_GAP_SET=true
            shift
            ;;
        --spacing=*)
            PROP_GAP="${1#*=}"
            PROP_GAP_SET=true
            ;;
        *)
            print_error "Unknown option: $1"
            echo
            show_help
            exit 1
            ;;
    esac
    shift
done

# Run main function
main
