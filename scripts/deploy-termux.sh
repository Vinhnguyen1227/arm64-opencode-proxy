#!/data/data/com.termux/files/usr/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

apt update -y || pkg update -y
apt install -y nodejs-lts net-tools iproute2 || pkg install -y nodejs-lts net-tools iproute2
termux-wake-lock

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
    echo "[+] Loaded environment from $REPO_DIR/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
    echo "[+] Loaded environment from $SCRIPT_DIR/.env"
fi

export PORT="${PORT:-8080}"
export USER_A_KEY="${USER_A_KEY:-sk-userA-vkey-001}"
export USER_B_KEY="${USER_B_KEY:-sk-userB-vkey-002}"
export USER_C_KEY="${USER_C_KEY:-sk-userC-vkey-003}"

cd "$REPO_DIR"

echo "[*] Installing Node.js dependencies..."
npm install --omit=dev

mkdir -p "$PREFIX/var/log"
mkdir -p "$REPO_DIR/data"

echo "[*] Stopping existing proxy instances..."
pkill -9 -f nginx 2>/dev/null || true
pkill -9 -f "node.*proxy.js" 2>/dev/null || true
sleep 1

LOG_FILE="$PREFIX/var/log/proxy.log"

if command -v pm2 &>/dev/null; then
    echo "[+] Managing proxy daemon via PM2..."
    pm2 delete mimo-proxy 2>/dev/null || true
    pm2 start proxy.js --name mimo-proxy
else
    echo "[+] Starting proxy daemon in background..."
    nohup node proxy.js > "$LOG_FILE" 2>&1 &
fi

sleep 2

WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
if [ -z "$WLAN_IP" ]; then
    WLAN_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
fi
if [ -z "$WLAN_IP" ]; then
    WLAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "PHONE_IP")
fi

echo ""
echo "[+] Credit-Metered Reverse Proxy deployed successfully on ARM64 Termux!"
echo "    Local BaseURL:   http://localhost:$PORT"
echo "    LAN BaseURL:     http://$WLAN_IP:$PORT"
echo "    Health Check:    http://$WLAN_IP:$PORT/healthz"
echo "    Live Telemetry:  bash scripts/trace-live.sh"
echo "    Public WAN:      bash scripts/tunnel-ngrok.sh"
echo ""
echo "    User A Key: $USER_A_KEY"
echo "    User B Key: $USER_B_KEY"
echo "    User C Key: $USER_C_KEY"
