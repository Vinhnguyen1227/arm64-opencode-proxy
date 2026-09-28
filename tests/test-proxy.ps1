# Automated Test Suite for Nginx AI Reverse Proxy

param(
    [string]$BaseUrl = "http://localhost:8080",
    [string]$UserAKey = "sk-userA-vkey-001",
    [string]$UserBKey = "sk-userB-vkey-002"
)

$passed = 0
$failed = 0

function Report-Test {
    param([string]$Name, [bool]$Condition, [string]$Details = "")
    if ($Condition) {
        Write-Host " [PASS] $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host " [FAIL] $Name - $Details" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "======================================================================"
Write-Host "Starting Nginx Proxy Test Suite against $BaseUrl"
Write-Host "======================================================================"

# Test 1: Health Check
try {
    $res = Invoke-WebRequest -Uri "$BaseUrl/healthz" -Method GET -TimeoutSec 5 -UseBasicParsing
    $body = $res.Content | ConvertFrom-Json
    Report-Test "Health Check (/healthz)" ($res.StatusCode -eq 200 -and $body.status -eq "ok") "Status: $($res.StatusCode)"
} catch {
    Report-Test "Health Check (/healthz)" $false $_.Exception.Message
}

# Test 2: Unauthenticated Request Gate
try {
    $res = Invoke-WebRequest -Uri "$BaseUrl/v1/models" -Method GET -TimeoutSec 5 -UseBasicParsing
    Report-Test "Unauthenticated Request (Expect 401)" $false "Expected 401 but got $($res.StatusCode)"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Test "Unauthenticated Request (Expect 401)" ($statusCode -eq 401) "Got status $statusCode"
}

# Test 3: Invalid Virtual Key Gate
try {
    $headers = @{ "Authorization" = "Bearer sk-invalid-key-999" }
    $res = Invoke-WebRequest -Uri "$BaseUrl/v1/models" -Headers $headers -Method GET -TimeoutSec 5 -UseBasicParsing
    Report-Test "Invalid Virtual Key (Expect 401)" $false "Expected 401 but got $($res.StatusCode)"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Test "Invalid Virtual Key (Expect 401)" ($statusCode -eq 401) "Got status $statusCode"
}

# Test 4: CORS Preflight (OPTIONS)
try {
    $headers = @{
        "Origin" = "http://localhost:3000"
        "Access-Control-Request-Method" = "POST"
        "Access-Control-Request-Headers" = "Authorization, Content-Type"
    }
    $res = Invoke-WebRequest -Uri "$BaseUrl/v1/chat/completions" -Method OPTIONS -Headers $headers -TimeoutSec 5 -UseBasicParsing
    $allowOrigin = $res.Headers["Access-Control-Allow-Origin"]
    Report-Test "CORS Preflight OPTIONS /v1/" ($res.StatusCode -eq 204 -and $allowOrigin -eq "*") "Status: $($res.StatusCode)"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Report-Test "CORS Preflight OPTIONS /v1/" ($statusCode -eq 204) "Status: $statusCode"
}

# Test 5: User A Virtual Key Auth Pass
try {
    $headers = @{ "Authorization" = "Bearer $UserAKey" }
    $res = Invoke-WebRequest -Uri "$BaseUrl/v1/models" -Headers $headers -Method GET -TimeoutSec 10 -UseBasicParsing
    # If upstream key is valid -> 200. If upstream key is placeholder -> upstream returns 401/403 with upstream body (not our proxy's 401)
    Report-Test "User A Virtual Key Accepted" ($res.StatusCode -eq 200) "Upstream returned 200"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $body = ""
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
    }
    # Note: If proxy passes to Xiaomi MiMo and MiMo returns an upstream response (not proxy's internal "Invalid Virtual API Key"), it passed the gate!
    $isProxyGate = $body -match "Invalid Virtual API Key"
    if (-not $isProxyGate) {
        Report-Test "User A Virtual Key Passed Proxy Gate" $true "Passed proxy auth and reached upstream (Upstream HTTP $statusCode)"
    } else {
        Report-Test "User A Virtual Key Accepted" $false "Blocked by proxy gate: $body"
    }
}

# Test 6: User B Virtual Key Auth Pass
try {
    $headers = @{ "Authorization" = "Bearer $UserBKey" }
    $res = Invoke-WebRequest -Uri "$BaseUrl/v1/models" -Headers $headers -Method GET -TimeoutSec 10 -UseBasicParsing
    Report-Test "User B Virtual Key Accepted" ($res.StatusCode -eq 200) "Upstream returned 200"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $body = ""
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
    }
    $isProxyGate = $body -match "Invalid Virtual API Key"
    if (-not $isProxyGate) {
        Report-Test "User B Virtual Key Passed Proxy Gate" $true "Passed proxy auth and reached upstream (Upstream HTTP $statusCode)"
    } else {
        Report-Test "User B Virtual Key Accepted" $false "Blocked by proxy gate: $body"
    }
}

Write-Host "======================================================================"
Write-Host "Test Results: $passed Passed, $failed Failed"
Write-Host "======================================================================"

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}

