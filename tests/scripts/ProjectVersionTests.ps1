#requires -Version 7.0
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/project-version.ps1')
$passed = 0
foreach ($value in @('0.0.0', '1.2.3', '65534.65534.65534', '1.2.3-dev.0', '1.2.3-rc.1+build.02', '1.2.3-0', '1.2.3-alpha-1')) {
    if ((ConvertTo-AstralVersion $value) -cne $value) { throw "Valid SemVer changed: $value" }
    $passed++
}
foreach ($value in @('', '01.0.1', '1.00.0', '1.0.01', '1.0', '1.0.0.0', '1.0.0-01', '1.0.0-alpha.01', '1.0.0-', '1.0.0+', 'v1.0.0', '-1.0.0', ' 1.0.0', "1.0.0`n", '65535.0.0', '1.65535.0', '1.0.65535', '99999999999999999.0.0')) {
    $failed = $false
    try { ConvertTo-AstralVersion $value | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Invalid version accepted: $value" }
    $passed++
}
foreach ($value in @('1.2.3-rc.1', '1.2.3+build')) {
    $failed = $false
    try { ConvertTo-AstralVersion $value -Release | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Release accepted a non-stable version.' }
}
foreach ($tag in @('1.0.0', 'V1.0.0', 'v01.0.0', 'v1.0.0-rc.1', 'v65535.0.0')) {
    $failed = $false
    try { ConvertTo-AstralVersion $tag -Tag | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Invalid release tag accepted.' }
    $passed++
}
if ((ConvertTo-AstralVersion 'v1.2.3' -Tag) -cne '1.2.3') { throw 'Canonical tag parsing failed.' }
foreach ($case in @(
    @{ Version = '0.0.1'; Bump = 'patch'; Expected = '0.0.2' },
    @{ Version = '1.2.3'; Bump = 'minor'; Expected = '1.3.0' },
    @{ Version = '0.2.3'; Bump = 'major'; Expected = '1.0.0' },
    @{ Version = '1.65534.65534'; Bump = 'major'; Expected = '2.0.0' },
    @{ Version = '1.2.65534'; Bump = 'minor'; Expected = '1.3.0' })) {
    if ((Get-AstralNextVersion -Version $case.Version -Bump $case.Bump) -cne $case.Expected) { throw 'Incorrect bump/reset.' }
    $passed++
}
foreach ($bump in @('patch', 'minor', 'major', 'miner')) {
    $failed = $false
    try { Get-AstralNextVersion -Version '65534.65534.65534' -Bump $bump | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Overflow or invalid bump accepted.' }
}
Write-Output "Project version tests passed: $passed cases."
$global:LASTEXITCODE = 0
