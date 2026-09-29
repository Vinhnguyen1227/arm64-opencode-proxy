param (
    [string]$TargetUrl = "http://192.168.22.87:8080",
    [string]$ApiKey = "sk-userA-vkey-001",
    [string]$Model = "vgpt/gpt-6-sol"
)

$ErrorActionPreference = "Continue"

Write-Host "Target: $TargetUrl" -ForegroundColor Cyan
Write-Host "API Key: $ApiKey" -ForegroundColor Cyan
Write-Host "Model : $Model" -ForegroundColor Cyan
Write-Host ""

$Passed = 0
$Failed = 0

function Assert-Result([string]$Name, [bool]$Condition, [string]$Details = "") {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Details) {
            Write-Host "         $Details" -ForegroundColor DarkRed
        }
        $script:Failed++
    }
}

# 1. Healthcheck
Write-Host "[1/7] Testing Healthcheck (GET /healthz)..."
try {
    $res = Invoke-RestMethod -Uri "$TargetUrl/healthz" -Method Get -TimeoutSec 10
    Assert-Result "Healthcheck returns 200 OK" ($res.status -eq "ok") "Response: $($res | ConvertTo-Json -Compress)"
} catch {
    Assert-Result "Healthcheck returns 200 OK" $false $_.Exception.Message
}

# 2. Auth Gate Enforcement
Write-Host "[2/7] Testing Auth Enforcement with invalid key..."
try {
    $badHeaders = @{ Authorization = "Bearer invalid-token-xyz" }
    $res = Invoke-WebRequest -Uri "$TargetUrl/v1/models" -Headers $badHeaders -Method Get -TimeoutSec 10
    Assert-Result "Rejected invalid key with 401" $false "Expected 401, got $($res.StatusCode)"
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    Assert-Result "Rejected invalid key with 401" ($status -eq 401) "Got status code $status"
}

# 3. CORS Preflight
Write-Host "[3/7] Testing CORS Preflight (OPTIONS /responses)..."
try {
    $corsReq = [System.Net.HttpWebRequest]::Create("$TargetUrl/responses")
    $corsReq.Method = "OPTIONS"
    $corsReq.Timeout = 10000
    $corsRes = $corsReq.GetResponse()
    $statusCode = [int]$corsRes.StatusCode
    $corsHeader = $corsRes.Headers["Access-Control-Allow-Origin"]
    $corsRes.Close()
    Assert-Result "CORS preflight returns 204" ($statusCode -eq 204 -and $corsHeader -eq "*") "Status: $statusCode, Origin: $corsHeader"
} catch {
    Assert-Result "CORS preflight returns 204" $false $_.Exception.Message
}

# 4. Models Discovery (GET /models vs GET /v1/models)
Write-Host "[4/7] Testing Models Discovery (GET /models with rewrite)..."
try {
    $headers = @{ Authorization = "Bearer $ApiKey" }
    $res = Invoke-RestMethod -Uri "$TargetUrl/models" -Headers $headers -Method Get -TimeoutSec 15
    Assert-Result "Models returned via root rewrite /models" ($res.data -ne $null -or $res.object -eq "list") "Data items: $($res.data.Count)"
} catch {
    Assert-Result "Models returned via root rewrite /models" $false $_.Exception.Message
}

# 5. Native OpenCode Responses (POST /responses without /v1)
Write-Host "[5/7] Testing Native OpenCode Responses (POST /responses)..."
try {
    $headers = @{
        Authorization = "Bearer $ApiKey"
        "Content-Type" = "application/json"
    }
    $body = @{
        model = $Model
        input = "ping"
    } | ConvertTo-Json -Compress

    $res = Invoke-WebRequest -Uri "$TargetUrl/responses" -Headers $headers -Method Post -Body $body -TimeoutSec 30
    Assert-Result "Native POST /responses returned 200 OK" ($res.StatusCode -eq 200) "Status: $($res.StatusCode)"
} catch {
    Assert-Result "Native POST /responses returned 200 OK" $false $_.Exception.Message
}

# 6. OpenCode Responses with /v1 (POST /v1/responses)
Write-Host "[6/7] Testing OpenCode Responses (POST /v1/responses)..."
try {
    $headers = @{
        Authorization = "Bearer $ApiKey"
        "Content-Type" = "application/json"
    }
    $body = @{
        model = $Model
        input = "ping"
    } | ConvertTo-Json -Compress

    $res = Invoke-WebRequest -Uri "$TargetUrl/v1/responses" -Headers $headers -Method Post -Body $body -TimeoutSec 30
    Assert-Result "POST /v1/responses returned 200 OK" ($res.StatusCode -eq 200) "Status: $($res.StatusCode)"
} catch {
    Assert-Result "POST /v1/responses returned 200 OK" $false $_.Exception.Message
}

# 7. 35KB OpenCode Tool Schema Payload Handling
Write-Host "[7/7] Testing 35KB Payload Buffer (POST /responses)..."
try {
    # Generate 35KB simulated OpenCode schema
    $filler = "x" * 35000
    $body = @{
        model = $Model
        input = "hello"
        tools = @(
            @{
                type = "function"
                function = @{
                    name = "schema_filler"
                    description = $filler
                    parameters = @{ type = "object"; properties = @{} }
                }
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    $res = Invoke-WebRequest -Uri "$TargetUrl/responses" -Headers $headers -Method Post -Body $body -TimeoutSec 30
    Assert-Result "35KB tool schema processed without 413 or buffer error" ($res.StatusCode -eq 200) "Status: $($res.StatusCode)"
} catch {
    Assert-Result "35KB tool schema processed without 413 or buffer error" $false $_.Exception.Message
}

Write-Host ""
Write-Host "Test Results: $Passed Passed, $Failed Failed" -ForegroundColor $(if ($Failed -eq 0) { "Green" } else { "Red" })
if ($Failed -gt 0) { exit 1 }
