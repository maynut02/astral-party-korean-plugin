param(
    [string]$Version = '',
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
if (-not $DotNetPath) {
    $localDotnet = Join-Path $work 'dotnet/dotnet.exe'
    if (Test-Path -LiteralPath $localDotnet) { $DotNetPath = $localDotnet }
    else {
        $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw 'Install .NET SDK 6.0.428 or pass -DotNetPath to an existing SDK.' }
        $DotNetPath = $command.Source
    }
}

& (Join-Path $PSScriptRoot 'setup.ps1') -WorkRoot $work
$deps = Join-Path $work 'deps'
$generatedVersionSource = Join-Path $work 'generated/AstralBuildVersion.g.cs'
New-Item -ItemType Directory -Path (Split-Path -Parent $generatedVersionSource),$dist -Force | Out-Null
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
            "-p:AstralDepsRoot=$deps" `
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
