param(
    [ValidateSet('template_debug','template_release','both')][string]$Target = 'both',
    [int]$Jobs = 12
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repoRoot
try {
    $targets = if ($Target -eq 'both') { @('template_debug','template_release') } else { @($Target) }
    foreach ($buildTarget in $targets) {
        & scons platform=windows arch=x86_64 "target=$buildTarget" "-j$Jobs"
        if ($LASTEXITCODE -ne 0) { throw "SCons failed: $buildTarget" }
    }
} finally { Pop-Location }
