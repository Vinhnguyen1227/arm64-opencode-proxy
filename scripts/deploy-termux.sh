#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# ARM64 AI Reverse Proxy - Termux Deployment Script
# Target: Android ARM64 (Samsung / Termux)
# ==============================================================================

set -e

echo "[*] Step 1: Updating packages and installing prerequisites..."
# Use apt directly to bypass pkg/curl bootstrap library mismatch
apt update -y || pkg update -y
apt install -y nginx gettext net-tools || pkg install -y nginx gettext net-tools

echo "[*] Step 2: Enabling Android Wake-Lock..."
termux-wake-lock
echo "[+] Wake-lock acquired. (Ensure Termux battery is set to Unrestricted in Android Settings)"

echo "[*] Step 3: Loading configuration from .env..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/../.env" | xargs)
    echo "[+] Loaded environment from $SCRIPT_DIR/../.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
    echo "[+] Loaded environment from $SCRIPT_DIR/.env"
else
    echo "[!] Warning: .env file not found, using fallback defaults."
fi

# Set defaults
export PORT="${PORT:-8080}"
export UPSTREAM_HOST="${UPSTREAM_HOST:-api.vilao.ai}"
export UPSTREAM_PORT="${UPSTREAM_PORT:-443}"
export UPSTREAM_SCHEME="${UPSTREAM_SCHEME:-https}"
export USER_A_KEY="${USER_A_KEY:-sk-userA-vkey-001}"
export USER_B_KEY="${USER_B_KEY:-sk-userB-vkey-002}"
export MIMO_API_KEY="${MIMO_API_KEY:-tp-placeholder-key}"

echo "[*] Upstream Target: ${UPSTREAM_SCHEME}://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo "[*] Listening Port : $PORT"

echo "[*] Step 4: Generating Nginx configuration for Termux..."
NGINX_CONF_DIR="$PREFIX/etc/nginx"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$PREFIX/var/log/nginx"

# Generate standalone Termux nginx.conf containing events, http, and our proxy blocks
cat << 'EOF' > "$NGINX_CONF_DIR/nginx.conf.raw"
worker_processes auto;
daemon on;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    # Fix Nginx map_hash_bucket_size error on ARM64 / Termux for long Bearer tokens
    map_hash_bucket_size 128;
    map_hash_max_size 2048;

    # Map virtual authorization keys to valid flag
    map $http_authorization $auth_valid {
        default 0;
        "Bearer ${USER_A_KEY}" 1;
        "Bearer ${USER_B_KEY}" 1;
    }

    # Map Content-Type: fallback to application/json if empty or missing
    map $content_type $outbound_content_type {
        default $content_type;
        ""      "application/json";
    }

    # Dual-stream log format: INBOUND (client) + OUTBOUND (upstream & response)
    log_format proxy_debug '[$time_local] id=$request_id | '
                           '[INBOUND] client=$remote_addr (cf_ip=$http_cf_connecting_ip) '
                           'method=$request_method uri="$request_uri" '
                           'auth="$http_authorization" ua="$http_user_agent" '
                           'content_type="$content_type" len=$content_length '
                           'body="$request_body" | '
                           '[OUTBOUND] upstream=$upstream_addr status=$upstream_status '
                           'connect_time=${upstream_connect_time}s ttfb=${upstream_header_time}s stream_time=${upstream_response_time}s '
                           'client_status=$status bytes_sent=$body_bytes_sent total_time=${request_time}s';

    access_log /data/data/com.termux/files/usr/var/log/nginx/access.log proxy_debug;
    error_log  /data/data/com.termux/files/usr/var/log/nginx/error.log warn;

    server {
        listen ${PORT};
        server_name _;
        default_type application/json;
        client_body_buffer_size 1M;
        client_max_body_size 50M;

        location = /healthz {
            return 200 '{"status":"ok","engine":"nginx","port":"${PORT}"}\n';
        }

        location /v1/ {
            if ($request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' '*' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
                add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept' always;
                add_header 'Content-Type' 'text/plain; charset=utf-8';
                add_header 'Content-Length' 0;
                return 204;
            }

            if ($auth_valid = 0) {
                return 401 '{"error":{"message":"Invalid Virtual API Key. Unauthorized proxy access.","type":"invalid_request_error","code":"invalid_api_key"}}\n';
            }

            proxy_pass ${UPSTREAM_SCHEME}://${UPSTREAM_HOST}:${UPSTREAM_PORT};
            proxy_ssl_server_name on;
            proxy_ssl_name ${UPSTREAM_HOST};
            proxy_ssl_protocols TLSv1.2 TLSv1.3;

            proxy_pass_request_body on;
            proxy_set_header Host ${UPSTREAM_HOST};
            proxy_set_header Authorization "Bearer ${MIMO_API_KEY}";
            proxy_set_header User-Agent "opencode/1.18.21 ai-sdk/...";
            proxy_set_header Content-Type $outbound_content_type;
            proxy_set_header Accept $http_accept;
            proxy_set_header X-Request-ID $request_id;
            add_header X-Request-ID $request_id always;

            proxy_set_header X-Forwarded-For "";
            proxy_set_header X-Real-IP "";
            proxy_set_header X-Forwarded-Proto "";
            proxy_set_header X-Forwarded-Host "";

            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_cache off;
            chunked_transfer_encoding on;

            proxy_connect_timeout 60s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
        }

        location / {
            return 404 '{"error":{"message":"Not Found. Use /v1 endpoints.","type":"invalid_request_error","code":"not_found"}}\n';
        }
    }
}
EOF

# Safely substitute only our configuration variables while preserving Nginx internal variables
envsubst '$PORT $UPSTREAM_HOST $UPSTREAM_PORT $UPSTREAM_SCHEME $MIMO_API_KEY $USER_A_KEY $USER_B_KEY' < "$NGINX_CONF_DIR/nginx.conf.raw" > "$NGINX_CONF_DIR/nginx.conf"
rm -f "$NGINX_CONF_DIR/nginx.conf.raw"

echo "[*] Step 5: Testing Nginx syntax..."
nginx -t

echo "[*] Step 6: Launching Nginx server..."
nginx -s reload 2>/dev/null || nginx

# Discover Wi-Fi IP address
WLAN_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' || true)
if [ -z "$WLAN_IP" ]; then
    WLAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "PHONE_IP")
fi

echo ""
echo "======================================================================"
echo "[+] Nginx AI Reverse Proxy successfully running on ARM64!"
echo "    Local Endpoint : http://localhost:$PORT/v1"
echo "    Network BaseURL: http://$WLAN_IP:$PORT/v1"
echo ""
echo "    User A Key: $USER_A_KEY"
echo "    User B Key: $USER_B_KEY"
echo "======================================================================"
