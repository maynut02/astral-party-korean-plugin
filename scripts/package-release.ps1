#requires -Version 7.2
param(
    [string]$Version = '',
    [string]$Tag = '',
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$RefsRoot = '',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [string]$DotNetPath = '',
    [string]$SigningKeyPath = '',
    [string]$Repository = 'maynut02/astral-party-korean-plugin'
)

$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'project-version.ps1')
. (Join-Path $PSScriptRoot 'package-files.ps1')
if ($Tag) {
    $tagVersion = ConvertTo-AstralVersion $Tag -Tag
    if ($Version -and $Version -cne $tagVersion) { throw 'Package Version and Tag must match.' }
    $Version = $tagVersion
}
if ($Version) { $Version = ConvertTo-AstralVersion $Version -Release }
else { $Version = (Get-AstralVersionPlan -Root $pluginRoot).Version }
$Tag = "v$Version"
if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Repository must be owner/name.' }
$buildRoot = Join-Path $pluginRoot 'dist'
if (-not $OutputRoot) { $OutputRoot = Join-Path $buildRoot "release/$Tag" }
if (-not $WorkRoot) { $WorkRoot = Join-Path $pluginRoot '.work' }
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkRoot)
$dist = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$names = @(Get-AstralReleaseAssetNames $Tag)
$localNames = @('AstralPartyKoreanPlugin.dll', 'astralkorean_fonts.bundle', 'build-references.json', 'windows-plugin-build.json')
Assert-AstralPackageDirectory -Root $dist -AllowedFiles ($localNames + $names)
$key = Get-AstralSigningKey -Path $SigningKeyPath
$key.Dispose()
foreach ($source in @('installer/install.bat', 'installer/install.ps1', 'assets/third-party/LICENSE-BepInEx.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot $source) -PathType Leaf)) { throw "Missing full-package source: $source" }
}
$bepInEx = Get-AstralBepInExArchive -WorkRoot $work
$buildArguments = @{ Version = $Version; RefsRoot = $RefsRoot; WorkRoot = $work; OutputRoot = $buildRoot; DotNetPath = $DotNetPath }
if ($PSBoundParameters.ContainsKey('GameRoot')) { $buildArguments.GameRoot = $GameRoot }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArguments | Write-Output
$files = [ordered]@{
    'BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll' = (Join-Path $buildRoot 'AstralPartyKoreanPlugin.dll')
    'BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle' = (Join-Path $buildRoot 'astralkorean_fonts.bundle')
}
Assert-AstralPluginAssembly -Path $files['BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll'] -Name 'AstralPartyKoreanPlugin' -Version $Version
foreach ($path in $files.Values) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing build output: $path" } }
$references = Get-Content -LiteralPath (Join-Path $buildRoot 'build-references.json') -Raw -Encoding utf8 | ConvertFrom-Json
$stage = Join-Path $work ('package-release/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    $package = New-AstralZipPackage -Files $files -OutputRoot $stage -ZipName $names[0]
    $fullFiles = [ordered]@{}
    foreach ($file in $files.GetEnumerator()) { $fullFiles[$file.Key] = $file.Value }
    $fullFiles['BepInEx/config/BepInEx.cfg'] = [Text.Encoding]::UTF8.GetBytes("[Logging]`r`nUnityLogListening = false`r`n[Logging.Console]`r`nEnabled = false`r`n")
    $fullFiles['LICENSE-BepInEx.txt'] = Join-Path $pluginRoot 'assets/third-party/LICENSE-BepInEx.txt'
    $fullFiles['install.bat'] = Join-Path $pluginRoot 'installer/install.bat'
    $fullFiles['install.ps1'] = Join-Path $pluginRoot 'installer/install.ps1'
    $fullPackage = New-AstralZipPackage -Files $fullFiles -OutputRoot $stage -ZipName $names[1] -BaseArchive $bepInEx
    New-AstralUpdateManifest -Version $Version -Repository $Repository -OutputRoot $stage -Files $files -SigningKeyPath $SigningKeyPath
    Assert-AstralReleaseAssets -Tag $Tag -Repository $Repository -Root $stage | Out-Null
    foreach ($path in $files.Values) { Copy-Item -LiteralPath $path -Destination (Join-Path $stage ([IO.Path]::GetFileName($path))) }
    Copy-Item -LiteralPath (Join-Path $buildRoot 'build-references.json') -Destination (Join-Path $stage 'build-references.json')
    [ordered]@{
        schemaVersion = 2
        packageVersion = $Version
        buildReferences = @($references.references)
        package = [ordered]@{ file = $names[0]; sha256 = $package.Sha256; size = $package.Size }
        fullPackage = [ordered]@{ file = $names[1]; sha256 = $fullPackage.Sha256; size = $fullPackage.Size }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'windows-plugin-build.json') -Encoding utf8NoBOM
    [IO.Directory]::CreateDirectory($dist) | Out-Null
    foreach ($name in ($localNames + $names)) { Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $dist $name) -Force }
    Write-Output "package=$(Join-Path $dist $names[0])"
    Write-Output "fullPackage=$(Join-Path $dist $names[1])"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force }
