#requires -Version 7.0
param(
    [string]$Version = '',
    [string]$Tag = '',
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$RefsRoot = '',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [string]$DotNetPath = ''
)

$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'project-version.ps1')
. (Join-Path $PSScriptRoot 'package-files.ps1')
$currentVersion = Get-AstralProjectVersion -Root $pluginRoot
if ($Tag) {
    $tagVersion = ConvertTo-AstralVersion $Tag -Tag
    if ($Version -and $Version -cne $tagVersion) { throw 'Package Version and Tag must match.' }
    $Version = $tagVersion
}
if ($Version -and (ConvertTo-AstralVersion $Version) -cne $currentVersion) { throw 'Package tag must match VERSION when building. Prepare the VERSION file before packaging.' }
$Version = $currentVersion
$buildRoot = Join-Path $pluginRoot 'dist'
if (-not $OutputRoot) { $OutputRoot = Join-Path $buildRoot "release/v$Version" }
$dist = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$zipName = "AstralPartyKoreanPlugin-v$Version.zip"
Assert-AstralPackageDirectory -Root $dist -AllowedFiles @('AstralPartyKoreanPlugin.dll', 'astralkorean_fonts.bundle', 'build-references.json', 'windows-plugin-build.json', $zipName, 'SHA256SUMS.txt')
$buildArguments = @{ Version = $Version; RefsRoot = $RefsRoot; WorkRoot = $WorkRoot; OutputRoot = $buildRoot; DotNetPath = $DotNetPath }
if ($PSBoundParameters.ContainsKey('GameRoot')) { $buildArguments.GameRoot = $GameRoot }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArguments

$files = [ordered]@{
    'BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle' = (Join-Path $buildRoot 'astralkorean_fonts.bundle')
    'BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll' = (Join-Path $buildRoot 'AstralPartyKoreanPlugin.dll')
}
Assert-AstralPluginAssembly -Path $files['BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll'] -Name 'AstralPartyKoreanPlugin' -Version $Version
$references = Get-Content -LiteralPath (Join-Path $buildRoot 'build-references.json') -Raw -Encoding utf8 | ConvertFrom-Json
$package = New-AstralPluginPackage -Files $files -OutputRoot $dist -ZipName $zipName
if ($dist.TrimEnd('\', '/') -ine $buildRoot.TrimEnd('\', '/')) {
    Copy-Item -LiteralPath (Join-Path $buildRoot 'build-references.json') -Destination (Join-Path $dist 'build-references.json') -Force
}
$metadata = [ordered]@{
    schemaVersion = 1
    packageVersion = $Version
    buildReferences = @($references.references)
    includesBepInExRuntime = $false
    package = [ordered]@{
        file = $zipName
        sha256 = $package.Sha256
        size = $package.Size
    }
    fontBundle = [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $files['BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle'] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    plugin = [ordered]@{
        version = $Version
        sha256 = (Get-FileHash -LiteralPath $files['BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll'] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$metadataPath = Join-Path $dist 'windows-plugin-build.json'
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
Write-Output "package=$($package.Path)"
Write-Output "metadata=$metadataPath"
Write-Output "sha256=$($package.Sha256)"
