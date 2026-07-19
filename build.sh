#!/bin/bash

# Interactive Font Generator
# Processes font families with metadata patcher and optionally generates nerd fonts

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Default directories
SRC_DIR="./src"
BUILD_DIR="./build"
TTF_DIR="$BUILD_DIR/ttf"
TTF_GROUP_DIR="$TTF_DIR/quanta-strike"

# Metadata defaults. When this file exists the build reads names/license/URLs
# from it and skips the questions; remove it to get the interactive prompts.
DEFAULTS_FILE="./default-metadata.json"

# The licence text. OFL requires it to be distributed WITH the fonts, so it gets
# copied into every output folder that holds fonts.
LICENSE_FILE="./OFL.txt"

# Staged sources. png-to-ttf.py builds each strike's TTF in here, mirroring the
# src/<family>/<style>/ layout the metadata patcher expects, so that src/ only
# ever holds the real sources (PNG + JSON) and never a build artifact.
# Lives under build/ — wiped at the start of every run, and already gitignored.
STAGE_DIR="$BUILD_DIR/tmp/src"

# Global variable to store metadata options
METADATA_OPTIONS=""

# The build always emits TWO variants per strike: a monospace one (PFM type
# always "monospace") and a proportional one. PROP_TYPE is the PFM family type
# for the proportional variant — "sans" or "serif". Set by get_metadata_options.
PROP_TYPE="sans"

# Proportional inter-glyph gap: the proportional advance is (ink-width + gap) ×
# 128. A pixel count, or "auto" (scale with strike size N: 1px N<11, 2px 11..18,
# 3px N>18). EMPTY = "let each strike decide" — png-to-ttf then reads the strike
# JSON's `spacing` key, falling back to "auto". Precedence: --spacing V (forces
# every strike, skips the prompt) > a "spacing" key in default-metadata.json >
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

# The staging dir ($BUILD_DIR/tmp) holds png-to-ttf's intermediate TTFs that the
# metadata patcher reads; nothing needs it once the build finishes, so it's
# removed at the end. --keep-tmp leaves it in place for inspecting a bad build.
KEEP_TMP=false

# Function to print colored output
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo -e "${CYAN}▶${NC} $1"
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

# Function to ask yes/no question
ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local response

    if [ "$default" = "y" ]; then
        printf "${YELLOW}?${NC} %s [Y/n]: " "$question"
    else
        printf "${YELLOW}?${NC} %s [y/N]: " "$question"
    fi

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
# The source is read from src/<family>/regular/ but STAGED under a folder named
# <family><suffix> — that folder name becomes the internal family name (the
# metadata patcher takes it from the folder), which is how the mono variant gets
# its "-mono" family. prop_flag is passed straight to png-to-ttf.py (empty, or
# "--proportional --prop-gap ...").
#
# A variant may have its OWN hand-drawn sheet: if a <family><suffix> pair exists
# (e.g. quanta-strike-14-mono.{png,json}) it is used for that variant; otherwise
# the variant falls back to the plain <family> source. So mono uses a dedicated
# mono sheet when present, and both variants share the plain source otherwise.
# Usage: run_png_to_ttf "<prop_flag>" "<suffix>" family1 family2 ...
run_png_to_ttf() {
    local prop_flag="$1"; shift
    local suffix="$1"; shift
    local families=("$@")

    print_info "Building source TTFs from PNG + JSON → ${DIM}$STAGE_DIR${NC}"

    rm -rf "$STAGE_DIR"

    local built=0
    local reused=0
    for family_name in "${families[@]}"; do
        local dir="$SRC_DIR/$family_name/regular"
        local stage="$STAGE_DIR/${family_name}${suffix}/regular"

        # Prefer a variant-specific sheet (<family><suffix>) when the suffix names
        # one and BOTH its png+json are present; otherwise use the plain source.
        local src_name="$family_name"
        if [ -n "$suffix" ] && [ -f "$dir/${family_name}${suffix}.json" ] && [ -f "$dir/${family_name}${suffix}.png" ]; then
            src_name="${family_name}${suffix}"
        fi
        local json="$dir/$src_name.json"
        local png="$dir/$src_name.png"
        # TTF fallback: the variant-specific one if we chose that source, else plain.
        local prebuilt="$dir/$src_name.ttf"
        [ -f "$prebuilt" ] || prebuilt="$dir/$family_name.ttf"

        mkdir -p "$stage"

        if [ -f "./png-to-ttf.py" ] && [ -f "$json" ] && [ -f "$png" ]; then
            if python3 png-to-ttf.py $prop_flag "$json" "$stage"; then
                [ "$src_name" != "$family_name" ] && print_info "  ${DIM}$family_name: using dedicated $src_name sheet${NC}"
                built=$((built + 1))
            else
                print_error "png-to-ttf failed for $family_name ($src_name)"
                return 1
            fi
        elif [ -f "$prebuilt" ]; then
            # No source pair (or no converter) — fall back to the checked-in TTF.
            cp "$prebuilt" "$stage/"
            print_warning "$family_name: no PNG+JSON source — using the existing TTF"
            reused=$((reused + 1))
        else
            print_error "$family_name: no PNG+JSON source and no TTF to fall back on"
            return 1
        fi
    done

    if [ $built -gt 0 ]; then
        print_success "Built $built source TTF(s) from PNG + JSON"
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

    print_info "Copying ${BOLD}$LICENSE_FILE${NC} next to the built fonts..."

    local copied=0
    local dir f has
    while IFS= read -r dir; do
        # Does this folder actually hold fonts? (An unmatched glob stays literal,
        # so -e is the reliable test — `ls a/*.ttf a/*.otf` would report failure
        # whenever ANY one of the patterns matches nothing.)
        has=0
        for f in "$dir"/*.ttf "$dir"/*.otf "$dir"/*.woff2; do
            if [ -e "$f" ]; then has=1; break; fi
        done
        if [ $has -eq 0 ]; then continue; fi

        cp "$LICENSE_FILE" "$dir/"
        copied=$((copied + 1))
        echo -e "  ${DIM}$dir/$(basename "$LICENSE_FILE")${NC}"
    done < <(find "$BUILD_DIR" -mindepth 1 -type d ! -path "$BUILD_DIR/tmp*" 2>/dev/null)

    if [ $copied -eq 0 ]; then
        print_warning "No font output folders found to place the licence in"
    else
        print_success "Licence copied into $copied folder(s)"
    fi
    return 0
}

# Function to run metadata patcher
run_metadata_patcher() {
    local family_name="$1"
    local extra_args="$2"

    print_info "Running metadata patcher for ${BOLD}$family_name${NC}..."

    # Reads the staged TTF that png-to-ttf.py just built, not src/.
    local cmd="python3 font-metadata-patcher.py --src '$STAGE_DIR' --family '$family_name' --output '$TTF_GROUP_DIR' --flat"

    if [ -n "$extra_args" ]; then
        cmd="$cmd $extra_args"
    fi

    echo -e "  ${DIM}$cmd${NC}"

    if eval "$cmd"; then
        print_success "Metadata patcher completed for $family_name"
        return 0
    else
        print_error "Metadata patcher failed for $family_name"
        return 1
    fi
}

# Function to run nerd fonts generator for selected families only
# Usage: run_nerd_fonts_generator family1 family2 ...
run_nerd_fonts_generator() {
    local families=("$@")

    print_info "Running Nerd Fonts generator for: ${BOLD}${families[*]}${NC}"

    if [ ! -f "./generate-nerd-fonts" ]; then
        print_error "generate-nerd-fonts script not found"
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

    local nerd_dir="${TTF_GROUP_DIR}-nerd"
    if "./generate-nerd-fonts" "$TTF_GROUP_DIR" "$nerd_dir" "${families[@]}"; then
        print_success "Nerd Fonts generator completed"
        return 0
    else
        print_error "Nerd Fonts generator failed"
        return 1
    fi
}

# Function to run small caps generator
run_small_caps() {
    local source="$1"
    local c2sc="$2"

    print_info "Running small caps..."

    local cmd="python3 add-small-caps.py --src '$TTF_GROUP_DIR' --source '$source'"
    if [ "$c2sc" != "true" ]; then
        cmd="$cmd --no-c2sc"
    fi

    if eval "$cmd"; then
        print_success "Small caps completed"
        return 0
    else
        print_error "Small caps failed"
        return 1
    fi
}

# Function to run old-style figures generator
run_old_style_figures() {
    local source="$1"

    print_info "Running old-style figures..."

    local cmd="python3 add-old-style-figures.py --src '$TTF_GROUP_DIR' --source '$source'"

    if eval "$cmd"; then
        print_success "Old-style figures completed"
        return 0
    else
        print_error "Old-style figures failed"
        return 1
    fi
}

# Function to convert the built TTFs to WOFF2 web fonts
run_woff2() {
    local include_nerd="$1"

    print_info "Converting to WOFF2..."

    local cmd="python3 convert-woff2.py '$TTF_DIR' '$BUILD_DIR/woff2'"
    if [ "$include_nerd" = "true" ]; then
        cmd="$cmd --include-nerd"
    fi

    if eval "$cmd"; then
        print_success "WOFF2 conversion completed"
        return 0
    else
        print_error "WOFF2 conversion failed"
        return 1
    fi
}

# Verify the pixel-grid invariant (em == N*128, glyphs on the 128 grid) for one
# or more targets. Refuses to continue if any strike would render a pixel that
# is not exactly 1.0000px at its native size.
# Usage: run_verify "label" target1 [target2 ...]
run_verify() {
    local label="$1"; shift
    local targets=("$@")

    if [ ! -f "./verify-pixel-grid.py" ]; then
        print_warning "verify-pixel-grid.py not found — skipping invariant check"
        return 0
    fi

    print_info "Verifying pixel-grid invariant ($label)..."

    if python3 verify-pixel-grid.py "${targets[@]}" 2>/dev/null; then
        print_success "Pixel-grid invariant holds ($label)"
        return 0
    else
        print_error "Pixel-grid invariant violated ($label) — a pixel would not be 1.0000px at native size"
        return 1
    fi
}

# Function to uniformly scale the whole family bigger while keeping the pixel
# size identical across strikes (picotype-style line metrics, one shared factor)
run_pixel_scale() {
    local scale="$1"

    if [ ! -f "./pixel-scale.py" ]; then
        print_error "pixel-scale.py not found"
        return 1
    fi

    print_info "Scaling family (pixel stays identical across strikes) at factor ${BOLD}$scale${NC}..."

    if python3 pixel-scale.py "$TTF_GROUP_DIR" --scale "$scale"; then
        print_success "Pixel-scale completed"
        return 0
    else
        print_error "Pixel-scale failed"
        return 1
    fi
}

# Function to anchor the em to N*128 (pixel-perfect) and set line metrics to the
# full ink extent, so accents drawn above the em (taller canvas) don't clip.
run_anchor_em() {
    if [ ! -f "./anchor-em.py" ]; then
        print_error "anchor-em.py not found"
        return 1
    fi

    print_info "Anchoring em to strike size (pixel-perfect) + line metrics for accent overshoot..."

    if python3 anchor-em.py "$TTF_GROUP_DIR"; then
        print_success "Anchor-em completed"
        return 0
    else
        print_error "Anchor-em failed"
        return 1
    fi
}

# Ask user to choose a small cap glyph source
ask_smcp_source() {
    echo "  Small cap source:" >&2
    echo "    1) phonetic  — Unicode small capitals (ᴀ ʙ ᴄ … ꞯ)" >&2
    echo "    2) lowercase — use lowercase glyphs" >&2
    echo "    3) capital   — use uppercase glyphs" >&2
    printf "${YELLOW}?${NC} Source [1/2/3] (default: 1): " >&2
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}1 (phonetic)${NC}" >&2
        echo "phonetic"
        return 0
    fi
    read -r response
    case "${response:-1}" in
        2) echo "lowercase" ;;
        3) echo "capital" ;;
        *) echo "phonetic" ;;
    esac
}

# Ask user to choose an old-style figure glyph source
ask_onum_source() {
    echo "  Old-style figure source:" >&2
    echo "    1) circled     — ⓿①②③④⑤⑥⑦⑧⑨" >&2
    echo "    2) superscript — ⁰¹²³⁴⁵⁶⁷⁸⁹" >&2
    echo "    3) subscript   — ₀₁₂₃₄₅₆₇₈₉" >&2
    echo "    4) lining      — same as regular digits" >&2
    printf "${YELLOW}?${NC} Source [1/2/3/4] (default: 1): " >&2
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}1 (circled)${NC}" >&2
        echo "circled"
        return 0
    fi
    read -r response
    case "${response:-1}" in
        2) echo "superscript" ;;
        3) echo "subscript" ;;
        4) echo "lining" ;;
        *) echo "circled" ;;
    esac
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

# Compute bumped version for a family based on VERSION_STRATEGY
# Usage: compute_version "picosans"  → prints --version flag or empty string
compute_version_flag() {
    local family="$1"
    local current_version
    current_version=$(get_family_version "$family")

    case "$VERSION_STRATEGY" in
        1|2|3)
            if [ -z "$current_version" ]; then
                return
            fi
            local major minor patch
            IFS='.' read -r major minor patch <<< "$current_version"
            major=${major:-0}
            minor=${minor:-0}
            patch=${patch:-0}
            local new_version=""
            case "$VERSION_STRATEGY" in
                1) new_version="$major.$minor.$((patch + 1))" ;;
                2) new_version="$major.$((minor + 1)).0" ;;
                3) new_version="$((major + 1)).0.0" ;;
            esac
            echo "--version '$new_version'"
            print_info "$family: $current_version → $new_version" >&2
            ;;
        4)
            if [ -n "$VERSION_CUSTOM" ]; then
                echo "--version '$VERSION_CUSTOM'"
            fi
            ;;
        *)
            # keep — no flag
            ;;
    esac
}

# Global version strategy (set by get_metadata_options)
VERSION_STRATEGY="5"
VERSION_CUSTOM=""

# Turn default-metadata.json into patcher flags (shell-quoted, one line).
metadata_flags_from_defaults() {
    python3 - "$DEFAULTS_FILE" <<'PY'
import json, shlex, sys

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
print(" ".join(shlex.quote(f) for f in flags))
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
    print(f"    {key:12s} {text}")
PY
}

# Ask for the version bump. Deliberately always asked, never taken from
# default-metadata.json: it's a per-release decision, not a project constant.
# Sets VERSION_STRATEGY / VERSION_CUSTOM; version computed per-family at build time.
ask_version() {
    echo
    print_header "Version"
    echo "    1) patch bump"
    echo "    2) minor bump"
    echo "    3) major bump"
    echo "    4) custom (same for all)"
    echo "    5) keep"
    printf "${YELLOW}?${NC} Version [1/2/3/4/5] (default: 5): "
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}5 (keep)${NC}"
        VERSION_STRATEGY="5"
        VERSION_CUSTOM=""
        return 0
    fi
    read -r ver_choice
    VERSION_STRATEGY="${ver_choice:-5}"
    VERSION_CUSTOM=""
    if [ "$VERSION_STRATEGY" = "4" ]; then
        printf "${YELLOW}?${NC} Version: "
        read -r VERSION_CUSTOM
    fi
}

# Gather metadata patcher options (stores in global METADATA_OPTIONS)
get_metadata_options() {
    local options=""

    # Defaults file present → take everything from it EXCEPT the version bump.
    if [ -f "$DEFAULTS_FILE" ]; then
        echo
        print_header "Metadata Options ${DIM}(from $DEFAULTS_FILE)${NC}"
        METADATA_OPTIONS=" $(metadata_flags_from_defaults)"
        PROP_TYPE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("prop-type") or "sans")' "$DEFAULTS_FILE")"
        # Only adopt a build-level spacing if the defaults file actually sets one;
        # otherwise leave it empty so each strike's JSON `spacing` key stays in charge.
        if [ "$PROP_GAP_SET" != true ]; then
            PROP_GAP="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["spacing"] if "spacing" in c else "")' "$DEFAULTS_FILE")"
        fi
        metadata_summary_from_defaults
        echo
        print_info "Proportional variant PFM type: ${BOLD}$PROP_TYPE${NC} (mono variant is always monospace)."
        print_info "Edit $DEFAULTS_FILE to change these (delete it to be asked instead)."

        ask_version
        return 0
    fi

    echo
    print_header "Metadata Options"

    if ask_yes_no "Use lowercase font names?" "y"; then
        options="$options --lowercase"
    fi

    # The build always emits a monospace variant AND a proportional variant, so
    # there is no "is it mono?" question — mono is always PFM type monospace.
    # Ask only what the proportional variant should be classified as.
    if ask_yes_no "Proportional variant: serif (instead of sans)?"; then
        PROP_TYPE="serif"
    else
        PROP_TYPE="sans"
    fi

    ask_version

    printf "${YELLOW}?${NC} Output extension (ttf/otf, enter to keep): "
    read_or_skip extension
    if [ -n "$extension" ]; then
        options="$options --extension '$extension'"
    fi

    printf "${YELLOW}?${NC} Designer URL (enter to skip): "
    read_or_skip designer_url
    if [ -n "$designer_url" ]; then
        options="$options --designerurl '$designer_url'"
    fi

    printf "${YELLOW}?${NC} License URL (enter to skip): "
    read_or_skip license_url
    if [ -n "$license_url" ]; then
        options="$options --licenseurl '$license_url'"
    fi

    printf "${YELLOW}?${NC} License/copyright text (enter to skip): "
    read_or_skip license_text
    if [ -n "$license_text" ]; then
        options="$options --license '$license_text'"
    fi

    if ask_yes_no "Enable debug logging?"; then
        options="$options --debug"
    fi

    METADATA_OPTIONS="$options"
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

    echo
    echo "════════════════════════════════════════════════════════════════"
    print_header "Variant: ${BOLD}$label${NC} → ${DIM}$group${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo

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
    echo
    if ! run_verify "source · $label" "${src_targets[@]}"; then
        print_error "Fix the source strike(s) above before building — aborting."
        return 1
    fi
    echo

    # 3. Metadata for each strike (into this variant's group dir). --type is
    #    appended last so it wins over anything the defaults might carry.
    local i sfam version_flag
    for i in "${!stage_families[@]}"; do
        sfam="${stage_families[$i]}"
        print_header "Metadata: $sfam"
        echo
        version_flag=$(compute_version_flag "$sfam")
        if ! run_metadata_patcher "$sfam" "$METADATA_OPTIONS --type $pfm_type $version_flag"; then
            return 1
        fi
        echo
    done

    # 4. Features on the base TTFs, then anchor + optional scale.
    if [ "$do_small_caps" = true ]; then
        run_small_caps "$smcp_source" "$smcp_c2sc"
        echo
    fi
    if [ "$do_onum" = true ]; then
        run_old_style_figures "$onum_source"
        echo
    fi

    if ! run_anchor_em; then return 1; fi
    echo
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        if ! run_pixel_scale "$scale_factor"; then return 1; fi
        echo
    fi

    # 5. Gate: the built strikes must still hold the pixel-grid invariant.
    if ! run_verify "build output · $label" "$TTF_GROUP_DIR"; then
        print_error "Built $label fonts broke the pixel-grid invariant — aborting."
        return 1
    fi
    echo
    return 0
}

# Main function
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  Interactive Font Generator                  ║"
    echo "║          Metadata Patcher + Nerd Fonts Generator             ║"
    echo "║                       quanta-strike                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Check if source directory exists
    if [ ! -d "$SRC_DIR" ]; then
        print_error "Source directory not found: $SRC_DIR"
        exit 1
    fi

    # Check if font-metadata-patcher.py exists
    if [ ! -f "font-metadata-patcher.py" ]; then
        print_error "font-metadata-patcher.py not found in current directory"
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

    # ─── Step 1: Select font families ─────────────────────────────────
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
    print_info "Selected: ${selected_families[*]}"
    print_info "Each strike is built TWICE: a ${BOLD}proportional${NC} variant (quanta-strike-N) and a ${BOLD}mono${NC} variant (quanta-strike-N-mono)."

    # NB: the actual source build (png-to-ttf) + source guard now happen once per
    # variant inside build_variant (Step 4), since each variant trims widths
    # differently. Here we only gather the shared options.

    # ─── Step 2: Configure metadata options ───────────────────────────
    get_metadata_options
    echo
    print_info "Options:${DIM}$METADATA_OPTIONS${NC}"

    # ─── Step 3: Optional features ───────────────────────────────────
    echo
    print_header "Optional Features"

    local do_small_caps=false
    local smcp_source="phonetic"
    local smcp_c2sc=true
    if ask_yes_no "Add small caps (smcp/c2sc)?" "y"; then
        do_small_caps=true
        smcp_source=$(ask_smcp_source)
        if ! ask_yes_no "Also add c2sc (uppercase → small caps)?" "y"; then
            smcp_c2sc=false
        fi
    fi

    local do_onum=false
    local onum_source="circled"
    if ask_yes_no "Add old-style figures (onum)?" "y"; then
        do_onum=true
        onum_source=$(ask_onum_source)
    fi

    # Nerd Fonts are for coding/TUIs, which is exactly where the mono variant is
    # used — so they're generated for the MONO variant only (and always last,
    # since patching is the slow part). The proportional variant gets none. They
    # are OPT-IN: --nerd-fonts forces them on; otherwise the prompt defaults to no.
    local do_nerd=false
    if [ "$NERD_FORCED" = true ]; then
        do_nerd=true
        print_info "Nerd Fonts: enabled via --nerd-fonts (mono variant only)."
    elif ask_yes_no "Generate nerd font variants (mono variant only)?" "n"; then
        do_nerd=true
    fi

    # Vertical sizing: always anchor to pixel-perfect (em = N*128), then an
    # optional uniform scale-up on top. Default scale 1 = leave it pixel-perfect.
    echo
    print_header "Vertical sizing"
    print_info "Every strike is anchored to em = N×128 (pixel-perfect, 1px at native)."
    printf "${YELLOW}?${NC} Scale factor on top [default 1 = leave pixel-perfect]: "
    local sf=""
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${DIM}1${NC}"
    else
        read -r sf
    fi
    local scale_factor="${sf:-1}"

    # Proportional inter-glyph spacing. --spacing (or a defaults-file value)
    # already pinned it if set; otherwise ask. Blank = let each strike's JSON
    # `spacing` key decide (falling back to auto). A value here forces every
    # strike. The mono variant is unaffected either way.
    if [ "$PROP_GAP_SET" != true ] && [ -z "$PROP_GAP" ]; then
        echo
        print_header "Proportional spacing"
        print_info "Gap between glyphs in the proportional variant (mono is unaffected)."
        print_info "${DIM}blank = per-strike JSON \`spacing\` key, else auto (1/2/3px by size).${NC}"
        print_info "${DIM}or force all strikes: type a pixel count, or 'auto'.${NC}"
        printf "${YELLOW}?${NC} Spacing [blank = per-strike/auto]: "
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

    local do_woff2=false
    local do_woff2_nerd=false
    if ask_yes_no "Also export WOFF2 web fonts?" "y"; then
        do_woff2=true
        if [ "$do_nerd" = true ]; then
            if ask_yes_no "Include Nerd Font variants in WOFF2 (large files)?"; then
                do_woff2_nerd=true
            fi
        fi
    fi

    # ─── Step 4: Process each variant, then WOFF2, then Nerd (mono, slow) last ─
    echo
    echo "────────────────────────────────────────────────────────────────"

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

    echo "────────────────────────────────────────────────────────────────"
    echo

    # Base WOFF2 first (mirrors the whole build/ttf tree → both variants at once,
    # pruning any -nerd groups) so normal web fonts are ready before the slow pass.
    if [ "$do_woff2" = true ]; then
        run_woff2 false
        echo
    fi

    # Nerd Fonts LAST, and for the MONO variant only. The mono family names carry
    # the "-mono" suffix, so the generator filters on those and writes into
    # build/ttf/quanta-strike-mono-nerd.
    if [ "$do_nerd" = true ]; then
        local mono_families=()
        for fam in "${selected_families[@]}"; do mono_families+=("${fam}-mono"); done
        TTF_GROUP_DIR="$mono_group"
        run_nerd_fonts_generator "${mono_families[@]}"
        echo
        if [ "$do_woff2" = true ] && [ "$do_woff2_nerd" = true ]; then
            run_woff2 true
            echo
        fi
    fi

    local processed_count=${#selected_families[@]}

    # ─── Licence: must ship with the fonts (do this after every output exists) ──
    run_copy_license
    echo

    # ─── Clean up the staging dir — only png-to-ttf/metadata needed it ─────────
    if [ "$KEEP_TMP" = true ]; then
        print_info "Keeping staging dir ${DIM}$BUILD_DIR/tmp${NC} (--keep-tmp)."
    else
        rm -rf "$BUILD_DIR/tmp"
        print_info "Removed staging dir ${DIM}$BUILD_DIR/tmp${NC} (use --keep-tmp to keep it)."
    fi
    echo

    # ─── Summary ──────────────────────────────────────────────────────
    echo
    print_header "Done!"
    print_success "Built $processed_count strike(s) × 2 variants:"
    print_success "  proportional ($PROP_TYPE, $gap_desc) → $prop_group"
    print_success "  mono → $mono_group"
    [ "$do_small_caps" = true ] && print_success "Added small caps (smcp/c2sc) to both variants"
    [ "$do_onum" = true ] && print_success "Added old-style figures (onum) to both variants"
    print_success "Anchored em to strike size (pixel-perfect, accent overshoot handled)"
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        print_success "Scaled family by ×$scale_factor on top (pixel identical across strikes)"
    fi
    [ "$do_woff2" = true ] && print_success "Exported WOFF2 web fonts (both variants)"
    [ "$do_nerd" = true ] && print_success "Generated Nerd Font variants (mono only): ${selected_families[*]}"
    [ "$do_woff2_nerd" = true ] && print_success "Exported Nerd Font WOFF2 variants"
    [ -f "$LICENSE_FILE" ] && print_success "Shipped $LICENSE_FILE with the fonts (required by the OFL)"

    echo
    print_info "Output: $BUILD_DIR/"
}

show_help() {
    echo "Interactive Font Generator"
    echo
    echo "Usage: $0 [--defaults|-y] [--spacing V] [--nerd-fonts] [--keep-tmp]"
    echo
    echo "Options:"
    echo "  --defaults, -y   Non-interactive: take the DEFAULT answer to every"
    echo "                   prompt and don't ask. Note the defaults are not all"
    echo "                   \"yes\" — version = keep, Nerd Fonts = no — which is"
    echo "                   why this isn't --yes. Builds ALL strikes (both variants)."
    echo "  --spacing V      Force the proportional inter-glyph gap for ALL strikes:"
    echo "                   a pixel count, or 'auto' (scale with size: 1px N<11,"
    echo "                   2px 11–18, 3px N>18). Skips the prompt. If not given,"
    echo "                   each strike's JSON \`spacing\` key decides (else auto)."
    echo "                   Mono is unaffected."
    echo "  --nerd-fonts     Opt in to Nerd Font generation (mono variant only, the"
    echo "                   slow step). Aliases: --nerd. Off unless given."
    echo "  --keep-tmp       Keep the build/tmp staging dir after the build (for"
    echo "                   inspecting the intermediate TTFs). Removed by default."
    echo "  --help, -h       Show this help"
    echo
    echo "  e.g. $0 -y --spacing 2 --nerd-fonts   # non-interactive, 2px gap, with Nerd"
    echo
    echo "Flow:"
    echo "  1. Select font families (space to toggle, a to select all)"
    echo "  2. Configure metadata options (applied to both variants)"
    echo "  3. Choose optional features (small caps, old-style figures, nerd fonts, WOFF2)"
    echo "  4. Build EACH strike twice — a proportional variant (quanta-strike-N)"
    echo "     and a mono variant (quanta-strike-N-mono) — via png-to-ttf.py into"
    echo "     build/tmp; then base WOFF2, then Nerd Fonts (mono variant only) last"
    echo
    echo "Requirements:"
    echo "  - png-to-ttf.py (builds each strike's TTF from its PNG + JSON)"
    echo "  - font-metadata-patcher.py in current directory"
    echo "  - FontForge with Python bindings (brew install fontforge)"
    echo "  - generate-nerd-fonts script (for nerd font variants)"
    echo "  - verify-pixel-grid.py (enforces em == N*128 / 1px-per-pixel invariant)"
    echo
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --defaults|-y|--yes|--non-interactive)
            NON_INTERACTIVE=true
            ;;
        --nerd-fonts|--nerd)
            NERD_FORCED=true
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
