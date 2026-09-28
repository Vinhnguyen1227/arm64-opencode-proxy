# Comprehensive Traffic & Header Inspection Verification Script

param(
    [string]$ProxyUrl = "http://localhost:8080",
    [string]$UserAKey = "sk-userA-vkey-001",
    [string]$UserBKey = "sk-userB-vkey-002"
)

$passed = 0
$failed = 0

function Report-Assert {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host " [PASS] $Name" -ForegroundColor Green
        if ($Details) { Write-Host "        $Details" -ForegroundColor DarkGray }
        $script:passed++
    } else {
        Write-Host " [FAIL] $Name" -ForegroundColor Red
        if ($Details) { Write-Host "        $Details" -ForegroundColor Yellow }
        $script:failed++
    }
}

Write-Host "AI REVERSE PROXY: TRAFFIC & HEADER INSPECTION TEST HARNESS" -ForegroundColor Cyan

# TEST SUITE 1: Downstream Auth Gate & Health Check
Write-Host "`n[SUITE 1] Downstream Auth Gate" -ForegroundColor Yellow

# 1. Health check
try {
    $res = Invoke-RestMethod -Uri "$ProxyUrl/healthz" -Method GET -TimeoutSec 5
    Report-Assert "Health Endpoint (/healthz)" ($res.status -eq "ok") "Engine: $($res.engine), Port: $($res.port)"
} catch {
    Report-Assert "Health Endpoint (/healthz)" $false $_.Exception.Message
}

# 2. Block unauthenticated
try {
    $res = Invoke-RestMethod -Uri "$ProxyUrl/v1/models" -Method GET -TimeoutSec 5
    Report-Assert "Reject Missing Token" $false "Expected 401 Unauthorized"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Assert "Reject Missing Token" ($statusCode -eq 401) "Got HTTP 401 Unauthorized as expected"
}

# 3. Block invalid token
try {
    $headers = @{ "Authorization" = "Bearer sk-invalid-hacker-key" }
    $res = Invoke-RestMethod -Uri "$ProxyUrl/v1/models" -Headers $headers -Method GET -TimeoutSec 5
    Report-Assert "Reject Invalid Token" $false "Expected 401 Unauthorized"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Assert "Reject Invalid Token" ($statusCode -eq 401) "Got HTTP 401 Unauthorized as expected"
}

# TEST SUITE 2: Live Upstream Connection (api.vilao.ai - gpt-6-sol)
Write-Host "`n[SUITE 2] Live Upstream (api.vilao.ai)" -ForegroundColor Yellow

# 4. Live Model Listing via User A key
try {
    $headers = @{ "Authorization" = "Bearer $UserAKey" }
    $res = Invoke-RestMethod -Uri "$ProxyUrl/v1/models" -Headers $headers -Method GET -TimeoutSec 10
    $modelFound = ($res.data | Where-Object { $_.id -eq "gpt-6-sol" -or $_.id -eq "mimo-v2.5" }) -ne $null
    Report-Assert "Live Upstream Model Listing" ($modelFound -eq $true) "Discovered models via User A key"
} catch {
    Report-Assert "Live Upstream Model Listing" $false $_.Exception.Message
}

# 5. Live Chat Completion via User B key
try {
    $headers = @{
        "Authorization" = "Bearer $UserBKey"
        "Content-Type"  = "application/json"
    }
    $body = @{
        model    = "gpt-6-sol"
        messages = @(
            @{ role = "user"; content = "Respond with 'TEST_OK'." }
        )
        stream   = $false
    } | ConvertTo-Json -Compress

    $res = Invoke-RestMethod -Uri "$ProxyUrl/v1/chat/completions" -Headers $headers -Method POST -Body $body -TimeoutSec 15
    $reply = $res.choices[0].message.content
    Report-Assert "Live Chat Completion via User B" ($reply.Length -gt 0) "Response: $reply"
} catch {
    Report-Assert "Live Chat Completion via User B" $false $_.Exception.Message
}

# TEST SUITE 3: Canonical Header Inspection (Mock Upstream Server)
Write-Host "`n[SUITE 3] Canonical Header Assertion via Mock Server" -ForegroundColor Yellow

Write-Host "[*] Starting local mock upstream on port 9000..." -ForegroundColor DarkGray
$mockProc = Start-Process -FilePath "node" -ArgumentList "mock-upstream.js" -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 2

try {
    $clientHeaders = @{
        "Authorization"   = "Bearer $UserAKey"
        "User-Agent"      = "Cursor/0.45.2 (DownstreamDeveloperMachine)"
        "X-Forwarded-For" = "192.168.1.100"
        "X-Real-IP"       = "192.168.1.100"
        "Content-Type"    = "application/json"
    }

    $body = @{
        model    = "gpt-6-sol"
        messages = @(@{ role = "user"; content = "Inspect headers" })
        stream   = $false
    } | ConvertTo-Json -Compress

    $postRes = Invoke-RestMethod -Uri "$ProxyUrl/mock-v1/chat/completions" -Headers $clientHeaders -Method POST -Body $body -TimeoutSec 10

    $inspected = Invoke-RestMethod -Uri "http://localhost:9000/_inspect" -Method GET -TimeoutSec 5

    $receivedUA = $inspected.headers.'user-agent'
    $uaMatches = ($receivedUA -eq "opencode/1.18.21 ai-sdk/...")
    Report-Assert "Upstream User-Agent Canonicalized" $uaMatches "Inbound: Cursor/0.45.2 -> Outbound to Upstream: $receivedUA"

    $receivedAuth = $inspected.headers.'authorization'
    $authMatches = ($receivedAuth -match "^Bearer sk-")
    Report-Assert "Master API Key Injected" $authMatches "Inbound: $UserAKey -> Outbound: $receivedAuth"

    $xff = $inspected.headers.'x-forwarded-for'
    $xreal = $inspected.headers.'x-real-ip'
    $trackingDropped = ($xff -eq $null -and $xreal -eq $null)
    Report-Assert "Client IP Tracking Dropped" $trackingDropped "X-Forwarded-For: <DROPPED>, X-Real-IP: <DROPPED>"

} catch {
    Report-Assert "Mock Inspection Roundtrip" $false $_.Exception.Message
} finally {
    Write-Host "[*] Stopping local mock upstream process..." -ForegroundColor DarkGray
    if ($mockProc -and -not $mockProc.HasExited) {
        Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue
    }
}

# TEST SUITE 4: Nginx Proxy Debug Log Inspection
Write-Host "`n[SUITE 4] Nginx Live Debug Logs" -ForegroundColor Yellow
$logs = docker compose logs --tail=5
Write-Host "Latest Nginx Proxy Log Entries:" -ForegroundColor Cyan
Write-Host $logs -ForegroundColor DarkCyan

Write-Host "`nSUMMARY: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

if ($failed -gt 0) { exit 1 } else { exit 0 }
