#!/bin/bash
set -eEo pipefail

# Omarchy Configuration Setup Script
# This script sets up omarchy configuration repositories in ~/.config/

# Color codes for output
RED=1
GREEN=2
YELLOW=3
CYAN=6

# ============================================================================
# Cancellation Handler
# ============================================================================

cleanup() {
    echo
    if command -v gum &> /dev/null; then
        gum style --foreground $RED --padding "1 0 1 0" "Setup cancelled by user"
    else
        echo -e "\e[31mSetup cancelled by user\e[0m"
    fi
    exit 130
}

trap cleanup SIGINT SIGTERM

# Repository definitions
declare -A REPOS=(
    ["hypr"]="timmo001/omarchy-hypr"
    ["waybar"]="timmo001/omarchy-waybar"
    ["ghostty"]="timmo001/omarchy-ghostty"
    ["uwsm"]="timmo001/omarchy-uwsm"
)
DOTFILES_REPO="timmo001/dotfiles"
DOTFILES_BRANCH="arch-omarchy"

# Directories
CONFIG_DIR="$HOME/.config"
BACKUP_DIR="$CONFIG_DIR/omarchy-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ============================================================================
# Helper Functions
# ============================================================================

abort() {
    gum style --foreground $RED --padding "1 0 1 0" "Error: $1"
    exit 1
}

info() {
    gum style --foreground $GREEN --padding "1 0 0 0" "$1"
}

progress() {
    gum style --foreground $YELLOW --padding "1 0 0 0" "$1"
}

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
    progress "Checking prerequisites..."

    # Check for gum
    if ! command -v gum &> /dev/null; then
        abort "gum is required but not installed. Install with: sudo pacman -S gum"
    fi

    # Check for gh CLI
    if ! command -v gh &> /dev/null; then
        abort "GitHub CLI (gh) is required but not installed. Install with: sudo pacman -S github-cli"
    fi

    # Check gh authentication
    if ! gh auth status &> /dev/null; then
        abort "GitHub CLI is not authenticated. Run: gh auth login"
    fi

    info "✓ All prerequisites satisfied"
}

# ============================================================================
# Branch Discovery
# ============================================================================

get_repo_branches() {
    local repo="$1"
    local result
    set +e
    result=$(gh api "repos/$repo/branches" --jq '.[].name' 2>/dev/null)
    local exit_code=$?
    set -e

    # If gh command was interrupted (exit code 130), return that code
    if [[ $exit_code -eq 130 ]]; then
        return 130
    fi

    echo "$result"
}

discover_branches() {
    progress "Discovering available branches..." >&2

    # Use omarchy-hypr as source of truth
    local hypr_branches
    set +e
    hypr_branches=$(get_repo_branches "timmo001/omarchy-hypr")
    local branches_exit_code=$?
    set -e

    if [[ $branches_exit_code -eq 130 ]]; then
        return 130
    fi

    if [[ -z "$hypr_branches" ]]; then
        abort "Failed to fetch branches from omarchy-hypr repository"
    fi

    echo "$hypr_branches"
}

# ============================================================================
# User Prompts
# ============================================================================

prompt_branch_selection() {
    local branches="$1"

    gum style --foreground $CYAN --padding "1 0 0 0" "Select your system configuration:" >&2

    local selected_branch
    # Temporarily remove trap and disable errexit to let gum handle Ctrl+C naturally
    trap - SIGINT SIGTERM
    set +e
    selected_branch=$(echo "$branches" | gum choose --header "Available branches")
    local exit_code=$?
    set -e
    trap cleanup SIGINT SIGTERM

    if [[ $exit_code -eq 130 ]]; then
        cleanup
    elif [[ $exit_code -ne 0 || -z "$selected_branch" ]]; then
        abort "No branch selected"
    fi

    echo "$selected_branch"
}

# ============================================================================
# Backup Functions
# ============================================================================

backup_if_exists() {
    local dir_name="$1"
    local target_dir="$CONFIG_DIR/$dir_name"

    if [[ -d "$target_dir" ]]; then
        progress "Backing up existing $dir_name..."

        mkdir -p "$BACKUP_DIR"
        local backup_path="$BACKUP_DIR/${dir_name}-${TIMESTAMP}"

        mv "$target_dir" "$backup_path"
        info "✓ Backed up to $backup_path"
        echo "$backup_path"
    fi
}

# ============================================================================
# Repository Management
# ============================================================================

check_if_correct_repo() {
    local target_dir="$1"
    local expected_repo="$2"

    if [[ ! -d "$target_dir/.git" ]]; then
        return 1
    fi

    local remote_url=$(cd "$target_dir" && git remote get-url origin 2>/dev/null || echo "")

    # Match both HTTPS and SSH URLs
    if [[ "$remote_url" == *"$expected_repo"* ]]; then
        return 0
    else
        return 1
    fi
}

clone_or_update_repo() {
    local dir_name="$1"
    local repo="$2"
    local branch="$3"
    local target_dir="$CONFIG_DIR/$dir_name"

    progress "Processing $dir_name..."

    if [[ -d "$target_dir" ]]; then
        # Directory exists - check if it's the correct GitHub repo
        if check_if_correct_repo "$target_dir" "$repo"; then
            # Correct GitHub repo exists - check if clean and pull
            cd "$target_dir"

            if [[ -z $(git status --porcelain) ]]; then
                # Working directory is clean, pull automatically with rebase
                git pull --rebase

                # Check if branch is clean after pull
                if [[ -z $(git status --porcelain) ]]; then
                    info "✓ Updated $dir_name"
                else
                    gum style --foreground $RED "✗ $dir_name has conflicts after pull - please resolve manually"
                fi
            else
                # Working directory has changes, skip pull
                gum style --foreground $YELLOW "⚠ Skipped $dir_name (uncommitted changes)"
            fi
        else
            # Not a GitHub repo or wrong repo - backup and clone fresh
            local backup_path=$(backup_if_exists "$dir_name")
            gh repo clone "$repo" "$target_dir"
            info "✓ Cloned $repo to $dir_name (old version backed up)"
        fi
    else
        # Directory doesn't exist - clone fresh
        gh repo clone "$repo" "$target_dir"
        info "✓ Cloned $repo to $dir_name"
    fi

    # Checkout branch if specified and exists
    if [[ -n "$branch" && -d "$target_dir/.git" ]]; then
        cd "$target_dir"

        # Check if branch exists in this repo
        if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
            git fetch origin "$branch" 2>/dev/null || true
            git checkout "$branch" 2>/dev/null || true
            info "✓ Checked out branch: $branch"
        else
            info "✓ Branch '$branch' not available in $dir_name, using default branch"
        fi
    fi
}

# ============================================================================
# Main Setup Process
# ============================================================================

main() {
    clear

    gum style \
        --foreground $GREEN \
        --border double \
        --padding "1 2" \
        --margin "1 0" \
        "Omarchy Configuration Setup" \
        "" \
        "This script will set up your omarchy configuration repositories."

    # Step 1: Check prerequisites
    check_prerequisites
    echo

    # Step 2: Discover branches
    set +e
    local available_branches=$(discover_branches)
    local discovery_exit_code=$?
    set -e

    if [[ $discovery_exit_code -eq 130 ]]; then
        cleanup
    fi
    echo

    # Step 3: Prompt for branch selection
    local selected_branch
    selected_branch=$(prompt_branch_selection "$available_branches")

    info "✓ Selected branch: $selected_branch"
    echo

    # Step 4: Clone/update repositories
    gum style --foreground $CYAN --padding "1 0 0 0" "Setting up configuration repositories..."

    for dir_name in "${!REPOS[@]}"; do
        clone_or_update_repo "$dir_name" "${REPOS[$dir_name]}" "$selected_branch"
        echo
    done

    # Step 5: Handle dotfiles separately (always use arch-omarchy branch)
    clone_or_update_repo "dotfiles" "$DOTFILES_REPO" "$DOTFILES_BRANCH"
    echo

    # Step 7: Success message
    gum style \
        --foreground $GREEN \
        --border double \
        --padding "1 2" \
        --margin "1 0" \
        "Setup Complete!" \
        "" \
        "Your omarchy configuration repositories have been set up." \
        "Branch: $selected_branch"

    if [[ -d "$BACKUP_DIR" ]]; then
        info "Backups are stored in: $BACKUP_DIR"
    fi
}

# Run main function
main
