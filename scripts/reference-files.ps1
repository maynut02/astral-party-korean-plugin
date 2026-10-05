function Get-AstralReferencePaths {
    @(
        'core/BepInEx.Core.dll'
        'core/BepInEx.Preloader.Core.dll'
        'core/BepInEx.Unity.IL2CPP.dll'
        'core/0Harmony.dll'
        'core/Il2CppInterop.Runtime.dll'
        'interop/Il2Cppmscorlib.dll'
        'interop/UnityEngine.CoreModule.dll'
        'interop/UnityEngine.TextRenderingModule.dll'
        'interop/UnityEngine.AssetBundleModule.dll'
        'interop/UnityEngine.UIModule.dll'
        'interop/UnityEngine.InputLegacyModule.dll'
        'interop/UnityEngine.UI.dll'
    )
}

function Assert-AstralReferences([string]$Root) {
    foreach ($relative in Get-AstralReferencePaths) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing build reference: $path. Initialize BepInEx in the game first, then run scripts/setup.ps1 -GameRoot <game-folder>."
        }
    }
}

function Get-AstralReferenceVersions([string]$Root) {
    foreach ($relative in Get-AstralReferencePaths) {
        $path = Join-Path $Root $relative
        $assembly = [Reflection.AssemblyName]::GetAssemblyName($path)
        [ordered]@{
            file = $relative
            assemblyVersion = $assembly.Version.ToString()
            fileVersion = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

function Sync-AstralReferences([string]$GameRoot, [string]$WorkRoot) {
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
}
