#!/data/data/com.termux/files/usr/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

DEFAULT_LOG="${PREFIX:-/data/data/com.termux/files/usr}/var/log/nginx/access.log"
LOG_FILE="${1:-${LOG_PATH:-$DEFAULT_LOG}}"

if [ ! -f "$LOG_FILE" ]; then
    echo "[!] Log file not found at $LOG_FILE. Creating it..."
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
fi

echo "[+] Streaming live telemetry from: $LOG_FILE"

tail -n 20 -F "$LOG_FILE" | awk '
BEGIN {
    CYAN    = "\033[1;36m"
    GREEN   = "\033[1;32m"
    YELLOW  = "\033[1;33m"
    RED     = "\033[1;31m"
    MAGENTA = "\033[1;35m"
    BLUE    = "\033[1;34m"
    RESET   = "\033[0m"
}
{
    line = $0
    gsub(/ (GET|POST|OPTIONS|DELETE|PUT) /, CYAN " & " RESET, line)
    gsub(/-> 200 /, GREEN "-> 200 " RESET, line)
    gsub(/-> (4[0-9][0-9]|5[0-9][0-9]) /, RED "-> & " RESET, line)
    gsub(/status: 200/, GREEN "status: 200" RESET, line)
    gsub(/status: (4[0-9][0-9]|5[0-9][0-9])/, RED "&" RESET, line)
    gsub(/Upstream: [^|]+/, YELLOW "&" RESET, line)
    gsub(/latency: [0-9.]+s/, MAGENTA "&" RESET, line)
    gsub(/ttfb: [0-9.]+s/, MAGENTA "&" RESET, line)
    gsub(/Size: [^|]+/, BLUE "&" RESET, line)
    print line
    fflush()
}
'
