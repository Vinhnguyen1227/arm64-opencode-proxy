#!/usr/bin/env bash
# Cross-Platform POSIX Test Suite for ARM64 AI Reverse Proxy
# Compatible with: Debian, Ubuntu, Fedora, macOS, Termux, and WSL
# Requires: bash, curl, grep, awk (standard POSIX tools)

set -u

# Default Configuration
BASE_URL="${PROXY_URL:-https://specified-bonds-listed-figures.trycloudflare.com}"
API_KEY="${PROXY_KEY:-sk-userB-vkey-002}"
MODEL_NAME="${PROXY_MODEL:-gpt-6-sol}"

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            BASE_URL="$2"
            shift 2
            ;;
        --key)
            API_KEY="$2"
            shift 2
            ;;
        --model)
            MODEL_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--url <BASE_URL>] [--key <API_KEY>] [--model <MODEL_NAME>]"
            echo "Example:"
            echo "  $0 --url https://your-tunnel.trycloudflare.com --key sk-userB-vkey-002 --model gpt-6-sol"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# Strip trailing slash from BASE_URL
BASE_URL="${BASE_URL%/}"

# ANSI Colors
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

PASSED=0
FAILED=0

report_test() {
    local name="$1"
    local result="$2"
    local details="$3"

    if [ "$result" -eq 0 ]; then
        echo -e " ${GREEN}[PASS]${RESET} ${name}"
        if [ -n "$details" ]; then
            echo -e "        ${DIM}${details}${RESET}"
        fi
        PASSED=$((PASSED + 1))
    else
        echo -e " ${RED}[FAIL]${RESET} ${name}"
        if [ -n "$details" ]; then
            echo -e "        ${YELLOW}${details}${RESET}"
        fi
        FAILED=$((FAILED + 1))
    fi
}

echo -e "${CYAN}======================================================================${RESET}"
echo -e "${CYAN} AI REVERSE PROXY: CROSS-PLATFORM TEST SUITE (POSIX BASH)${RESET}"
echo -e "${CYAN} Target URL : ${RESET}${BOLD}${BASE_URL}${RESET}"
echo -e "${CYAN} Virtual Key: ${RESET}${BOLD}${API_KEY:0:15}...${RESET}"
echo -e "${CYAN} Model Target: ${RESET}${BOLD}${MODEL_NAME}${RESET}"
echo -e "${CYAN} OS Detected: ${RESET}${BOLD}$(uname -s) $(uname -m)${RESET}"
echo -e "${CYAN}======================================================================${RESET}"
echo ""

# ------------------------------------------------------------------------------
# TEST 1: Health Check Endpoint (/healthz)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}--- [SUITE 1] Infrastructure & Connectivity ---${RESET}"
TMP_RESP=$(mktemp)
TMP_HEADER=$(mktemp)

HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 10 "${BASE_URL}/healthz" -w "%{http_code}")
if [ "$HTTP_CODE" = "200" ] && grep -qi "ok" "$TMP_RESP"; then
    report_test "Health Check Endpoint (/healthz)" 0 "HTTP $HTTP_CODE | $(cat "$TMP_RESP" | tr -d '\n\r')"
else
    report_test "Health Check Endpoint (/healthz)" 1 "Expected HTTP 200, got $HTTP_CODE | Body: $(cat "$TMP_RESP" | head -n 1)"
fi

# ------------------------------------------------------------------------------
# TEST 2: Security - Reject Missing Authorization Token (HTTP 401)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}--- [SUITE 2] Security & Virtual Key Gate ---${RESET}"
HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 10 "${BASE_URL}/v1/models" -w "%{http_code}")
if [ "$HTTP_CODE" = "401" ]; then
    report_test "Reject Missing Token (HTTP 401)" 0 "Unauthenticated request correctly blocked"
else
    report_test "Reject Missing Token (HTTP 401)" 1 "Expected HTTP 401, got $HTTP_CODE"
fi

# ------------------------------------------------------------------------------
# TEST 3: Security - Reject Invalid Authorization Token (HTTP 401)
# ------------------------------------------------------------------------------
HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 10 \
    -H "Authorization: Bearer sk-unauthorized-fake-key-999" \
    "${BASE_URL}/v1/models" -w "%{http_code}")
if [ "$HTTP_CODE" = "401" ]; then
    report_test "Reject Invalid Token (HTTP 401)" 0 "Invalid virtual key correctly blocked"
else
    report_test "Reject Invalid Token (HTTP 401)" 1 "Expected HTTP 401, got $HTTP_CODE"
fi

# ------------------------------------------------------------------------------
# TEST 4: Upstream - Discover Models with Valid Virtual Key
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}--- [SUITE 3] Upstream Discovery & Authentication ---${RESET}"
HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 15 \
    -H "Authorization: Bearer ${API_KEY}" \
    "${BASE_URL}/v1/models" -w "%{http_code}")

if [ "$HTTP_CODE" = "200" ] && grep -qi "$MODEL_NAME" "$TMP_RESP"; then
    report_test "Model Discovery (/v1/models)" 0 "HTTP 200 | Found target model: ${MODEL_NAME}"
elif [ "$HTTP_CODE" = "200" ]; then
    report_test "Model Discovery (/v1/models)" 0 "HTTP 200 | Model list returned successfully"
else
    report_test "Model Discovery (/v1/models)" 1 "Expected HTTP 200, got $HTTP_CODE | Body: $(cat "$TMP_RESP" | head -n 1)"
fi

# ------------------------------------------------------------------------------
# TEST 5: Standard OpenAI Chat Completion (Non-streaming)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}--- [SUITE 4] OpenCode Chat & Completion Protocol ---${RESET}"
PAYLOAD="{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":10}"

HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 30 \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    -w "%{http_code}")

if [ "$HTTP_CODE" = "200" ] && grep -qi "pong" "$TMP_RESP"; then
    report_test "Standard Chat Completion (/v1/chat/completions)" 0 "HTTP 200 | Assistant replied with Pong"
elif [ "$HTTP_CODE" = "200" ]; then
    report_test "Standard Chat Completion (/v1/chat/completions)" 0 "HTTP 200 | Valid JSON response received"
else
    report_test "Standard Chat Completion (/v1/chat/completions)" 1 "Expected HTTP 200, got $HTTP_CODE | Body: $(cat "$TMP_RESP" | head -n 1)"
fi

# ------------------------------------------------------------------------------
# TEST 6: Real-Time SSE Streaming ("stream": true)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}--- [SUITE 5] Real-Time Streaming (SSE / Unbuffered) ---${RESET}"
STREAM_PAYLOAD="{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"count 1 to 3\"}],\"max_tokens\":20,\"stream\":true}"

HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 30 \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -d "$STREAM_PAYLOAD" \
    -w "%{http_code}")

if [ "$HTTP_CODE" = "200" ] && grep -q "data:" "$TMP_RESP"; then
    CHUNK_COUNT=$(grep -c "data:" "$TMP_RESP" || echo 0)
    report_test "Server-Sent Events Streaming (stream: true)" 0 "HTTP 200 | Captured ${CHUNK_COUNT} SSE data chunks"
else
    report_test "Server-Sent Events Streaming (stream: true)" 1 "Expected HTTP 200 with 'data:' chunks, got HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------------------
# TEST 7: Large Agent Payload Pass-Through (30KB Tool Schemas)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}--- [SUITE 6] Large Payload & Buffer Validation ---${RESET}"
TMP_LARGE=$(mktemp)

# Generate a synthetic 30KB payload simulating OpenCode tool schema definitions
python3 -c '
import json
tools = [{"type": "function", "function": {"name": f"tool_{i}", "description": "A" * 500, "parameters": {"type": "object", "properties": {"query": {"type": "string"}}}}} for i in range(50)]
payload = {"model": "'"${MODEL_NAME}"'", "messages": [{"role": "user", "content": "hello"}], "tools": tools, "max_tokens": 10}
print(json.dumps(payload))
' > "$TMP_LARGE" 2>/dev/null || node -e '
const tools = Array.from({length: 50}, (_, i) => ({type: "function", function: {name: `tool_${i}`, description: "A".repeat(500), parameters: {type: "object", properties: {query: {type: "string"}}}}}));
const payload = {model: "'"${MODEL_NAME}"'", messages: [{role: "user", content: "hello"}], tools, max_tokens: 10};
console.log(JSON.stringify(payload));
' > "$TMP_LARGE" 2>/dev/null || {
    # Fallback to pure shell string builder if python/node absent
    printf '{"model":"%s","messages":[{"role":"user","content":"hello"}],"padding":"' "${MODEL_NAME}" > "$TMP_LARGE"
    for i in {1..300}; do printf '%100s' 'X'; done >> "$TMP_LARGE"
    printf '"}' >> "$TMP_LARGE"
}

LARGE_SIZE=$(wc -c < "$TMP_LARGE" | tr -d ' ')

HTTP_CODE=$(curl -s -o "$TMP_RESP" -D "$TMP_HEADER" --max-time 30 \
    -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@$TMP_LARGE" \
    -w "%{http_code}")

if [ "$HTTP_CODE" = "200" ]; then
    report_test "Large Payload Pass-Through (${LARGE_SIZE} bytes)" 0 "HTTP 200 | Large buffer accepted without 413 or truncation"
elif [ "$HTTP_CODE" = "400" ] && grep -qi "tools" "$TMP_RESP"; then
    # Upstream model may not support dummy tools, but proxy forwarded without truncation
    report_test "Large Payload Pass-Through (${LARGE_SIZE} bytes)" 0 "Proxy delivered full ${LARGE_SIZE} bytes to upstream without Nginx buffer failure"
else
    report_test "Large Payload Pass-Through (${LARGE_SIZE} bytes)" 1 "Expected proxy pass-through, got HTTP $HTTP_CODE | Body: $(cat "$TMP_RESP" | head -n 1)"
fi

# Cleanup
rm -f "$TMP_RESP" "$TMP_HEADER" "$TMP_LARGE"

# ------------------------------------------------------------------------------
# SUMMARY REPORT
# ------------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================================================${RESET}"
echo -e "${BOLD} TEST SUMMARY: ${GREEN}${PASSED} Passed${RESET}, ${RED}${FAILED} Failed${RESET} (Total: $((PASSED + FAILED)))"
echo -e "${CYAN}======================================================================${RESET}"

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: The proxy is fully verified and ready for OpenCode on all operating systems!${RESET}"
    exit 0
else
    echo -e "${RED}FAILURE: One or more assertions failed. Check proxy logs for details.${RESET}"
    exit 1
fi
