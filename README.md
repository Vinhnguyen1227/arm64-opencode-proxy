# ARM64 OpenCode Reverse Proxy

Reverse proxy for ARM64 Android (Termux) and Linux/Docker for **OpenCode v2** and OpenAI-compatible inference providers.

Enables multiple developer clients to multiplex through a single upstream account over Ngrok WAN tunnel.

---

## 1. System Architecture & Traffic Flow

```text
[OpenCode Client - Linux / Win / Mac]
  │  (Plaintext HTTP + Virtual Key: sk-userA / sk-userB)
  │  POST /responses (with 35KB tool schemas) OR /v1/responses
  ▼
[ARM64 Reverse Proxy - Termux / Docker]
  │  1. Ingress: Listen on port 8080 (1MB memory buffer)
  │  2. Path Unification: rewrite ^/(responses|chat/completions|models|embeddings) -> /v1/$1
  │  3. Tenant Auth Gate: O(1) virtual key validation (401 on unauthorized)
  │  4. Privacy Scrub: Drop X-Forwarded-For, X-Real-IP, tracking headers
  │  5. Header Injection: Inject master MIMO_API_KEY + opencode User-Agent
  │  6. Zero-Buffer Egress: HTTP/1.1 SSE chunked streaming
  ▼
[Upstream AI Provider]
  https://api/v1/responses (gpt-6-sol)
```

---

## 2. OpenCode Architecture & Protocol Resolution

### The Debian / OpenCode Dilemma
OpenCode v2 differs from standard REST tools:
1. **Native Agent Protocol**: OpenCode dispatches tool-calling requests to `POST /responses` (not `/chat/completions`), sending 35KB–50KB schema definitions per turn.
2. **Path Variance**:
   - `baseURL: "http://host:8080"` dispatches to `POST /responses`.
   - `baseURL: "http://host:8080/v1"` dispatches to `POST /v1/responses`.
   - Generic proxies lacking root `/responses` routing return `404 Not Found`.
3. **Background Daemon Socket Stalling**:
   OpenCode runs a background daemon (`opencode service`). When a request encounters a 404 or connection error, the daemon enters a retry loop (`[retrying in 3s #2]`) and caches the failed socket. Subsequent edits to `opencode.json` are ignored until the daemon process is terminated (`pkill -f opencode`).

### The Proxy Solution
- **Path Rewrite Rule**:
  ```nginx
  rewrite ^/(responses|chat/completions|models|embeddings)(.*)$ /v1/$1$2 last;
  ```
  Both `POST /responses` and `POST /v1/responses` resolve to upstream `/v1/responses` identically.
- **Large Memory Buffer**:
  `client_body_buffer_size 1M;` holds 35KB–50KB OpenCode tool schemas completely in RAM, avoiding disk write overhead on mobile flash storage.
- **Unbuffered SSE Streaming**:
  `proxy_buffering off; chunked_transfer_encoding on;` streams generation tokens instantly to the client terminal with minimal latency.

---

## 3. Repository Structure

```text
arm64-opencode-proxy/
├── .env.example              # Environment variables template
├── .gitignore                # Git exclusions
├── docker-compose.yml        # Docker runner (mounts single-source template)
├── README.md                 # System documentation & deployment guide
│
├── config/
│   ├── nginx.conf.template   # Single source of truth Nginx configuration
│   ├── opencode.json         # Active OpenCode configuration
│   └── opencode.json.example # OpenCode configuration template
│
├── scripts/
│   ├── deploy-termux.sh      # 1-command installer for Termux ARM64
│   ├── tunnel-ngrok.sh       # Permanent Ngrok Tunnel WAN launcher
│   └── trace-live.sh         # Real-time multi-layer telemetry monitor
│
└── tests/
    ├── test-opencode.sh      # POSIX 7-point assertion test suite
    └── test-opencode.ps1     # Windows PowerShell test harness
```

---

## 4. Setup & Deployment

### Step 1: Configure Environment
Copy `.env.example` to `.env` and configure your credentials:
```bash
cp .env.example .env
```
Edit `.env`:
```env
PORT=8080
UPSTREAM_HOST=api.vilao.ai
UPSTREAM_PORT=443
UPSTREAM_SCHEME=https
MIMO_API_KEY=sk-your-upstream-secret-key
USER_A_KEY=sk-userA-vkey-001
USER_B_KEY=sk-userB-vkey-002
MODEL_NAME=vgpt/gpt-6-sol
```

---

### Step 2: Deploy on Android Phone (Termux ARM64)
1. Install Termux from [GitHub Releases](https://github.com/termux/termux-app/releases) and set battery usage to **Unrestricted** in Android Settings.
2. In Termux, run:
   ```bash
   pkg install -y git
   git clone https://github.com/Vinhnguyen1227/arm64-opencode-proxy.git
   cd arm64-opencode-proxy
   cp .env.example .env
   # Edit .env with your MIMO_API_KEY
   bash scripts/deploy-termux.sh
   ```
3. The script configures Nginx, enables `termux-wake-lock`, starts the service, and outputs the local Wi-Fi IP (e.g. `http://192.168.22.87:8080`).

---

### Step 3: (Optional) Permanent WAN Access via Ngrok
To connect from outside the local Wi-Fi using your permanent domain:
```bash
bash scripts/tunnel-ngrok.sh
```
Requires `NGROK_AUTHTOKEN` and `NGROK_DOMAIN` defined in your `.env`.

---

### Step 4: Alternative Deployment (Docker)
On any Docker-enabled host:
```bash
docker compose up -d
```

---

## 5. Client Configuration (OpenCode)

Create or update `opencode.json` (or `~/.config/opencode/config.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "phone-proxy": {
      "name": "OpenCode ARM64 Reverse Proxy",
      "npm": "@ai-sdk/openai",
      "options": {
        "baseURL": "http://192.168.22.87:8080",
        "apiKey": "sk-userA-vkey-001"
      },
      "models": {
        "gpt-6-sol": {
          "name": "GPT-6 Sol (Phone Proxy)"
        },
        "vgpt/gpt-6-sol": {
          "name": "GPT-6 Sol (vgpt/gpt-6-sol)"
        }
      }
    }
  },
  "model": "phone-proxy/gpt-6-sol"
}
```

> **Note**: Both `"baseURL": "http://192.168.22.87:8080"` and `"baseURL": "http://192.168.22.87:8080/v1"` are supported seamlessly.

---

## 6. Multi-Layer Logging & Diagnostics

Logging is organized into 3 distinct operational layers with request correlation:

### Log Layers

1. **Layer 1: Access Log** (`access.log`):
   One compact record per completed client request. Used as the standard live trace log.
   ```text
   [30/Sep/2026:15:10:05 +0700] INFO  [7f3a91bc] POST /responses -> api.vilao.ai 200 0.42s auth=userA req=34812B resp=1250B
   ```
2. **Layer 2: Error Log** (`error_layer.log`):
   Emitted *only* when a request fails or encounters abnormal conditions with stable error codes (`PX001` - `PX012`).
   ```text
   [30/Sep/2026:15:11:12 +0700] ERROR [e4b1089a] error_code=PX011 error=AUTH_UNAUTHORIZED upstream=local-proxy auth=unauthorized client=192.168.22.87 duration=0.001s
   ```
3. **Layer 3: Debug Log** (`debug.log`):
   Internal execution trace containing matched route, upstream address, auth flag, connection timings, and TTFB.
   ```text
   [30/Sep/2026:15:10:05 +0700] DEBUG [7f3a91bc] route=/responses upstream=103.252.123.86:443 auth_valid=1 client=192.168.22.87 ttfb=0.85s connect_time=0.045s
   ```

### Live Log Streaming (Pure White Text)

Stream logs in Termux or terminal:
```bash
# Standard live access trace (Layer 1)
bash scripts/trace-live.sh

# Errors only (Layer 2)
bash scripts/trace-live.sh --errors

# Debug / internal details (Layer 3)
bash scripts/trace-live.sh --debug

# Interleaved all layers
bash scripts/trace-live.sh --all

# Reconstruct full lifecycle for a specific request ID
bash scripts/trace-live.sh --trace 7f3a91bc
```

---

## 7. Verification & Automated Test Harness

### On Windows Workstation (PowerShell)
```powershell
.\tests\test-opencode.ps1 -TargetUrl "http://192.168.22.87:8080" -ApiKey "sk-userA-vkey-001" -Model "gpt-6-sol"
```

### On Linux / Debian / macOS / Termux (POSIX Bash)
```bash
bash tests/test-opencode.sh "http://192.168.22.87:8080" "sk-userB-vkey-002" "gpt-6-sol"
```

**Test Suite Coverage (7 Assertions)**:
1. Healthcheck (`GET /healthz` -> 200 OK)
2. Tenant Auth Gate (Invalid keys rejected with 401)
3. CORS Preflight (`OPTIONS /responses` -> 204 No Content)
4. Model Discovery (`GET /models` unified rewrite -> 200 OK)
5. Native OpenCode (`POST /responses` -> 200 OK)
6. Standard OpenCode (`POST /v1/responses` -> 200 OK)
7. 35KB Tool Schema Payload Buffer Handling (No 413 or disk spill)

---

## 8. Debian Client Troubleshooting

If OpenCode on Debian reports connection errors:
1. **Kill Stale Background Daemons**:
   ```bash
   pkill -f opencode
   ```
2. **Verify Connectivity**:
   ```bash
   curl -I http://192.168.22.87:8080/healthz
   ```
3. **Verify Upstream via curl**:
   ```bash
   curl -s -X POST http://192.168.22.87:8080/responses \
     -H "Authorization: Bearer sk-userB-vkey-002" \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-6-sol","input":"ping"}'
   ```
4. Restart `opencode` in your project workspace.
