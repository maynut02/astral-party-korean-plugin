param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$WorkRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'reference-files.ps1')
. (Join-Path $PSScriptRoot 'dotnet-sdk.ps1')
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $WorkRoot) { $WorkRoot = Join-Path $pluginRoot '.work' }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
Sync-AstralReferences -GameRoot $GameRoot -WorkRoot $WorkRoot
$dotnet = Install-AstralLocalSdk -Root $pluginRoot -WorkRoot $WorkRoot
Write-Output "dotnet=$dotnet"
