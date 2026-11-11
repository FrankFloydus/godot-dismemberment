param(
    [string]$Godot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GODOT/Godot_v4.7-stable_win64_console.exe'),
    [string]$ProjectPath = '',
    [switch]$Extended,
    [switch]$Rendered
)
$ErrorActionPreference = 'Stop'
$repositoryPath = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectPath)) { $ProjectPath = Join-Path $repositoryPath 'project' }
if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot executable not found: $Godot. Pass -Godot with a Godot 4.3+ console executable."
}
& $Godot --headless --editor --path $projectPath --import --quit
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$testOutput = & $Godot --headless --path $projectPath --script res://tests/integration.gd 2>&1
$testExitCode = $LASTEXITCODE
$testOutput | ForEach-Object { Write-Output $_ }
if ($testExitCode -ne 0) { exit $testExitCode }
if (-not ($testOutput -match 'GODOT_DISMEMBERMENT_TESTS_PASS')) {
    throw 'Test process ended without its success marker; check the script errors above.'
}
$geometryOutput = & $Godot --headless --path $projectPath --script res://tests/test_mesh_partition.gd 2>&1
$geometryExitCode = $LASTEXITCODE
$geometryOutput | ForEach-Object { Write-Output $_ }
if ($geometryExitCode -ne 0) { exit $geometryExitCode }
if (-not ($geometryOutput -match 'MeshPartition checks=\d+ failures=0')) {
    throw 'Mesh partition tests ended without their success marker; check the errors above.'
}
& (Join-Path $PSScriptRoot 'test_network.ps1') -GodotPath $Godot -ProjectPath $ProjectPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

function Invoke-BehaviorTest {
    param([string]$Script, [string]$Marker, [bool]$UseRenderer = $false, [string[]]$UserArguments = @())
    $engineArguments = @('--path', $ProjectPath, '--script', "res://tests/$Script")
    if (-not $UseRenderer) { $engineArguments = @('--headless') + $engineArguments }
    if ($UserArguments.Count -gt 0) { $engineArguments += @('--') + $UserArguments }
    $captured = & $Godot @engineArguments 2>&1
    $code = $LASTEXITCODE
    $captured | ForEach-Object { Write-Output $_ }
    if ($code -ne 0 -or -not ($captured -match $Marker)) { throw "Behavior test failed: $Script (exit $code)" }
    if ($captured -match '^ERROR:|^SCRIPT ERROR:') { throw "Engine error during $Script" }
}

Invoke-BehaviorTest 'test_component_inspector.gd' 'COMPONENT_INSPECTOR_CHECKS=\d+ FAILURES=0'
Invoke-BehaviorTest 'test_gore_audit.gd' 'Gore source audit checks=\d+ failures=0'
Invoke-BehaviorTest 'test_blood_pool_parity.gd' 'Blood pool parity checks=\d+ failures=0'
Invoke-BehaviorTest 'test_attachment_socket_parity.gd' 'ATTACHMENT_SOCKET_PARITY: checks=\d+ failures=0'
Invoke-BehaviorTest 'test_authored_demo.gd' 'AUTHORED_DEMO_CHECKS=\d+ FAILURES=0'
Invoke-BehaviorTest 'test_shotgun_impacts.gd' 'SHOTGUN_IMPACTS_CHECKS=\d+ FAILURES=0'
Invoke-BehaviorTest 'test_source_physics_removal.gd' 'SOURCE_PHYSICS_TESTS: \d+ checks, 0 failures'
if ($Extended) {
    Invoke-BehaviorTest 'test_physics_fidelity.gd' 'GODOT_DISMEMBERMENT_PHYSICS_FIDELITY_PASS'
    Invoke-BehaviorTest 'test_physics_joint_integrity.gd' 'GODOT_DISMEMBERMENT_JOINT_INTEGRITY_PASS'
    Invoke-BehaviorTest 'test_physics_reset_cycles.gd' 'GODOT_DISMEMBERMENT_RESET_PHYSICS_PASS'
}
if ($Rendered) {
    # Dummy headless rendering cannot prove final skin matrices. These tests
    # create actual short-lived renderer windows and close them on completion.
    Invoke-BehaviorTest 'integration.gd' 'GODOT_DISMEMBERMENT_TESTS_PASS' $true @('--attachment-only')
    Invoke-BehaviorTest 'test_body_cut.gd' 'BODY_CUT_TESTS: \d+ checks, 0 failures' $true
    Invoke-BehaviorTest 'test_gore_audit.gd' 'Custom blood material checks=\d+ failures=0' $true @('--custom-shader')
    Invoke-BehaviorTest 'test_real_skin_geometry.gd' 'REAL_SKIN_GEOMETRY: checks=\d+ failures=0' $true
    Invoke-BehaviorTest 'test_sequential_skin.gd' 'SEQUENTIAL_SKIN: checks=\d+ failures=0' $true
    Invoke-BehaviorTest 'test_fps_reset.gd' 'GODOT_DISMEMBERMENT_FPS_RESET_PASS' $true
    Invoke-BehaviorTest 'test_shotgun_impacts.gd' 'SHOTGUN_IMPACTS_CHECKS=\d+ FAILURES=0' $true
    Invoke-BehaviorTest 'test_physics_fidelity.gd' 'GODOT_DISMEMBERMENT_PHYSICS_FIDELITY_PASS' $true @('--head-only')
    Invoke-BehaviorTest 'test_ragdoll_comparison.gd' 'RAGDOLL_COMPARISON_CHECKS=\d+ FAILURES=0' $true
}
exit 0
