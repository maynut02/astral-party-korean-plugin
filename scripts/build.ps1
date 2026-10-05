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
if (-not $WorkRoot) { $WorkRoot = Join-Path $pluginRoot '.work' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $pluginRoot 'dist' }
$work = [IO.Path]::GetFullPath($WorkRoot)
$dist = [IO.Path]::GetFullPath($OutputRoot)
. (Join-Path $PSScriptRoot 'dotnet-sdk.ps1')
$DotNetPath = Get-AstralDotnet -Root $pluginRoot -WorkRoot $work -DotNetPath $DotNetPath

. (Join-Path $PSScriptRoot 'reference-files.ps1')
if (-not $RefsRoot) {
    $RefsRoot = Join-Path $work 'refs'
    if ($PSBoundParameters.ContainsKey('GameRoot') -or -not (Test-Path -LiteralPath (Join-Path $RefsRoot 'core/BepInEx.Core.dll'))) {
        Sync-AstralReferences -GameRoot $GameRoot -WorkRoot $work
    }
}
$RefsRoot = [IO.Path]::GetFullPath($RefsRoot)
Assert-AstralReferences $RefsRoot
$generatedVersionSource = Join-Path $work 'generated/AstralBuildVersion.g.cs'
New-Item -ItemType Directory -Path (Split-Path -Parent $generatedVersionSource),$dist -Force | Out-Null
[ordered]@{ references = @(Get-AstralReferenceVersions $RefsRoot) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dist 'build-references.json') -Encoding utf8NoBOM
@"
internal static class AstralBuildVersion
{
    public const string Value = "$Version";
}
"@ | Set-Content -LiteralPath $generatedVersionSource -Encoding utf8NoBOM

# Resolve global.json from this project even when invoked from another working directory.
Push-Location $pluginRoot
try {
    foreach ($project in @(
        'src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj',
        'src/Plugin/AstralPartyKoreanPlugin.csproj'
    )) {
        & $DotNetPath build (Join-Path $pluginRoot $project) --configuration Release --nologo `
            "-p:AstralRefsRoot=$RefsRoot" `
            "-p:AstralBuildVersionSource=$generatedVersionSource" `
            "-p:Version=$Version" -p:ContinuousIntegrationBuild=true
        if ($LASTEXITCODE -ne 0) { throw "dotnet build failed: $project" }
    }
}
finally { Pop-Location }

foreach ($component in @(
    @{ Project = 'Preloader'; Assembly = 'AstralPartyKoreanPlugin.dataUnity3dRedirect' },
    @{ Project = 'Plugin'; Assembly = 'AstralPartyKoreanPlugin' }
)) {
    $dll = Join-Path $pluginRoot "src/$($component.Project)/bin/Release/net6.0/$($component.Assembly).dll"
    if (-not (Test-Path -LiteralPath $dll)) { throw "Build output is missing: $dll" }
    Copy-Item -LiteralPath $dll -Destination (Join-Path $dist "$($component.Assembly).dll") -Force
}
Write-Output "output=$dist"
Write-Output "version=$Version"
