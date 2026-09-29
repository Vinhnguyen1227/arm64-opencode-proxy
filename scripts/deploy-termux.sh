#!/data/data/com.termux/files/usr/bin/bash
set -e

apt update -y || pkg update -y
apt install -y nginx gettext net-tools iproute2 || pkg install -y nginx gettext net-tools iproute2
termux-wake-lock

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
    echo "[+] Loaded environment from $REPO_DIR/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
    echo "[+] Loaded environment from $SCRIPT_DIR/.env"
fi

export PORT="${PORT:-8080}"
export UPSTREAM_HOST="${UPSTREAM_HOST:-api.vilao.ai}"
export UPSTREAM_PORT="${UPSTREAM_PORT:-443}"
export UPSTREAM_SCHEME="${UPSTREAM_SCHEME:-https}"
export MIMO_API_KEY="${MIMO_API_KEY:-}"
export USER_A_KEY="${USER_A_KEY:-sk-userA-vkey-001}"
export USER_B_KEY="${USER_B_KEY:-sk-userB-vkey-002}"
export LOG_PATH="${LOG_PATH:-$PREFIX/var/log/nginx/access.log}"
export ERROR_LOG_PATH="${ERROR_LOG_PATH:-$PREFIX/var/log/nginx/error.log}"

if [ -z "$MIMO_API_KEY" ]; then
    echo "[!] Warning: MIMO_API_KEY is unset in .env. Upstream authentication will fail."
fi

mkdir -p "$PREFIX/etc/nginx"
mkdir -p "$PREFIX/var/log/nginx"

TEMPLATE_FILE="$REPO_DIR/config/nginx.conf.template"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "[-] Error: Template not found at $TEMPLATE_FILE"
    exit 1
fi

envsubst '$PORT $UPSTREAM_HOST $UPSTREAM_PORT $UPSTREAM_SCHEME $MIMO_API_KEY $USER_A_KEY $USER_B_KEY $LOG_PATH $ERROR_LOG_PATH' < "$TEMPLATE_FILE" > "$PREFIX/etc/nginx/nginx.conf"

nginx -t

pkill -9 -f nginx 2>/dev/null || true
sleep 1
nginx


WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
if [ -z "$WLAN_IP" ]; then
    WLAN_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
fi
if [ -z "$WLAN_IP" ]; then
    WLAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "PHONE_IP")
fi

echo ""
echo "[+] OpenCode Reverse Proxy deployed successfully on ARM64 Termux!"
echo "    Local BaseURL:   http://localhost:$PORT"
echo "    LAN BaseURL:     http://$WLAN_IP:$PORT"
echo "    Health Check:    http://$WLAN_IP:$PORT/healthz"
echo "    Live Telemetry:  bash scripts/trace-live.sh"
echo "    Cloudflare WAN:  bash scripts/tunnel-termux.sh"
echo ""
echo "    User A Key: $USER_A_KEY"
echo "    User B Key: $USER_B_KEY"
