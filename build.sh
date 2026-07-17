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

# Staged sources. png-to-ttf.py builds each strike's TTF in here, mirroring the
# src/<family>/<style>/ layout the metadata patcher expects, so that src/ only
# ever holds the real sources (PNG + JSON) and never a build artifact.
# Lives under build/ — wiped at the start of every run, and already gitignored.
STAGE_DIR="$BUILD_DIR/tmp/src"

# Global variable to store metadata options
METADATA_OPTIONS=""

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

    read -r response
    response=${response:-$default}

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

# Build each strike's TTF from its yal source (PNG + JSON) — the step that used
# to be done by hand in the yal web tool. The TTF is a build artifact, so it goes
# to $STAGE_DIR rather than back into src/; everything downstream reads it from
# there. A strike with no PNG+JSON falls back to a prebuilt TTF in src/, which is
# copied into the staging area so the patcher sees one uniform layout.
# Usage: run_png_to_ttf family1 family2 ...
run_png_to_ttf() {
    local families=("$@")

    print_info "Building source TTFs from PNG + JSON → ${DIM}$STAGE_DIR${NC}"

    rm -rf "$STAGE_DIR"

    local built=0
    local reused=0
    for family_name in "${families[@]}"; do
        local json="$SRC_DIR/$family_name/regular/$family_name.json"
        local png="$SRC_DIR/$family_name/regular/$family_name.png"
        local prebuilt="$SRC_DIR/$family_name/regular/$family_name.ttf"
        local stage="$STAGE_DIR/$family_name/regular"

        mkdir -p "$stage"

        if [ -f "./png-to-ttf.py" ] && [ -f "$json" ] && [ -f "$png" ]; then
            if python3 png-to-ttf.py "$json" "$stage"; then
                built=$((built + 1))
            else
                print_error "png-to-ttf failed for $family_name"
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

# Gather metadata patcher options (stores in global METADATA_OPTIONS)
get_metadata_options() {
    local options=""

    echo
    print_header "Metadata Options"

    if ask_yes_no "Use lowercase font names?" "y"; then
        options="$options --lowercase"
    fi

    if ask_yes_no "Set font type to monospace?" "y"; then
        options="$options --type monospace"
    elif ask_yes_no "Set font type to sans serif?"; then
        options="$options --type sans"
    elif ask_yes_no "Set font type to serif?"; then
        options="$options --type serif"
    fi

    # Version bump strategy — actual version computed per-family at build time
    echo
    print_header "Version"
    echo "    1) patch bump"
    echo "    2) minor bump"
    echo "    3) major bump"
    echo "    4) custom (same for all)"
    echo "    5) keep"
    printf "${YELLOW}?${NC} Version [1/2/3/4/5] (default: 5): "
    read -r ver_choice
    VERSION_STRATEGY="${ver_choice:-5}"
    VERSION_CUSTOM=""
    if [ "$VERSION_STRATEGY" = "4" ]; then
        printf "${YELLOW}?${NC} Version: "
        read -r VERSION_CUSTOM
    fi

    printf "${YELLOW}?${NC} Output extension (ttf/otf, enter to keep): "
    read -r extension
    if [ -n "$extension" ]; then
        options="$options --extension '$extension'"
    fi

    printf "${YELLOW}?${NC} Designer URL (enter to skip): "
    read -r designer_url
    if [ -n "$designer_url" ]; then
        options="$options --designerurl '$designer_url'"
    fi

    printf "${YELLOW}?${NC} License URL (enter to skip): "
    read -r license_url
    if [ -n "$license_url" ]; then
        options="$options --licenseurl '$license_url'"
    fi

    printf "${YELLOW}?${NC} License/copyright text (enter to skip): "
    read -r license_text
    if [ -n "$license_text" ]; then
        options="$options --license '$license_text'"
    fi

    if ask_yes_no "Enable debug logging?"; then
        options="$options --debug"
    fi

    METADATA_OPTIONS="$options"
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

    # ─── Step 1a: Build source TTFs from the yal PNG + JSON sources ────
    echo
    if ! run_png_to_ttf "${selected_families[@]}"; then
        print_error "Could not build source TTFs — aborting."
        exit 1
    fi

    # ─── Step 1b: Fail fast — source strikes must be on the pixel grid ─
    # Checks the freshly staged TTFs, i.e. what the build will actually consume.
    local src_targets=()
    for fam in "${selected_families[@]}"; do
        src_targets+=("$STAGE_DIR/$fam")
    done
    echo
    if ! run_verify "source" "${src_targets[@]}"; then
        print_error "Fix the source strike(s) above before building — aborting."
        exit 1
    fi

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

    local do_nerd=false
    if ask_yes_no "Generate nerd font variants?" "y"; then
        do_nerd=true
    fi

    # Vertical sizing: always anchor to pixel-perfect (em = N*128), then an
    # optional uniform scale-up on top. Default scale 1 = leave it pixel-perfect.
    echo
    print_header "Vertical sizing"
    print_info "Every strike is anchored to em = N×128 (pixel-perfect, 1px at native)."
    printf "${YELLOW}?${NC} Scale factor on top [default 1 = leave pixel-perfect]: "
    read -r sf
    local scale_factor="${sf:-1}"

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

    # ─── Step 4: Process ──────────────────────────────────────────────
    echo
    echo "────────────────────────────────────────────────────────────────"
    echo

    local processed_count=0

    # ─── Step 4a: Metadata for each selected strike (into the shared group dir) ──
    for family_name in "${selected_families[@]}"; do
        print_header "Metadata: $family_name"
        echo

        # Compute per-family version flag
        local version_flag=""
        version_flag=$(compute_version_flag "$family_name")

        if run_metadata_patcher "$family_name" "$METADATA_OPTIONS $version_flag"; then
            ((processed_count++))
        fi
        echo
    done

    if [ $processed_count -eq 0 ]; then
        print_error "No fonts were built."
        exit 1
    fi

    echo "────────────────────────────────────────────────────────────────"
    echo

    # ─── Step 4b: Features on base TTFs, then WOFF2, then Nerd (slow) last ──────
    if [ "$do_small_caps" = true ]; then
        run_small_caps "$smcp_source" "$smcp_c2sc"
        echo
    fi
    if [ "$do_onum" = true ]; then
        run_old_style_figures "$onum_source"
        echo
    fi

    # Always anchor to pixel-perfect first (before the gate/WOFF2/Nerd)...
    run_anchor_em
    echo
    # ...then optionally scale the whole family up on top (1 = no-op, stays pixel-perfect).
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        run_pixel_scale "$scale_factor"
        echo
    fi

    # ─── Gate: built base TTFs must still hold the pixel-grid invariant ──
    # (metadata + features must not have disturbed em or pixel alignment)
    if ! run_verify "build output" "$TTF_GROUP_DIR"; then
        print_error "Built fonts broke the pixel-grid invariant — refusing to emit WOFF2/Nerd."
        exit 1
    fi
    echo

    # Base WOFF2 first so normal web fonts are ready before the slow Nerd pass
    if [ "$do_woff2" = true ]; then
        run_woff2 false
        echo
    fi

    if [ "$do_nerd" = true ]; then
        run_nerd_fonts_generator "${selected_families[@]}"
        echo
        if [ "$do_woff2" = true ] && [ "$do_woff2_nerd" = true ]; then
            run_woff2 true
            echo
        fi
    fi

    # ─── Summary ──────────────────────────────────────────────────────
    echo
    print_header "Done!"
    print_success "Built $processed_count strike(s) into $TTF_GROUP_DIR"
    [ "$do_small_caps" = true ] && print_success "Added small caps (smcp/c2sc)"
    [ "$do_onum" = true ] && print_success "Added old-style figures (onum)"
    print_success "Anchored em to strike size (pixel-perfect, accent overshoot handled)"
    if [ "$scale_factor" != "1" ] && [ "$scale_factor" != "1.0" ]; then
        print_success "Scaled family by ×$scale_factor on top (pixel identical across strikes)"
    fi
    [ "$do_woff2" = true ] && print_success "Exported WOFF2 web fonts"
    [ "$do_nerd" = true ] && print_success "Generated Nerd Font variants for: ${selected_families[*]}"
    [ "$do_woff2_nerd" = true ] && print_success "Exported Nerd Font WOFF2 variants"

    echo
    print_info "Output: $BUILD_DIR/"
}

# Check for help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Interactive Font Generator"
    echo
    echo "Usage: $0"
    echo
    echo "Flow:"
    echo "  1. Select font families (space to toggle, a to select all)"
    echo "  1a. Build source TTFs from each strike's PNG + JSON into build/tmp/src"
    echo "      (png-to-ttf.py — src/ keeps only the PNG + JSON)"
    echo "  2. Configure metadata options (applied to all selected)"
    echo "  3. Choose optional features (small caps, old-style figures, nerd fonts, WOFF2)"
    echo "  4. Build base TTF (+ WOFF2), then Nerd Fonts last (selected families only)"
    echo
    echo "Requirements:"
    echo "  - png-to-ttf.py (builds each strike's TTF from its PNG + JSON)"
    echo "  - font-metadata-patcher.py in current directory"
    echo "  - FontForge with Python bindings (brew install fontforge)"
    echo "  - generate-nerd-fonts script (for nerd font variants)"
    echo "  - verify-pixel-grid.py (enforces em == N*128 / 1px-per-pixel invariant)"
    echo
    exit 0
fi

# Run main function
main
