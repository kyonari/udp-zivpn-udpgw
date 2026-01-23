#!/bin/bash
# Uninstaller for Zivpn UDP Module + UDPGW
# Cleans up Services, Files, and Firewall Rules

# --- Global Variables & Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "sudo su, please!"
        exit 1
    fi
}

confirm_uninstall() {
    echo -e "${RED}WARNING:${NC} This script will remove Zivpn, UDPGW, and related configurations."
    read -p "Are you sure you want to continue? (y/n):" choice
    case "$choice" in 
      y|Y ) echo "Starting the uninstall process...";;
      * ) echo "Cancelled."; exit 0;;
    esac
}

remove_services() {
    log_info "Stopping and removing services..."
    
    # Stop services
    systemctl stop zivpn.service 2>/dev/null
    systemctl stop udpgw.service 2>/dev/null
    
    # Disable services
    systemctl disable zivpn.service 2>/dev/null
    systemctl disable udpgw.service 2>/dev/null
    
    # Remove service files
    rm -f /etc/systemd/system/zivpn.service
    rm -f /etc/systemd/system/udpgw.service
    
    # Reload daemon
    systemctl daemon-reload
}

remove_files() {
    log_info "Removing binaries and configurations..."
    
    # Remove Binaries
    rm -f /usr/local/bin/zivpn
    rm -f /usr/local/bin/udpgw
    
    # Remove Config Directory
    rm -rf /etc/zivpn
    
    # Remove Sysctl Config
    rm -f /etc/sysctl.d/zivpn.conf
}

remove_firewall() {
    log_info "Cleaning up Firewall rules..."
    
    # Detect Main Interface
    IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    if [ -n "$IFACE" ]; then
        iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || true
        log_info "IPTables NAT rule removed."
    fi

    # UFW cleanup
    if command -v ufw > /dev/null; then
        ufw delete allow 6000:19999/udp 2>/dev/null
        ufw delete allow 5667/udp 2>/dev/null
        ufw delete allow 7300/udp 2>/dev/null
        log_info "UFW rules removed."
    fi

    # Save changes permanently
    if command -v netfilter-persistent > /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
}

cleanup_logs() {
    log_info "Cleaning up logs..."
    # Delete log journald (opsional btw)
    journalctl --vacuum-time=1s --unit=zivpn.service >/dev/null 2>&1
    journalctl --vacuum-time=1s --unit=udpgw.service >/dev/null 2>&1
}

# --- Main Execution ---
check_root
confirm_uninstall
remove_services
remove_files
remove_firewall
cleanup_logs

echo -e ""
echo -e "======================================="
echo -e "${GREEN} UNINSTALL COMPLETED ${NC}"
echo -e "======================================="
