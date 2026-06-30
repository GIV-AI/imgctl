#!/bin/bash
# ============================================================================
# imgctl - Uninstall Script
# ============================================================================
# This script removes imgctl from the system.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Date: 2025-12-03
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Hardcoded paths - do not allow environment override
readonly INSTALL_DIR="/opt/imgctl"
readonly BIN_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/imgctl"
readonly LOG_DIR="/var/log/giindia/imgctl"
readonly CACHE_DIR="/var/cache/imgctl"
readonly COMMAND_NAME="imgctl"

# Security function: safely remove a directory only if it's a real directory (not symlink)
# and is owned by root, preventing symlink attacks
safe_remove_dir() {
    local target="$1"
    
    # Check if path exists
    if [[ ! -e "$target" ]]; then
        return 1
    fi
    
    # CRITICAL: Check that it's a real directory, not a symlink
    if [[ -L "$target" ]]; then
        echo -e "${RED}Security Error:${NC} $target is a symlink, refusing to remove"
        return 2
    fi
    
    # Verify it's actually a directory
    if [[ ! -d "$target" ]]; then
        echo -e "${RED}Security Error:${NC} $target is not a directory"
        return 2
    fi
    
    # Verify ownership (should be root for system directories)
    local owner
    owner=$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target" 2>/dev/null)
    if [[ "$owner" != "0" ]]; then
        echo -e "${YELLOW}Warning:${NC} $target is not owned by root (owner uid: $owner)"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 3
        fi
    fi
    
    # Safe to remove
    rm -rf -- "$target"
    return 0
}

# Security function: safely remove a symlink only if it points to expected target
safe_remove_symlink() {
    local symlink="$1"
    local expected_target="$2"
    
    if [[ ! -L "$symlink" ]]; then
        return 1
    fi
    
    local actual_target
    actual_target=$(readlink -f "$symlink" 2>/dev/null || readlink "$symlink" 2>/dev/null)
    
    if [[ "$actual_target" != "$expected_target" ]]; then
        echo -e "${YELLOW}Warning:${NC} Symlink $symlink points to unexpected target: $actual_target"
        echo "  Expected: $expected_target"
        read -p "Remove anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 2
        fi
    fi
    
    rm -f -- "$symlink"
    return 0
}

echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║              imgctl - Uninstaller                          ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error:${NC} This script must be run as root (use sudo)"
    exit 1
fi

# Show what will be removed
echo -e "${BOLD}The following will be removed:${NC}"
[[ -L "$BIN_DIR/$COMMAND_NAME" ]] && echo "  • $BIN_DIR/$COMMAND_NAME (symlink)"
[[ -d "$INSTALL_DIR" ]] && echo "  • $INSTALL_DIR (installation directory)"
[[ -d "$CONFIG_DIR" ]] && echo "  • $CONFIG_DIR (configuration)"
[[ -d "$LOG_DIR" ]] && echo "  • $LOG_DIR (logs)"
[[ -d "$CACHE_DIR" ]] && echo "  • $CACHE_DIR (cache)"
echo ""

# Confirm uninstallation
read -p "Are you sure you want to uninstall $COMMAND_NAME? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Removing $COMMAND_NAME...${NC}"
echo ""

# --- Back up config + ignore list BEFORE removing anything ---
BACKUP_DIR="/var/backups/imgctl/$(date +%Y%m%d-%H%M%S)"
if [[ -f "$CONFIG_DIR/imgctl.conf" || -f "$CONFIG_DIR/images_to_ignore.txt" ]]; then
    mkdir -p "$BACKUP_DIR"
    [[ -f "$CONFIG_DIR/imgctl.conf" ]] && cp -f -- "$CONFIG_DIR/imgctl.conf" "$BACKUP_DIR/"
    [[ -f "$CONFIG_DIR/images_to_ignore.txt" ]] && cp -f -- "$CONFIG_DIR/images_to_ignore.txt" "$BACKUP_DIR/"
    echo -e "${GREEN}✓${NC} Backed up config + ignore list to: ${BOLD}$BACKUP_DIR${NC}"
fi

# --- Tear down the Web GUI (stop services first, then remove units + state) ---
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now imgcatalog.service       >/dev/null 2>&1 || true
    systemctl disable --now imgcatalog-refresh.timer >/dev/null 2>&1 || true
    systemctl stop          imgcatalog-refresh.service >/dev/null 2>&1 || true
    rm -f -- /etc/systemd/system/imgcatalog.service \
             /etc/systemd/system/imgcatalog-refresh.service \
             /etc/systemd/system/imgcatalog-refresh.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo -e "${GREEN}✓${NC} Removed Web GUI services (imgcatalog.service / imgcatalog-refresh.timer)"
fi
if [[ -e "/var/lib/imgcatalog" ]]; then
    if safe_remove_dir "/var/lib/imgcatalog"; then
        echo -e "${GREEN}✓${NC} Removed /var/lib/imgcatalog (snapshot)"
    fi
fi

# Remove symlink (verify it points to our installation)
if [[ -L "$BIN_DIR/$COMMAND_NAME" ]]; then
    if safe_remove_symlink "$BIN_DIR/$COMMAND_NAME" "$INSTALL_DIR/bin/$COMMAND_NAME"; then
        echo -e "${GREEN}✓${NC} Removed $BIN_DIR/$COMMAND_NAME"
    fi
else
    echo -e "${YELLOW}!${NC} Symlink $BIN_DIR/$COMMAND_NAME not found"
fi

# Remove installation directory (with symlink attack protection)
if [[ -e "$INSTALL_DIR" ]]; then
    if safe_remove_dir "$INSTALL_DIR"; then
        echo -e "${GREEN}✓${NC} Removed $INSTALL_DIR"
    fi
else
    echo -e "${YELLOW}!${NC} Installation directory $INSTALL_DIR not found"
fi

# Ask about configuration (with symlink attack protection)
echo ""
if [[ -e "$CONFIG_DIR" ]]; then
    read -p "Remove configuration files ($CONFIG_DIR)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if safe_remove_dir "$CONFIG_DIR"; then
            echo -e "${GREEN}✓${NC} Removed $CONFIG_DIR"
        fi
    else
        echo -e "${YELLOW}!${NC} Configuration preserved at $CONFIG_DIR"
    fi
fi

# Ask about logs (with symlink attack protection)
if [[ -e "$LOG_DIR" ]]; then
    read -p "Remove log files ($LOG_DIR)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if safe_remove_dir "$LOG_DIR"; then
            echo -e "${GREEN}✓${NC} Removed $LOG_DIR"
            
            # Also remove parent if empty (safe - rmdir only removes empty dirs)
            rmdir --ignore-fail-on-non-empty /var/log/giindia 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}!${NC} Logs preserved at $LOG_DIR"
    fi
fi

# Clean up cache (with symlink attack protection)
if [[ -e "$CACHE_DIR" ]]; then
    if safe_remove_dir "$CACHE_DIR"; then
        echo -e "${GREEN}✓${NC} Removed cache directory $CACHE_DIR"
    fi
fi

# Clean up user config directories
# SECURITY: Get actual root user's home, not potentially manipulated $HOME
ROOT_HOME=$(getent passwd root | cut -d: -f6)
# Also check the invoking user's home via SUDO_USER if available
if [[ -n "$SUDO_USER" ]]; then
    INVOKING_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

# Check root's config
if [[ -d "$ROOT_HOME/.config/$COMMAND_NAME" ]] && [[ ! -L "$ROOT_HOME/.config/$COMMAND_NAME" ]]; then
    read -p "Remove root user configuration ($ROOT_HOME/.config/$COMMAND_NAME)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf -- "$ROOT_HOME/.config/$COMMAND_NAME"
        echo -e "${GREEN}✓${NC} Removed $ROOT_HOME/.config/$COMMAND_NAME"
    fi
fi

# Check invoking user's config (if different from root)
if [[ -n "$INVOKING_USER_HOME" ]] && [[ "$INVOKING_USER_HOME" != "$ROOT_HOME" ]]; then
    if [[ -d "$INVOKING_USER_HOME/.config/$COMMAND_NAME" ]] && [[ ! -L "$INVOKING_USER_HOME/.config/$COMMAND_NAME" ]]; then
        read -p "Remove user configuration ($INVOKING_USER_HOME/.config/$COMMAND_NAME)? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf -- "$INVOKING_USER_HOME/.config/$COMMAND_NAME"
            echo -e "${GREEN}✓${NC} Removed $INVOKING_USER_HOME/.config/$COMMAND_NAME"
        fi
    fi
fi

echo ""

# Remind about the manual firewall rule (the installer never touched it, so we don't either)
echo -e "${YELLOW}Note:${NC} If you opened a firewall port for the Web GUI, remove it manually via cmsh:"
echo -e "    ${CYAN}cmsh${NC}"
echo -e "    ${CYAN}% device; use \$(hostname -s); roles; use firewall${NC}"
echo -e "    ${CYAN}% openports; remove ACCEPT net 8088 tcp fw; commit${NC}"
echo "  (Adjust the port if you changed WEB_PORT.)"
echo ""

# Remind about optional sudoers/alias files
if [[ -f "/etc/sudoers.d/imgctl" ]] || [[ -f "/etc/profile.d/imgctl.sh" ]]; then
    echo -e "${YELLOW}Note:${NC} If you configured imgctl for non-root users, remove these files:"
    echo ""
    [[ -f "/etc/sudoers.d/imgctl" ]] && echo "  • Remove sudoers rule:"
    [[ -f "/etc/sudoers.d/imgctl" ]] && echo -e "    ${CYAN}sudo rm /etc/sudoers.d/imgctl${NC}"
    echo ""
    [[ -f "/etc/profile.d/imgctl.sh" ]] && echo "  • Remove shell alias:"
    [[ -f "/etc/profile.d/imgctl.sh" ]] && echo -e "    ${CYAN}sudo rm /etc/profile.d/imgctl.sh${NC}"
    echo ""
fi

echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Uninstall Completed Successfully!             ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
