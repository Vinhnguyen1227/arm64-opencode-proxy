#!/data/data/com.termux/files/usr/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/log/proxy.log"
touch "$LOG_FILE" 2>/dev/null || true

MODE="${1:-}"

case "$MODE" in
    --meter)
        echo "[Live Quota Meter Stream: $LOG_FILE]"
        tail -n 30 -F "$LOG_FILE" | grep --line-buffered "METER"
        ;;
    --errors)
        echo "[Live Error Log Stream: $LOG_FILE]"
        tail -n 30 -F "$LOG_FILE" | grep --line-buffered "ERROR"
        ;;
    --debug)
        echo "[Live Debug Log Stream: $LOG_FILE]"
        tail -n 30 -F "$LOG_FILE" | grep --line-buffered "DEBUG"
        ;;
    --trace)
        REQ_ID="$2"
        if [ -z "$REQ_ID" ]; then
            echo "Usage: bash scripts/trace-live.sh --trace <request_id>"
            exit 1
        fi
        echo "[Lifecycle Trace for request_id: $REQ_ID]"
        grep -h "\[$REQ_ID" "$LOG_FILE" 2>/dev/null || echo "No logs found for $REQ_ID"
        ;;
    --help|-h)
        echo "Usage: bash scripts/trace-live.sh [OPTION]"
        echo "Options:"
        echo "  (no args)          Stream all live gateway logs"
        echo "  --meter            Stream credit quota deductions only"
        echo "  --errors           Stream error diagnostics only"
        echo "  --trace <id>       Filter full request lifecycle by request ID"
        ;;
    *)
        echo "[Live Gateway Log Stream: $LOG_FILE]"
        tail -n 30 -F "$LOG_FILE"
        ;;
esac
