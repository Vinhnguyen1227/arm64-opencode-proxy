#!/data/data/com.termux/files/usr/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
elif [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

PORT="${PORT:-8080}"
NGROK_DOMAIN="${NGROK_DOMAIN:-}"
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"

if [ -z "$NGROK_AUTHTOKEN" ]; then
    echo "[-] Error: NGROK_AUTHTOKEN is missing. Please define it in your .env file."
    exit 1
fi

if [ -z "$NGROK_DOMAIN" ]; then
    echo "[-] Error: NGROK_DOMAIN is missing. Please define it in your .env file."
    exit 1
fi

termux-wake-lock

if ! command -v proot &>/dev/null; then
    apt update -y || pkg update -y
    apt install -y proot curl tar || pkg install -y proot curl tar
fi

if [ ! -f "$PREFIX/bin/ngrok" ]; then
    echo "[*] Downloading official ngrok Linux ARM64 binary..."
    TMP_TGZ="$PREFIX/tmp/ngrok.tgz"
    mkdir -p "$PREFIX/tmp"
    curl -Lo "$TMP_TGZ" https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz
    tar -xzf "$TMP_TGZ" -C "$PREFIX/bin"
    chmod +x "$PREFIX/bin/ngrok"
    rm -f "$TMP_TGZ"
fi

echo "[+] Applying ngrok authtoken from .env..."
termux-chroot ngrok config add-authtoken "$NGROK_AUTHTOKEN"

echo ""
echo "[+] Starting permanent ngrok tunnel..."
echo "    Domain: https://$NGROK_DOMAIN"
echo "    Target: http://127.0.0.1:$PORT"
echo ""

exec termux-chroot ngrok http "$PORT" --domain="$NGROK_DOMAIN"
