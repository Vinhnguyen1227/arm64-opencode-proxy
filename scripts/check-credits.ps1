# Run check-credits.sh on ARM64 Termux phone via SSH bridge
$brainDir = "C:\Users\Hello\.gemini\antigravity\brain\8ef50d19-3de0-4a76-a37c-e6abe5dd8b68"
$sshHelper = Join-Path $brainDir "scratch\ssh_termux.js"

if (Test-Path $sshHelper) {
    node $sshHelper "bash ~/arm64-opencode-proxy/scripts/check-credits.sh"
} else {
    Write-Error "SSH bridge script not found at $sshHelper"
}
