param(
    [string]$HostName = "36.138.61.152",
    [string]$User = "root",
    [ValidateSet("backend", "frontend", "images", "values", "crds", "deploy", "smoke", "access", "all")]
    [string]$Stage = "smoke",
    [string]$RemoteScript = "/opt/ai-k8s-platform/build/dev-loop.sh"
)

$ErrorActionPreference = "Stop"

$localScript = Join-Path $PSScriptRoot "dev-loop.sh"
if (-not (Test-Path $localScript)) {
    throw "Missing local script: $localScript"
}

$target = "${User}@${HostName}:${RemoteScript}"
$sshTarget = "${User}@${HostName}"

scp -o BatchMode=yes -o UpdateHostKeys=no $localScript $target
ssh -o BatchMode=yes -o UpdateHostKeys=no $sshTarget "chmod +x '$RemoteScript' && PUBLIC_HOST='$HostName' '$RemoteScript' '$Stage'"
