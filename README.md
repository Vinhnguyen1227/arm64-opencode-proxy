# ARM64 proxy for OpenAI compatiable api

Reverse proxy using **Nginx** for ARM64 hardware (Android/Termux or Docker). Avoid single token plan constraint by multiplexing multiple downstream clients (via VS Code, OpenCode, Cursor, NextChat) through a single upstream provider account (any OpenAI-compatible provider).

The proxy strips client network fingerprints, isolates tenants with virtual keys, injects canonical `opencode/1.18.21` telemetry, and streams encrypted HTTPS responses.

---

## 1. System Architecture & Traffic Flow

```text
┌─────────────────────────┐
│ User A: OpenCode / IDE  │ (Plaintext HTTP + sk-userA-key)
└────────────┬────────────┘
             │                                  ARM64 Phone / Termux (192.168.22.61:8080)
             ├──────────────────────────────► ┌──────────────────────────────────────────┐
             │                                │ 1. Ingress: Listen on 0.0.0.0:8080       │
┌────────────┴────────────┐                   │ 2. Auth Gate: Validate virtual key       │
│ User B: OpenCode / IDE  │ (Plaintext HTTP)  │ 3. Strip: Drop X-Forwarded-For, Real-IP  │
└─────────────────────────┘                   │ 4. Rewrite: Force opencode User-Agent    │
                                              │ 5. Egress TLS: Establish HTTPS Handshake │
                                              └────────────────────┬─────────────────────┘
                                                                   │
                                       (Encrypted HTTPS + Master Key + Canonical Headers)
                                                                   ▼
                                              ┌──────────────────────────────────────────┐
                                              │ Upstream AI Provider                     │
                                              │ (api.vilao.ai / MiMo V2.5 / OpenAI API)  │
                                              └──────────────────────────────────────────┘
```

---

## 2. Repository Structure

```text
arm64-openai-proxy/
├── .env.example              # Environment variables template (safe defaults)
├── .gitignore                # Git exclusions (strictly blocks secrets)
├── docker-compose.yml        # Multi-arch Docker runner (ARM64/AMD64)
├── README.md                 # Master architecture & deployment guide
│
├── config/                   # Configuration files & templates
│   ├── nginx.conf.template   # Dynamic Nginx proxy template
│   ├── opencode.json         # Client configuration (local Wi-Fi)
│   └── opencode.json.example # OpenCode client configuration template
│
├── scripts/                  # Deployment & operational scripts
│   └── deploy-termux.sh      # 1-click Termux ARM64 installer (with wake-lock)
│
└── tests/                    # Testing harnesses & mocks
    ├── mock-upstream.js      # Mock API server with header inspection
    ├── test-payload.json     # Sample cURL JSON payload
    ├── test-proxy.ps1        # Proxy assertion script
    └── verify-traffic.ps1    # 8-point automated test harness
```

---

## 3. How the Encrypt / Decrypt Pipeline Works

The proxy operates as a **TLS Termination and Bridging Gateway**:

### Downstream: Plaintext HTTP (Local Wi-Fi)
* **Path**: Developer PC (OpenCode / VS Code) ➔ Phone Proxy (`http://192.168.22.61:8080`).
* **Protocol**: Unencrypted HTTP/1.1 over local trusted Wi-Fi.
* **Why**:
  * Eliminates the need to generate, distribute, and trust custom self-signed SSL certificates on every developer machine.
  * Allows Nginx to inspect, validate, and rewrite headers in memory without breaking TLS encryption signatures.
  * Local Wi-Fi is protected behind home/office network firewalls.

### In-Memory Transformation (The Proxy Boundary)
Because Nginx receives the downstream request in plaintext, its rewrite engine:
1. Validates the virtual client token (`sk-userA-vkey-001`) via an O(1) hash map.
2. Strips client IP tracking headers (`X-Forwarded-For`, `X-Real-IP`, `X-Forwarded-Proto`).
3. Replaces the client token with the master upstream token (`MIMO_API_KEY`).
4. Overwrites the client `User-Agent` to the canonical string: `opencode/1.18.21 ai-sdk/...`.

### Upstream: Encrypted HTTPS (Public Internet)
* **Path**: Phone Proxy (Termux) ➔ Provider (`https://api.vilao.ai:443`).
* **Protocol**: Encrypted HTTPS (TLS 1.2 / TLS 1.3).
* **How Encryption Works**:
  * Nginx initiates a secure TLS handshake with the provider, negotiating AES-GCM or ChaCha20 cipher suites with SNI alignment (`proxy_ssl_server_name on`).
  * Nginx encrypts the rewritten request headers and body before sending them across the public internet.
  * To ISPs and eavesdroppers, all wire traffic is completely encrypted and indistinguishable from an official single-user OpenCode desktop client.

### Response Decryption & Zero-Buffering Streaming
* The upstream AI provider streams encrypted SSE (Server-Sent Events) tokens back to the phone.
* Nginx's OpenSSL layer **decrypts** the TLS records in real time.
* With `proxy_buffering off; chunked_transfer_encoding on;`, Nginx immediately pipes each plaintext chunk directly into the client's HTTP connection without waiting for the full response to finish.

---

## 3. Technology Stack & Engines

| Layer | Technology | Version / Details | Purpose |
| :--- | :--- | :--- | :--- |
| **Reverse Proxy** | **Nginx** | `v1.31.6` (Alpine & Termux ARM64) | Core routing, auth map, header rewriting, SSE proxy |
| **Mobile Runtime** | **Android / Termux** | ARM64 (`aarch64`) / Android 7.0+ | Hosts proxy on physical Samsung smartphone |
| **Process Daemon** | **termux-wake-lock** | Termux native API | Prevents Android OS Doze mode from sleeping TCP sockets |
| **Local Testing** | **Docker Desktop** | `nginx:alpine` + QEMU multi-arch | Emulates ARM64 container on Windows PC |
| **Templating** | **GNU envsubst** | `gettext` package | Injects environment variables into `nginx.conf` at boot |
| **Test Harness** | **Node.js & PowerShell** | Node.js v24 / PowerShell 5.1/7 | Automated 8-assertion unit testing & header inspection |
| **Downstream Client**| **OpenCode** | `sst-dev.opencode` / OpenCode v2 | AI coding agent in VS Code |
| **Upstream Target** | **Xiaomi MiMo / Hana**| `api.vilao.ai` (`hana/mimo-v2.5`) | Model inference provider |

---

## 4. Header Transformation Matrix

| Header | Inbound (from Client) | Outbound (to Provider) | Purpose |
| :--- | :--- | :--- | :--- |
| `Authorization` | `Bearer sk-userA-vkey-001` | `Bearer <OFFICIAL_MASTER_KEY>` | Masks individual user keys with single master credential |
| `User-Agent` | `Cursor/0.45` / variable | `opencode/1.18.21 ai-sdk/...` | Standardizes telemetry signature to 1 user |
| `Host` | `<PHONE_IP>:8080` | `api.vilao.ai` | Aligns SNI and virtual host |
| `X-Forwarded-For` | Client IP (`192.168.x.x`) | *Dropped (Empty)* | Prevents leaking downstream network topology |
| `X-Real-IP` | Client IP | *Dropped (Empty)* | Prevents leaking developer workstation IP |
| `Content-Type` | `application/json` | `application/json` | Transparent payload pass-through |

---

## 6. Verification & Test Evidence

### A. Windows Docker ARM64 Automated Test Suite
Ran [`verify-traffic.ps1`](file:///d:/proxy-test/tests/verify-traffic.ps1):
```text
======================================================================
 AI REVERSE PROXY: TRAFFIC & HEADER INSPECTION TEST HARNESS
======================================================================
--- [SUITE 1] Downstream Auth Gate ---
 [PASS] Health Endpoint (/healthz) (Engine: nginx, Port: 8080)
 [PASS] Reject Missing Token (HTTP 401 Unauthorized)
 [PASS] Reject Invalid Token (HTTP 401 Unauthorized)

--- [SUITE 2] Live Upstream (api.vilao.ai - hana/mimo-v2.5) ---
 [PASS] Live Upstream Model Listing (Discovered model: mimo-v2.5 via User A key)
 [PASS] Live Chat Completion via User B (Response: TEST_OK)

--- [SUITE 3] Canonical Header Assertion via Mock Server ---
 [PASS] Upstream User-Agent Canonicalized:
        Inbound: Cursor/0.45.2 -> Outbound to Upstream: opencode/1.18.21 ai-sdk/...
 [PASS] Master API Key Injected:
        Inbound: sk-userA-vkey-001 -> Outbound: Bearer sk-235b...
 [PASS] Client IP Tracking Dropped:
        X-Forwarded-For: <DROPPED>, X-Real-IP: <DROPPED>
======================================================================
 SUMMARY: 8 Passed, 0 Failed
======================================================================
```

### B. Physical Samsung Android ARM64 Phone Live Test
Request dispatched from PC across local Wi-Fi to phone (`192.168.22.61:8080`):
```powershell
curl.exe -i -H "Authorization: Bearer sk-userA-vkey-001" http://192.168.22.61:8080/v1/models
```
**Upstream Response (HTTP 200 OK from Hana Gateway via Phone):**
```http
HTTP/1.1 200 OK
Server: nginx/1.31.6
Content-Type: application/json; charset=utf-8

{"data":[{"active":true,"id":"mimo-v2.5","model_id":"mimo-v2.5","provider_prefix":"hana"}],"object":"list"}
```

---

## 7. Deployment Guides

### Option 1: Physical Phone Deployment (Termux ARM64)
1. Install Termux APK from [GitHub Releases](https://github.com/termux/termux-app/releases) (*not Google Play Store*).
2. Set Termux battery to **Unrestricted** in Android Settings.
3. Clone or copy repo to Termux and run:
   ```bash
   chmod +x scripts/deploy-termux.sh
   ./scripts/deploy-termux.sh
   ```
4. Script installs Nginx, activates wake-lock, starts the daemon, and prints the phone Wi-Fi IP address.

### Option 2: Local Windows Testing (Docker Compose)
1. Launch container:
   ```powershell
   docker compose up -d
   ```
2. Verify container architecture:
   ```powershell
   docker exec mimo-nginx-proxy uname -m
   # Output: aarch64
   ```

---

## 8. Connecting OpenCode in VS Code

Copy [`config/opencode.json.example`](file:///d:/proxy-test/config/opencode.json.example) into your project root as `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "mimo": {
      "name": "Xiaomi MiMo (Phone Proxy)",
      "npm": "@ai-sdk/openai",
      "options": {
        "baseURL": "http://192.168.22.61:8080/v1",
        "apiKey": "sk-userA-vkey-001"
      },
      "models": {
        "hana/mimo-v2.5": {
          "id": "hana/mimo-v2.5",
          "name": "MiMo 2.5 (Phone Proxy)"
        }
      }
    }
  },
  "model": "mimo/hana/mimo-v2.5"
}
```

In OpenCode TUI, type `/model` and select `mimo/hana/mimo-v2.5`. All chat completions will route through the proxy phone.

---

## 9. Real-Time Telemetry & Log Tracing

In Termux on your phone, watch incoming and outgoing traffic live:

```bash
tail -f $PREFIX/var/log/nginx/access.log
```

**Log Format**:
```text
192.168.22.63 - [23/Sep/2026:08:48:07 +0000] "POST /v1/chat/completions HTTP/1.1" 200
  downstream_ua: "opencode/1.18.21"
  downstream_auth: "Bearer sk-userA-vkey-001"
  upstream_host: "api.vilao.ai"
  upstream_addr: "103.252.123.86:443"
  upstream_status: "200"
  upstream_time: "1.420"
```

