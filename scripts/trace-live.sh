#!/data/data/com.termux/files/usr/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

LOG_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/log/nginx"
ACCESS_LOG="${ACCESS_LOG_PATH:-$LOG_DIR/access.log}"
ERROR_LOG="${ERROR_LOG_PATH:-$LOG_DIR/error_layer.log}"
DEBUG_LOG="${DEBUG_LOG_PATH:-$LOG_DIR/debug.log}"

mkdir -p "$LOG_DIR"
touch "$ACCESS_LOG" "$ERROR_LOG" "$DEBUG_LOG"

MODE="${1:-}"

case "$MODE" in
    --errors)
        echo "[Live Error Log Stream: $ERROR_LOG]"
        tail -n 20 -F "$ERROR_LOG"
        ;;
    --debug)
        echo "[Live Debug Log Stream: $DEBUG_LOG]"
        tail -n 20 -F "$DEBUG_LOG"
        ;;
    --all)
        echo "[Live All Layers Stream: access, errors, debug]"
        tail -n 20 -F "$ACCESS_LOG" "$ERROR_LOG" "$DEBUG_LOG"
        ;;
    --trace)
        REQ_ID="$2"
        if [ -z "$REQ_ID" ]; then
            echo "Usage: bash scripts/trace-live.sh --trace <request_id>"
            exit 1
        fi
        echo "[Lifecycle Trace for request_id: $REQ_ID]"
        grep -h "\[$REQ_ID" "$DEBUG_LOG" "$ERROR_LOG" "$ACCESS_LOG" 2>/dev/null || echo "No logs found for $REQ_ID"
        ;;
    --help|-h)
        echo "Usage: bash scripts/trace-live.sh [OPTION]"
        echo "Options:"
        echo "  (no args)          Standard live access trace (Layer 1)"
        echo "  --errors           Stream error logs only (Layer 2)"
        echo "  --debug            Stream debug logs only (Layer 3)"
        echo "  --all              Stream all log layers interleaved"
        echo "  --trace <id>       Reconstruct full request lifecycle by request ID"
        ;;
    *)
        echo "[Live Access Log Stream: $ACCESS_LOG]"
        tail -n 20 -F "$ACCESS_LOG"
        ;;
esac
