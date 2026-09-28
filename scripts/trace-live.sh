#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Live HTTP Request / Response Trace Viewer for Termux Nginx Proxy
# ==============================================================================

LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/log/nginx/access.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "[!] Log file not found at $LOG_FILE"
    echo "[*] Creating empty log file..."
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
fi

echo "=============================================================================="
echo " Starting Live Dual-Stream Trace Monitor on $LOG_FILE"
echo " (Press Ctrl+C to stop)"
echo "=============================================================================="
echo ""

# Format and colorize log stream live
tail -n 20 -F "$LOG_FILE" | awk '
BEGIN {
    CYAN   = "\033[1;36m"
    GREEN  = "\033[1;32m"
    YELLOW = "\033[1;33m"
    RED    = "\033[1;31m"
    BOLD   = "\033[1m"
    RESET  = "\033[0m"
}
{
    print ""
    print BOLD "------------------------------------------------------------------------------" RESET
    
    # Highlight Inbound block
    gsub(/\[INBOUND\]/, CYAN "[INBOUND CLIENT]" RESET)
    
    # Highlight Outbound block
    gsub(/\[OUTBOUND\]/, GREEN "[OUTBOUND UPSTREAM]" RESET)
    
    # Highlight status codes
    gsub(/status=200/, GREEN "status=200" RESET)
    gsub(/status=4[0-9][0-9]/, RED "&" RESET)
    gsub(/status=5[0-9][0-9]/, RED "&" RESET)
    
    # Print formatted line
    print $0
    fflush()
}
'
