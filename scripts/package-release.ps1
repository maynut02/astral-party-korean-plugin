param(
    [string]$Version = '',
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Astral Party\8vJXnINT',
    [string]$RefsRoot = '',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [string]$DotNetPath = ''
)

$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'project-version.ps1')
if (-not $Version) { $Version = Get-AstralProjectVersion -Root $pluginRoot }
else { $Version = ConvertTo-AstralVersion $Version }
$buildRoot = Join-Path $pluginRoot 'dist'
if (-not $OutputRoot) { $OutputRoot = Join-Path $buildRoot "release/v$Version" }
$dist = [IO.Path]::GetFullPath($OutputRoot)
$buildArguments = @{ Version = $Version; RefsRoot = $RefsRoot; WorkRoot = $WorkRoot; OutputRoot = $buildRoot; DotNetPath = $DotNetPath }
if ($PSBoundParameters.ContainsKey('GameRoot')) { $buildArguments.GameRoot = $GameRoot }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArguments

New-Item -ItemType Directory -Path $dist -Force | Out-Null
if ($dist.TrimEnd([IO.Path]::DirectorySeparatorChar) -ine $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
    foreach ($name in @('AstralPartyKoreanPlugin.dataUnity3dRedirect.dll', 'AstralPartyKoreanPlugin.dll', 'build-references.json')) {
        Copy-Item -LiteralPath (Join-Path $buildRoot $name) -Destination (Join-Path $dist $name) -Force
    }
}

$files = [ordered]@{
    'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll' = (Join-Path $dist 'AstralPartyKoreanPlugin.dataUnity3dRedirect.dll')
    'BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll' = (Join-Path $dist 'AstralPartyKoreanPlugin.dll')
}

# An explicit allowlist prevents build references, caches and the BepInEx runtime from entering the ZIP.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $dist "AstralPartyKoreanPlugin-v$Version.zip"
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files.GetEnumerator()) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $file.Value, $file.Key, [IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally { $archive.Dispose(); $stream.Dispose() }

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$metadata = [ordered]@{
    schemaVersion = 1
    packageVersion = $Version
    buildReferences = @((Get-Content -LiteralPath (Join-Path $dist 'build-references.json') -Raw -Encoding utf8 | ConvertFrom-Json).references)
    includesBepInExRuntime = $false
    package = [ordered]@{
        file = [IO.Path]::GetFileName($zipPath)
        sha256 = $zipHash
        size = (Get-Item -LiteralPath $zipPath).Length
    }
    preloader = [ordered]@{
        version = $Version
        sha256 = (Get-FileHash -LiteralPath $files['BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll'] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    plugin = [ordered]@{
        version = $Version
        sha256 = (Get-FileHash -LiteralPath $files['BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll'] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$metadataPath = Join-Path $dist 'windows-plugin-build.json'
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
"$zipHash  $([IO.Path]::GetFileName($zipPath))" | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding utf8NoBOM
Write-Output "package=$zipPath"
Write-Output "metadata=$metadataPath"
Write-Output "sha256=$zipHash"
