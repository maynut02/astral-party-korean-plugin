#requires -Version 7.0
param([string]$WorkRoot = '', [string]$DotNetPath = '', [string]$PythonPath = 'python')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $WorkRoot) { $WorkRoot = Join-Path $repoRoot '.work' }
. (Join-Path $PSScriptRoot 'dotnet-sdk.ps1')
$dotnet = Get-AstralDotnet -Root $repoRoot -WorkRoot $WorkRoot -DotNetPath $DotNetPath
$python = Get-Command $PythonPath -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
$savedDotnet = $env:ASTRAL_TEST_DOTNET
$env:ASTRAL_TEST_DOTNET = $dotnet
$testParent = Join-Path $repoRoot '.work/runtime-tests'
$testRoot = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testParent) | Out-Null
Push-Location -LiteralPath $repoRoot
try {
    & $python -B -m pytest tests -q -p no:cacheprovider --basetemp $testRoot
    if ($LASTEXITCODE -ne 0) { throw 'Runtime and local artifact regression checks failed.' }
} finally {
    Pop-Location
    $env:ASTRAL_TEST_DOTNET = $savedDotnet
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath($testParent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected runtime test fixture location.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
