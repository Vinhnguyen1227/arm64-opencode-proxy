# ARM64 OpenCode Reverse Proxy

High-performance reverse proxy for ARM64 Android (Termux) and Linux/Docker, engineered specifically for **OpenCode v2** and OpenAI-compatible inference providers.

Enables multiple local or remote developer clients (Linux/Debian, Windows, macOS) to multiplex through a single upstream account (e.g. `api.vilao.ai` / `gpt-6-sol`) over local Wi-Fi or Cloudflare Tunnel WAN.

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
  https://api.vilao.ai/v1/responses (gpt-6-sol)
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
│   ├── tunnel-termux.sh      # Cloudflare Tunnel WAN exposure
│   └── trace-live.sh         # Real-time colored telemetry monitor
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
MODEL_NAME=gpt-6-sol
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

### Step 3: (Optional) Public WAN Access via Cloudflare Tunnel
To connect from outside the local Wi-Fi:
```bash
bash scripts/tunnel-termux.sh
```
Cloudflare will assign an ephemeral public URL (e.g. `https://xxxx.trycloudflare.com`). Use this URL as `baseURL` in `opencode.json`.

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

## 6. Live Telemetry & Log Monitoring

Monitor incoming client calls and upstream metrics live on the phone:
```bash
bash scripts/trace-live.sh
```

**Output format**:
```text
[29/Sep/2026:09:15:20 +0700] id=a1b2c3d4 | POST /responses -> 200 | Client: 192.168.1.197 (cf: -, auth: Bearer sk-userB-vkey-002) | Upstream: 103.252.123.86:443 (status: 200, latency: 1.25s, ttfb: 0.85s) | Size: 34812B in / 1250B out
```

- **`id`**: Unique request identifier passed downstream and upstream (`X-Request-ID`).
- **`Method & URI`**: Client endpoint and returned HTTP status.
- **`Client`**: Client IP address and authenticated tenant virtual key.
- **`Upstream`**: Target IP, upstream status code, round-trip latency, and Time to First Token (`ttfb`).
- **`Size`**: Inbound payload size (e.g. 35KB tools schema) and outbound response size.

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
