param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$WorkRoot = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'reference-files.ps1')
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $WorkRoot) { $WorkRoot = Join-Path $pluginRoot '.work' }
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $GameRoot 'BepInEx'))
$targetRoot = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) 'refs'

# Validate the complete set before changing the cached references.
Assert-AstralReferences $sourceRoot
foreach ($relative in Get-AstralReferencePaths) {
    $source = Join-Path $sourceRoot $relative
    $target = Join-Path $targetRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}
[ordered]@{ references = @(Get-AstralReferenceVersions $targetRoot) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $targetRoot 'versions.json') -Encoding utf8NoBOM
Write-Output "refs=$targetRoot"
