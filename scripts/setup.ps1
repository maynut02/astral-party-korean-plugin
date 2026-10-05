param([string]$WorkRoot = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $WorkRoot) { $WorkRoot = Join-Path $pluginRoot '.work' }
$work = [IO.Path]::GetFullPath($WorkRoot)
$downloads = Join-Path $work 'downloads'
$deps = Join-Path $work 'deps'
New-Item -ItemType Directory -Path $downloads,$deps -Force | Out-Null

function Assert-Sha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw "SHA-256 mismatch for $Path. expected=$Expected actual=$actual" }
}

function Get-VerifiedFile([string]$Url, [string]$Destination, [string]$Sha256) {
    if (Test-Path -LiteralPath $Destination) {
        Assert-Sha256 $Destination $Sha256
        return
    }
    $temporary = "$Destination.part"
    try {
        Invoke-WebRequest -Headers @{ 'User-Agent' = 'AstralPartyKoreanPlugin-Builder/1.0' } -Uri $Url -OutFile $temporary
        Assert-Sha256 $temporary $Sha256
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Copy-ArchiveReferences([string]$ArchivePath, [string]$Destination, [string[]]$Entries) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($relative in $Entries) {
            $entry = $archive.GetEntry($relative)
            if (-not $entry) { throw "Missing build reference in ${ArchivePath}: $relative" }
            $target = Join-Path $Destination $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
    finally { $archive.Dispose() }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$bepinexZip = Join-Path $downloads 'BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788+5b766a3.zip'
$unityZip = Join-Path $downloads 'Unity-2022.3.62-libraries.zip'
Get-VerifiedFile `
    'https://builds.bepinex.dev/projects/bepinex_be/788/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788%2B5b766a3.zip' `
    $bepinexZip 'f4cc496bd098a0df4164b81e3737297707f13a47c2478dba2f60eefab784817a'
Get-VerifiedFile `
    'https://unity.bepinex.dev/libraries/2022.3.62.zip' `
    $unityZip '575e7d600f69de8200ccf4db700b3ae6252366c22e8c3434c860e428974518d1'

# Extract only compile-time references. The BepInEx runtime stays outside the project and release.
Copy-ArchiveReferences $bepinexZip (Join-Path $deps 'bepinex') @(
    'BepInEx/core/BepInEx.Core.dll',
    'BepInEx/core/BepInEx.Preloader.Core.dll',
    'BepInEx/core/BepInEx.Unity.IL2CPP.dll',
    'BepInEx/core/0Harmony.dll',
    'BepInEx/core/Il2CppInterop.Runtime.dll'
)
Copy-ArchiveReferences $unityZip (Join-Path $deps 'unity') @(
    'UnityEngine.CoreModule.dll',
    'UnityEngine.TextRenderingModule.dll',
    'UnityEngine.AssetBundleModule.dll',
    'UnityEngine.UIModule.dll',
    'UnityEngine.InputLegacyModule.dll'
)
Write-Output "deps=$deps"
