#!/data/data/com.termux/files/usr/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_DIR/.env" ]; then
    export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/var/log/proxy.log"

if [ -f "$LOG_FILE" ]; then
    tail -n 10 "$LOG_FILE"
else
    echo "[Notice: No log file found at $LOG_FILE]"
fi

echo ""
echo "Credit usage:"

node -e '
  const fs = require("fs");
  const path = require("path");
  const ledgerFile = process.argv[1];
  let ledger = {};
  try {
    if (fs.existsSync(ledgerFile)) {
      ledger = JSON.parse(fs.readFileSync(ledgerFile, "utf8"));
    }
  } catch {}

  const now = new Date();
  const period = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;

  const users = [
    { name: "userA", key: process.env.USER_A_KEY || "sk-userA-vkey-001" },
    { name: "userB", key: process.env.USER_B_KEY || "sk-userB-vkey-002" },
    { name: "userC", key: process.env.USER_C_KEY || "sk-userC-vkey-003" }
  ];

  for (const u of users) {
    const usage = ledger[`${u.key}:${period}`] || 0;
    console.log(`${u.name}: ${usage.toLocaleString()} / 2B`);
  }
' "$REPO_DIR/data/credits_ledger.json"
