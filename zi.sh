#!/bin/bash
# Zivpn UDP Module + UDPGW Installer

# --- Global Variables & Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ZIVPN_BIN="/usr/local/bin/zivpn"
ZIVPN_CFG_DIR="/etc/zivpn"
UDPGW_BIN="/usr/local/bin/udpgw"
TMP_DIR=$(mktemp -d)

# Stop script on error
set -e

# --- Helper Functions ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    rm -rf "$TMP_DIR"
    log_info "Temporary files cleaned up."
}
trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "sudo su, please!."
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ZIVPN_ARCH="amd64"
            ;;
        aarch64)
            ZIVPN_ARCH="arm64"
            ;;
        *)
            log_err "$ARCH not supported."
            exit 1
            ;;
    esac
    log_info "Architecture detected: $ARCH ($ZIVPN_ARCH)"
}

update_system() {
    log_info "Updating system repositories..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get upgrade -y
    
    log_info "Installing dependencies (Git, Go, OpenSSL, IPTables-Persistent)..."
    apt-get install -y git golang openssl iptables-persistent netfilter-persistent
}

stop_services() {
    log_info "Stopping existing services..."
    systemctl stop zivpn.service 2>/dev/null || true
    systemctl stop udpgw.service 2>/dev/null || true
}

install_zivpn() {
    log_info "Downloading Zivpn binary for $ZIVPN_ARCH..."
    
    # URL Selection based on architecture
    if [ "$ZIVPN_ARCH" == "amd64" ]; then
        DOWNLOAD_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
    elif [ "$ZIVPN_ARCH" == "arm64" ]; then
        DOWNLOAD_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
    else
        log_err "Arsitektur tidak dikenali untuk download."
        exit 1
    fi

    wget -q --show-progress "$DOWNLOAD_URL" -O "$ZIVPN_BIN"
    chmod +x "$ZIVPN_BIN"
    mkdir -p "$ZIVPN_CFG_DIR"
    
    log_info "Downloading Default Config..."
    wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O "$ZIVPN_CFG_DIR/config.json"

    log_info "Generating Self-Signed Certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=Zivpn/OU=VPN/CN=zivpn-server" \
        -keyout "$ZIVPN_CFG_DIR/zivpn.key" \
        -out "$ZIVPN_CFG_DIR/zivpn.crt" 2>/dev/null
}

build_udpgw() {
    log_info "Building UDPGW from source (mukswilly/udpgw)..."
    cd "$TMP_DIR"
    
    if git clone https://github.com/mukswilly/udpgw.git; then
        cd udpgw
        if [ -d "cmd" ]; then cd cmd; fi
        
        # Build optimized binary (stripped debug info, static link)
        export CGO_ENABLED=0
        if go build -ldflags="-s -w" -o udpgw; then
            mv udpgw "$UDPGW_BIN"
            chmod +x "$UDPGW_BIN"
            log_info "UDPGW built successfully."
        else
            log_err "Failed to compile UDPGW."
            exit 1
        fi
    else
        log_err "Failed to clone repo UDPGW."
        exit 1
    fi
}

configure_kernel() {
    log_info "Optimizing Kernel parameters..."
    cat <<EOF > /etc/sysctl.d/zivpn.conf
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl -p /etc/sysctl.d/zivpn.conf >/dev/null
}

setup_services() {
    log_info "Creating Systemd Services..."

    # ZIVPN Service
    cat <<EOF > /etc/systemd/system/zivpn.service
[Unit]
Description=Zivpn UDP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$ZIVPN_CFG_DIR
ExecStart=$ZIVPN_BIN server -c $ZIVPN_CFG_DIR/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    # UDPGW Service
    cat <<EOF > /etc/systemd/system/udpgw.service
[Unit]
Description=UDPGW Golang Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$UDPGW_BIN -port 7300
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

configure_passwords() {
    log_info "ZIVPN UDP Password Configuration"
    echo -e "${YELLOW}Enter passwords separated by commas (e.g., pass1,pass2).${NC}"
    read -p "Press Enter for default 'zi': " input_config

    if [ -n "$input_config" ]; then
        IFS=',' read -r -a config_array <<< "$input_config"
        config_clean=()
        for i in "${config_array[@]}"; do
            config_clean+=("$(echo "$i" | xargs)")
        done
    else
        config_clean=("zi")
    fi

    # Generate JSON array manually
    json_array="["
    first=true
    for pwd in "${config_clean[@]}"; do
        if [ "$first" = true ]; then
            json_array+="\"$pwd\""
            first=false
        else
            json_array+=", \"$pwd\""
        fi
    done
    json_array+="]"

    sed -i "s/\"config\":.*/\"config\": $json_array/" "$ZIVPN_CFG_DIR/config.json"
    log_info "Password configured: $json_array"
}

setup_firewall() {
    log_info "Applying Firewall Rules..."
    
    # Detect Main Interface
    IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    if [ -z "$IFACE" ]; then
        log_warn "Could not detect main interface. Skipping NAT rule."
    else
        # Remove old rule if exists
        iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || true
        iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 6000:7099 -j DNAT --to-destination :5667 2>/dev/null || true
        iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 7501:19999 -j DNAT --to-destination :5667 2>/dev/null || true
        
        # Add new rule
        iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:7099 -j DNAT --to-destination :5667
        iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 7501:19999 -j DNAT --to-destination :5667
    fi

    if command -v ufw > /dev/null; then
        ufw allow 6000:19999/udp >/dev/null
        ufw allow 5667/udp >/dev/null
    fi
    
    # Save IPTables rules persistently
    netfilter-persistent save >/dev/null 2>&1 || log_warn "Failed to save IPTables rule permanently."
}

start_services() {
    log_info "Starting Services..."
    systemctl enable --now zivpn.service
    systemctl enable --now udpgw.service
}

# --- Main Execution ---
check_root
detect_arch
update_system
stop_services
install_zivpn
build_udpgw
configure_kernel
setup_services
configure_passwords
setup_firewall
start_services

echo -e ""
echo -e "======================================="
echo -e "${GREEN} INSTALLATION COMPLETED ${NC}"
echo -e "======================================="
echo -e " UDP Ports   : 6000-19999 (Forwarded to 5667)"
echo -e " UDPGW Port  : 7300 (Local)"
echo -e " Config File : $ZIVPN_CFG_DIR/config.json"
echo -e " Arch        : $ZIVPN_ARCH"
echo -e "======================================="
