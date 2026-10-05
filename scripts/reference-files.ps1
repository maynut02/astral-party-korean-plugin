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
