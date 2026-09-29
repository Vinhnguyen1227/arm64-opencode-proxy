#!/data/data/com.termux/files/usr/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

PORT="${PORT:-8080}"
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"

if [ ! -f "$SSL_CERT_FILE" ]; then
    apt update -y || pkg update -y
    apt install -y ca-certificates || pkg install -y ca-certificates
fi

termux-wake-lock

if ! command -v cloudflared &>/dev/null; then
    echo "[*] cloudflared not found in PATH. Attempting package install..."
    pkg install -y cloudflared 2>/dev/null || true
fi

if ! command -v cloudflared &>/dev/null; then
    CLOUDFLARED_BIN="$PREFIX/bin/cloudflared"
    echo "[*] Downloading official cloudflared ARM64 binary..."
    curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" -o "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
fi

RUN_CMD="cloudflared"
if command -v termux-chroot &>/dev/null; then
    RUN_CMD="termux-chroot cloudflared"
fi

echo "[+] Starting Cloudflare Tunnel pointing to local port $PORT..."
echo "[+] Forwarding: http://127.0.0.1:$PORT"

if [ -n "$TUNNEL_TOKEN" ]; then
    echo "[+] Running named tunnel with TUNNEL_TOKEN..."
    exec $RUN_CMD tunnel run --token "$TUNNEL_TOKEN"
else
    echo "[+] Running quick ephemeral tunnel (trycloudflare.com)..."
    echo "[+] Copy the generated URL into your opencode.json options.baseURL"
    echo ""
    exec $RUN_CMD tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate
fi
