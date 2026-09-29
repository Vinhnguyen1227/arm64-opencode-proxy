#!/usr/bin/env bash
set -e

TARGET_URL="${1:-http://localhost:8080}"
API_KEY="${2:-sk-userA-vkey-001}"
MODEL="${3:-gpt-6-sol}"

GREEN="\033[1;32m"
RED="\033[1;31m"
CYAN="\033[1;36m"
RESET="\033[0m"

echo -e "${CYAN}Target URL: $TARGET_URL${RESET}"
echo -e "${CYAN}API Key   : $API_KEY${RESET}"
echo -e "${CYAN}Model     : $MODEL${RESET}"
echo ""

PASSED=0
FAILED=0

assert_result() {
    local name="$1"
    local condition="$2"
    local details="$3"
    if [ "$condition" -eq 1 ]; then
        echo -e "  ${GREEN}[PASS]${RESET} $name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${RESET} $name"
        [ -n "$details" ] && echo -e "         $details"
        FAILED=$((FAILED + 1))
    fi
}

echo "[1/7] Testing Healthcheck (GET /healthz)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/healthz" || true)
assert_result "Healthcheck returns 200 OK" $([ "$STATUS" = "200" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[2/7] Testing Auth Enforcement with invalid key..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid-key-xyz" "$TARGET_URL/v1/models" || true)
assert_result "Rejected invalid key with 401" $([ "$STATUS" = "401" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[3/7] Testing CORS Preflight (OPTIONS /responses)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS "$TARGET_URL/responses" || true)
assert_result "CORS preflight returns 204" $([ "$STATUS" = "204" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[4/7] Testing Models Discovery (GET /models)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" "$TARGET_URL/models" || true)
assert_result "Models returned via root rewrite /models" $([ "$STATUS" = "200" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[5/7] Testing Native OpenCode Responses (POST /responses)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TARGET_URL/responses" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"input\":\"ping\"}" || true)
assert_result "Native POST /responses returned 200 OK" $([ "$STATUS" = "200" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[6/7] Testing OpenCode Responses (POST /v1/responses)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TARGET_URL/v1/responses" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"input\":\"ping\"}" || true)
assert_result "POST /v1/responses returned 200 OK" $([ "$STATUS" = "200" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo "[7/7] Testing 35KB Payload Buffer (POST /responses)..."
PAYLOAD_FILE=$(mktemp)
python3 -c "
import json
filler = 'x' * 35000
data = {
    'model': '$MODEL',
    'input': 'schema test',
    'tools': [{'type': 'function', 'function': {'name': 'filler', 'description': filler, 'parameters': {'type': 'object'}}}]
}
print(json.dumps(data))
" > "$PAYLOAD_FILE" 2>/dev/null || {
    # Fallback if python3 not available
    printf '{"model":"%s","input":"%s"}' "$MODEL" "$(head -c 35000 < /dev/zero | tr '\0' 'a')" > "$PAYLOAD_FILE"
}

STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TARGET_URL/responses" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE" || true)
rm -f "$PAYLOAD_FILE"
assert_result "35KB tool schema processed without buffer error" $([ "$STATUS" = "200" ] && echo 1 || echo 0) "Got HTTP $STATUS"

echo ""
echo "Test Results: $PASSED Passed, $FAILED Failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
