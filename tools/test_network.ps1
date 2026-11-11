param(
    [string]$GodotPath = "$env:USERPROFILE\Desktop\GODOT\Godot_v4.7-stable_win64_console.exe",
    [string]$ProjectPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'project'),
    [string]$LogDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'work\network-test'),
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) { throw "Godot executable not found: $GodotPath" }
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'tests\network_peer.gd') -PathType Leaf)) { throw 'Network test project not found.' }
if ($Port -eq 0) { $Port = Get-Random -Minimum 20000 -Maximum 58000 }
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path
$processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$peerLogs = @{}

try {
    foreach ($role in @('server', 'client')) {
        $stdout = Join-Path $LogDirectory "$role.stdout.log"
        $stderr = Join-Path $LogDirectory "$role.stderr.log"
        $arguments = "--headless --path `"$ProjectPath`" --script res://tests/network_peer.gd -- --role=$role --port=$Port"
        $process = Start-Process -FilePath $GodotPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $processes.Add($process)
        $peerLogs[$role] = @{ Process = $process; Out = $stdout; Error = $stderr }
        if ($role -eq 'server') {
            $deadline = [DateTime]::UtcNow.AddSeconds(12)
            $ready = $false
            while ([DateTime]::UtcNow -lt $deadline) {
                $process.Refresh()
                if ($process.HasExited) { break }
                if ((Test-Path -LiteralPath $stdout) -and ((Get-Content -LiteralPath $stdout -Raw) -match 'GODOT_DISMEMBERMENT_NETWORK_SERVER_READY')) { $ready = $true; break }
                Start-Sleep -Milliseconds 100
            }
            if (-not $ready) { throw "ENet server did not become ready. See $stdout and $stderr" }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    while ([DateTime]::UtcNow -lt $deadline) {
        $allExited = $true
        foreach ($process in $processes) {
            $process.Refresh()
            if (-not $process.HasExited) { $allExited = $false }
        }
        if ($allExited) { break }
        Start-Sleep -Milliseconds 100
    }
    foreach ($role in @('server', 'client')) {
        $entry = $peerLogs[$role]
        $process = $entry.Process
        $process.Refresh()
        if (-not $process.HasExited) { throw "$role peer exceeded the process timeout." }
        $content = Get-Content -LiteralPath $entry.Out -Raw
        $errors = Get-Content -LiteralPath $entry.Error -Raw
        Write-Output $content
        if ($errors) { Write-Output $errors }
        if ($process.ExitCode -ne 0 -or $content -notmatch "GODOT_DISMEMBERMENT_NETWORK_PASS role=$role") { throw "$role peer failed with exit code $($process.ExitCode)." }
        if ($errors -match 'SCRIPT ERROR|ERROR:|GODOT_DISMEMBERMENT_NETWORK_FAIL') { throw "$role peer reported engine/test errors." }
    }
    $summary = "GODOT_DISMEMBERMENT_ENET_TEST_PASS peers=2 transport=ENet address=127.0.0.1 port=$Port`nlate_join=pass nonowner_rejection=pass authorized_request=pass authority_broadcast=pass duplicate_snapshot=pass reset=pass"
    Set-Content -LiteralPath (Join-Path $LogDirectory 'result.txt') -Value $summary -Encoding utf8
    Write-Output $summary
}
catch {
    Set-Content -LiteralPath (Join-Path $LogDirectory 'result.txt') -Value "GODOT_DISMEMBERMENT_ENET_TEST_FAIL peers=2 transport=ENet address=127.0.0.1 port=$Port`n$($_.Exception.Message)" -Encoding utf8
    throw
}
finally {
    # Stop only the exact child processes created above, never other Godot apps.
    foreach ($process in $processes) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -InputObject $process -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
}
