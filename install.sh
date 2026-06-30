#!/bin/bash
# ============================================================================
# imgctl - Installation Script
# ============================================================================
# This script installs imgctl on the BCM head node.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-12-03
# ============================================================================

# set -e is used to exit the script if any command fails
set -e 

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Installation paths - readonly to prevent tampering
readonly INSTALL_DIR="/opt/imgctl"
readonly BIN_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/imgctl"
readonly LOG_DIR="/var/log/giindia/imgctl"
readonly CACHE_DIR="/var/cache/imgctl"
readonly COMMAND_NAME="imgctl"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║              imgctl - Installation                         ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error:${NC} This script must be run as root (use sudo)"
    exit 1
fi

# Check dependencies
echo -e "${BLUE}[1/7]${NC} Checking dependencies..."

missing_deps=() # array to store missing dependencies

# -v is used to check if the command is available
if ! command -v jq >/dev/null 2>&1; then
    missing_deps+=("jq")
fi

if ! command -v curl >/dev/null 2>&1; then
    missing_deps+=("curl")
fi

if ! command -v ssh >/dev/null 2>&1; then
    missing_deps+=("openssh-client")
fi

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Installing missing dependencies: ${missing_deps[*]}${NC}"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq # -qq is used to suppress progress output
        apt-get install -y "${missing_deps[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing_deps[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing_deps[@]}"
    else
        echo -e "${RED}Error:${NC} Cannot install dependencies. Please install manually: ${missing_deps[*]}"
        exit 1
    fi
fi
echo -e "${GREEN}✓${NC} Dependencies satisfied"

# Security check: ensure installation paths don't contain malicious symlinks
echo -e "${BLUE}[2/7]${NC} Performing security checks..."

# Function to check for dangerous symlinks in path
check_path_security() {
    local path="$1"
    local current=""
    
    # Split path and check each component
    # -ra is used to read the array as elements
    IFS='/' read -ra PARTS <<< "$path"
    for part in "${PARTS[@]}"; do
        [[ -z "$part" ]] && continue
        current="$current/$part"
        
        if [[ -L "$current" ]]; then
            echo -e "${RED}Security Error:${NC} Symlink detected in installation path: $current"
            echo "This could be a symlink attack. Please investigate and remove the symlink."
            exit 1
        fi
    done
}

# Check all installation paths for existing symlinks
for check_path in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"; do
    if [[ -e "$check_path" ]]; then
        check_path_security "$check_path"
        
        # Additional check: if directory exists, verify ownership
        if [[ -d "$check_path" ]]; then
            owner=$(stat -c '%u' "$check_path" 2>/dev/null || stat -f '%u' "$check_path" 2>/dev/null)
            if [[ "$owner" != "0" ]] && [[ "$owner" != "$(id -u)" ]]; then
                echo -e "${YELLOW}Warning:${NC} $check_path exists but is owned by uid $owner"
                read -p "Continue installation? This may be unsafe. [y/N] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Installation cancelled."
                    exit 1
                fi
            fi
        fi
    fi
done

echo -e "${GREEN}✓${NC} Security checks passed"

# Create directories
echo -e "${BLUE}[3/7]${NC} Creating directories..."

# Use umask to ensure secure default permissions during directory creation
OLD_UMASK=$(umask)
umask 027

mkdir -p "$INSTALL_DIR"/{bin,lib,conf}
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$CACHE_DIR"

# Restore original umask
umask "$OLD_UMASK"

# Explicitly set permissions (defense in depth)
chmod 755 "$INSTALL_DIR"
chmod 750 "$CONFIG_DIR"
chmod 750 "$LOG_DIR"
chmod 750 "$CACHE_DIR"

# Set ownership explicitly to root
chown root:root "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"

echo -e "${GREEN}✓${NC} Directories created"

# Copy files
echo -e "${BLUE}[4/7]${NC} Installing files..."

# Function to securely copy a file (rejects symlinks)
copy_file() {
    local dest="$1"
    shift
    local sources=("$@")
    
    for src in "${sources[@]}"; do
        if [[ -f "$src" ]] && [[ ! -L "$src" ]]; then
            # Use -- to prevent argument injection
            # -- mean end of options
            cp -f -- "$src" "$dest"
            return 0
        elif [[ -L "$src" ]]; then
            echo -e "${YELLOW}Warning:${NC} Skipping symlink: $src"
        fi
    done
    
    echo -e "${RED}Error:${NC} Could not find source file. Tried: ${sources[*]}"
    return 1
}

# Copy library files
copy_file "$INSTALL_DIR/lib/common.sh" "${SCRIPT_DIR}/lib/common.sh" || exit 1
copy_file "$INSTALL_DIR/lib/crictl.sh" "${SCRIPT_DIR}/lib/crictl.sh" || exit 1
copy_file "$INSTALL_DIR/lib/harbor.sh" "${SCRIPT_DIR}/lib/harbor.sh" || exit 1
copy_file "$INSTALL_DIR/lib/output.sh" "${SCRIPT_DIR}/lib/output.sh" || exit 1

chmod 644 "$INSTALL_DIR/lib/"*.sh

# Copy binary
copy_file "$INSTALL_DIR/bin/imgctl" "${SCRIPT_DIR}/bin/imgctl" || exit 1

chmod 755 "$INSTALL_DIR/bin/imgctl"

echo -e "${GREEN}✓${NC} Files installed"

# Create symlink
echo -e "${BLUE}[5/7]${NC} Creating command symlink..."

# Remove existing symlink if present (safely)
if [[ -L "$BIN_DIR/$COMMAND_NAME" ]]; then
    rm -f -- "$BIN_DIR/$COMMAND_NAME"
elif [[ -e "$BIN_DIR/$COMMAND_NAME" ]]; then
    echo -e "${RED}Error:${NC} $BIN_DIR/$COMMAND_NAME exists and is not a symlink"
    echo "Please remove it manually before installing."
    exit 1
fi

# -s is used to create a symbolic link; -f is used to force the link
# -- is used to prevent argument injection
ln -sf -- "$INSTALL_DIR/bin/imgctl" "$BIN_DIR/$COMMAND_NAME"

echo -e "${GREEN}✓${NC} Symlink created: $BIN_DIR/$COMMAND_NAME"

# Install configuration -- PRESERVE an existing tuned config; never clobber it.
echo -e "${BLUE}[6/7]${NC} Installing configuration..."

if [[ -f "$CONFIG_DIR/imgctl.conf" ]]; then
    cfg_bak="$CONFIG_DIR/imgctl.conf.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p -f -- "$CONFIG_DIR/imgctl.conf" "$cfg_bak"
    chmod 600 "$cfg_bak"   # config holds HARBOR_PASSWORD — never leave the backup world-readable
    echo -e "${GREEN}✓${NC} Existing configuration preserved (backup: $cfg_bak, mode 600)"
    echo -e "${YELLOW}!${NC} Not overwriting $CONFIG_DIR/imgctl.conf — if upgrading, add any new WEB_* keys from conf/imgctl.conf"
else
    copy_file "$CONFIG_DIR/imgctl.conf" "${SCRIPT_DIR}/conf/imgctl.conf" || exit 1
    chmod 640 "$CONFIG_DIR/imgctl.conf"
    echo -e "${GREEN}✓${NC} Configuration installed"
    echo -e "${YELLOW}!${NC} Please edit $CONFIG_DIR/imgctl.conf with your cluster details"
fi

# Install ignore list -- PRESERVE an existing curated list; never clobber it.
if [[ -f "$CONFIG_DIR/images_to_ignore.txt" ]]; then
    cp -f -- "$CONFIG_DIR/images_to_ignore.txt" "$CONFIG_DIR/images_to_ignore.txt.bak.$(date +%Y%m%d-%H%M%S)"
    echo -e "${GREEN}✓${NC} Existing ignore list preserved (backed up)"
elif [[ -f "${SCRIPT_DIR}/images_to_ignore.txt" ]] && [[ ! -L "${SCRIPT_DIR}/images_to_ignore.txt" ]]; then
    cp -f -- "${SCRIPT_DIR}/images_to_ignore.txt" "$CONFIG_DIR/images_to_ignore.txt"
    chmod 644 "$CONFIG_DIR/images_to_ignore.txt"
    echo -e "${GREEN}✓${NC} Ignore list installed"
else
    echo -e "${YELLOW}!${NC} No ignore list found, skipping"
fi

# Verify installation
echo -e "${BLUE}[7/7]${NC} Verifying installation..."

if command -v imgctl >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Installation verified"
else
    echo -e "${RED}Error:${NC} Installation verification failed"
    exit 1
fi

# Print summary
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Installation Completed Successfully!          ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Installation Summary:${NC}"
echo "  • Install directory:  $INSTALL_DIR"
echo "  • Configuration:      $CONFIG_DIR/imgctl.conf"
echo "  • Ignore list:        $CONFIG_DIR/images_to_ignore.txt"
echo "  • Log directory:      $LOG_DIR"
echo "  • Cache directory:    $CACHE_DIR"
echo "  • Command:            imgctl"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo "  1. Edit the configuration file:"
echo -e "     ${CYAN}sudo nano $CONFIG_DIR/imgctl.conf${NC}"
echo ""
echo "  2. Update the following settings:"
echo "     • WORKER_NODES    - Your DGX worker node hostnames"
echo "     • HARBOR_URL      - Your Harbor registry URL"
echo "     • HARBOR_USER     - Harbor username"
echo "     • HARBOR_PASSWORD - Harbor password"
echo ""
echo "  3. (Optional) Edit the ignore list to exclude Kubernetes system images:"
echo -e "     ${CYAN}sudo nano $CONFIG_DIR/images_to_ignore.txt${NC}"
echo ""
echo "  4. (Optional) Enable imgctl for non-root users:"
echo ""
echo "     a. Open sudoers file:"
echo -e "        ${CYAN}sudo visudo -f /etc/sudoers.d/imgctl${NC}"
echo ""
echo "        Add the following entry:"
echo -e "        ${CYAN}ALL ALL=(root) NOPASSWD: $INSTALL_DIR/bin/imgctl${NC}"
echo ""
echo "     b. Create shell alias file:"
echo -e "        ${CYAN}sudo vim /etc/profile.d/imgctl.sh${NC}"
echo ""
echo "        Add the following entry:"
echo -e "        ${CYAN}alias imgctl='sudo $INSTALL_DIR/bin/imgctl'${NC}"
echo ""
echo "     c. Users must log out and log back in for the alias to take effect."
echo ""
echo "  5. Test the installation:"
echo -e "     ${CYAN}imgctl --version${NC}"
echo ""
echo -e "${BOLD}Quick Commands:${NC}"
echo "  imgctl get              # Get all images"
echo "  imgctl get harbor       # Get Harbor images only"
echo "  imgctl get nodes        # Get node images only"
echo "  imgctl compare          # Compare images across nodes"
echo "  imgctl help             # Show full help"
echo ""

# ============================================================================
# WEB GUI ("Cluster Image Portal") -- optional component (skip with --no-gui)
# ============================================================================
INSTALL_GUI="yes"
[[ "${1:-}" == "--no-gui" ]] && INSTALL_GUI="no"

if [[ "$INSTALL_GUI" == "yes" && -d "${SCRIPT_DIR}/web" ]]; then
    echo -e "${BOLD}${BLUE}Installing Web GUI (Cluster Image Portal)...${NC}"

    WEB_DIR="$INSTALL_DIR/web"
    STATE_DIR="/var/lib/imgcatalog"
    SYSTEMD_DIR="/etc/systemd/system"

    mkdir -p "$WEB_DIR/static"
    cp -f -- "${SCRIPT_DIR}/web/server.py"  "$WEB_DIR/server.py"
    cp -f -- "${SCRIPT_DIR}/web/refresh.sh" "$WEB_DIR/refresh.sh"
    cp -f -- "${SCRIPT_DIR}/web/static/"*   "$WEB_DIR/static/"
    chmod 755 "$WEB_DIR/server.py" "$WEB_DIR/refresh.sh"
    chmod 644 "$WEB_DIR/static/"*
    echo -e "${GREEN}✓${NC} Portal files installed to $WEB_DIR"

    # Snapshot dir: root writes it; world-readable so the unprivileged web user can read.
    mkdir -p "$STATE_DIR"; chown root:root "$STATE_DIR"; chmod 755 "$STATE_DIR"

    if command -v systemctl >/dev/null 2>&1; then
        cp -f -- "${SCRIPT_DIR}/web/systemd/imgcatalog.service"         "$SYSTEMD_DIR/"
        cp -f -- "${SCRIPT_DIR}/web/systemd/imgcatalog-refresh.service" "$SYSTEMD_DIR/"
        cp -f -- "${SCRIPT_DIR}/web/systemd/imgcatalog-refresh.timer"   "$SYSTEMD_DIR/"
        systemctl daemon-reload
        "$WEB_DIR/refresh.sh" || echo -e "${YELLOW}!${NC} Initial snapshot refresh failed (the timer will retry)"
        systemctl enable --now imgcatalog-refresh.timer >/dev/null 2>&1 || true
        systemctl enable --now imgcatalog.service       >/dev/null 2>&1 || true
        echo -e "${GREEN}✓${NC} Services enabled: imgcatalog.service + imgcatalog-refresh.timer"
    else
        echo -e "${YELLOW}!${NC} systemctl not found; units copied but not enabled"
    fi

    WEB_PORT_MSG="8088"
    if [[ -f "$CONFIG_DIR/imgctl.conf" ]]; then
        p="$(grep -E '^WEB_PORT=' "$CONFIG_DIR/imgctl.conf" 2>/dev/null | tail -1 | cut -d'"' -f2 || true)"
        [[ -n "$p" ]] && WEB_PORT_MSG="$p"
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}ACTION REQUIRED — open the firewall port (manual admin step):${NC}"
    echo "  The portal listens on TCP ${WEB_PORT_MSG}. This installer does NOT touch the firewall."
    echo "  Run cmsh INTERACTIVELY and enter these commands, one per line (do NOT hand-edit"
    echo "  /etc/shorewall/rules; non-interactive 'cmsh -c' does NOT reliably commit):"
    echo -e "    ${CYAN}cmsh${NC}"
    echo -e "    ${CYAN}device${NC}"
    echo -e "    ${CYAN}use $(hostname -s)${NC}"
    echo -e "    ${CYAN}roles${NC}"
    echo -e "    ${CYAN}use firewall${NC}"
    echo -e "    ${CYAN}openports${NC}"
    echo -e "    ${CYAN}add ACCEPT net ${WEB_PORT_MSG} tcp fw${NC}"
    echo -e "    ${CYAN}commit${NC}"
    echo -e "    ${CYAN}quit${NC}"
    echo "  Then browse to:  http://<head-node-host-or-ip>:${WEB_PORT_MSG}/"
    echo "  (Full details in README.md and docs/WEB_UI.md.)"
    echo ""
fi