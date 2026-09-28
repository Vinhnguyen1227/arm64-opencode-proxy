#!/data/data/com.termux/files/usr/bin/bash
# Live HTTP Request & Upstream Telemetry Monitor for Termux Nginx Proxy

LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/log/nginx/access.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "[!] Log file not found at $LOG_FILE"
    echo "[*] Creating empty log file..."
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
fi

echo " Starting Live HTTP Telemetry Monitor on $LOG_FILE"


# Format and colorize log stream live
tail -n 20 -F "$LOG_FILE" | awk '
BEGIN {
    CYAN    = "\033[1;36m"
    GREEN   = "\033[1;32m"
    YELLOW  = "\033[1;33m"
    RED     = "\033[1;31m"
    MAGENTA = "\033[1;35m"
    BLUE    = "\033[1;34m"
    BOLD    = "\033[1m"
    DIM     = "\033[2m"
    RESET   = "\033[0m"
}
{
    line = $0

    # Highlight HTTP Methods
    gsub(/ (GET|POST|OPTIONS|DELETE|PUT) /, CYAN " & " RESET, line)

    # Highlight Status Codes
    gsub(/-> 200 /, GREEN "-> 200 " RESET, line)
    gsub(/-> (4[0-9][0-9]|5[0-9][0-9]) /, RED "-> & " RESET, line)
    gsub(/status: 200/, GREEN "status: 200" RESET, line)
    gsub(/status: (4[0-9][0-9]|5[0-9][0-9])/, RED "&" RESET, line)

    # Highlight Upstream and Latency
    gsub(/Upstream: [^|]+/, YELLOW "&" RESET, line)
    gsub(/latency: [0-9.]+s/, MAGENTA "&" RESET, line)
    gsub(/ttfb: [0-9.]+s/, MAGENTA "&" RESET, line)

    # Highlight Size
    gsub(/Size: [^|]+/, BLUE "&" RESET, line)

    print line
    fflush()
}
'
