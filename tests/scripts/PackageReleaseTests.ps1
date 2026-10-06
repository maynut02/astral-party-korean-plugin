#requires -Version 7.0
param([string]$DotNetPath = '')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/project-version.ps1')
. (Join-Path $repoRoot 'scripts/dotnet-sdk.ps1')
$dotnet = Get-AstralDotnet -Root $repoRoot -WorkRoot (Join-Path $repoRoot '.work') -DotNetPath $DotNetPath
$version = Get-AstralProjectVersion -Root $repoRoot
$otherVersion = Get-AstralNextVersion -Version $version -Bump patch
$tag = "v$version"
$zipName = "AstralPartyKoreanPlugin-$tag.zip"
$testParent = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work/package-tests'))
$testRoot = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$passed = 0
try {
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Invoke-PackageCase([string]$CaseName, [scriptblock]$Test) {
    & $Test
    $script:passed++
    Write-Output "PASS package: $CaseName"
}

function New-ManagedFixture([string]$Name, [string]$FixtureVersion, [string]$Directory) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Directory 'Fixture.csproj'), "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>net6.0</TargetFramework><AssemblyName>$Name</AssemblyName><Version>$FixtureVersion</Version><IncludeSourceRevisionInInformationalVersion>false</IncludeSourceRevisionInInformationalVersion></PropertyGroup></Project>", $utf8)
    [IO.File]::WriteAllText((Join-Path $Directory 'Fixture.cs'), 'public static class Fixture { }', $utf8)
    [IO.File]::WriteAllText((Join-Path $Directory 'NuGet.Config'), '<configuration><packageSources><clear /></packageSources></configuration>', $utf8)
    $outputRoot = Join-Path $Directory 'bin'
    $result = @(& $dotnet build (Join-Path $Directory 'Fixture.csproj') --configuration Release --output $outputRoot --nologo 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Package fixture build failed: $($result -join "`n")" }
    return Join-Path $outputRoot "$Name.dll"
}

$dllNames = @('AstralPartyKoreanPlugin.dataUnity3dRedirect.dll', 'AstralPartyKoreanPlugin.dll')
$goodDlls = @{}
$wrongVersions = @{}
foreach ($name in $dllNames) {
    $assemblyName = [IO.Path]::GetFileNameWithoutExtension($name)
    # Keep .NET 6 MSBuild's intermediate file paths below Windows MAX_PATH.
    $fixtureName = if ($name -eq $dllNames[0]) { 'preloader' } else { 'plugin' }
    $goodDlls[$name] = New-ManagedFixture $assemblyName $version (Join-Path $testRoot "assembly/$fixtureName")
    $wrongVersions[$name] = New-ManagedFixture $assemblyName $otherVersion (Join-Path $testRoot "wrong-version/$fixtureName")
}
$wrongIdentity = New-ManagedFixture 'UnrelatedPlugin' $version (Join-Path $testRoot 'wrong-identity')
$automaticRoot = Join-Path $testRoot 'automatic'
$automaticScripts = Join-Path $automaticRoot 'scripts'
$inputRoot = Join-Path $automaticRoot 'build-input'
[IO.Directory]::CreateDirectory($automaticScripts) | Out-Null
[IO.Directory]::CreateDirectory($inputRoot) | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/package-release.ps1'), (Join-Path $repoRoot 'scripts/project-version.ps1'), (Join-Path $repoRoot 'scripts/package-files.ps1') -Destination $automaticScripts
[IO.File]::WriteAllText((Join-Path $automaticRoot 'VERSION'), $version, $utf8)
foreach ($name in $dllNames) { Copy-Item -LiteralPath $goodDlls[$name] -Destination (Join-Path $inputRoot $name) }
$buildStub = @'
param([string]$Version = '', [string]$GameRoot = 'fixture-default-game', [string]$RefsRoot = '',
    [string]$WorkRoot = '', [string]$OutputRoot = '', [string]$DotNetPath = '')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$call = @{ Version = $Version; GameRoot = $GameRoot; RefsRoot = $RefsRoot; WorkRoot = $WorkRoot; OutputRoot = $OutputRoot; DotNetPath = $DotNetPath } | ConvertTo-Json -Compress
[IO.File]::AppendAllText((Join-Path $root 'build-calls.jsonl'), $call + [Environment]::NewLine)
if (Test-Path -LiteralPath (Join-Path $root 'fail-build')) { throw 'Fixture build failed.' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $root 'dist' }
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
foreach ($name in @('AstralPartyKoreanPlugin.dataUnity3dRedirect.dll', 'AstralPartyKoreanPlugin.dll')) {
    if (Test-Path -LiteralPath (Join-Path $root "omit-$name")) {
        $missingOutput = Join-Path $OutputRoot $name
        if (Test-Path -LiteralPath $missingOutput) { Remove-Item -LiteralPath $missingOutput }
        continue
    }
    Copy-Item -LiteralPath (Join-Path $root "build-input/$name") -Destination (Join-Path $OutputRoot $name) -Force
}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'build-references.json'), '{"references":[]}', [Text.UTF8Encoding]::new($false))
'@
[IO.File]::WriteAllText((Join-Path $automaticScripts 'build.ps1'), $buildStub, $utf8)
$package = Join-Path $automaticScripts 'package-release.ps1'
$assets = Join-Path $automaticRoot "dist/release/$tag"
$buildRoot = Join-Path $automaticRoot 'dist'
$callsPath = Join-Path $automaticRoot 'build-calls.jsonl'
$expectedNames = @($dllNames) + @('build-references.json', 'windows-plugin-build.json', $zipName, 'SHA256SUMS.txt')
$zipEntries = [ordered]@{
    'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll' = $dllNames[0]
    'BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll' = $dllNames[1]
}

function Get-BuildCallCount {
    if (-not (Test-Path -LiteralPath $callsPath)) { return 0 }
    return [IO.File]::ReadAllLines($callsPath).Count
}

function Get-ReleaseHashes([string]$Root) {
    return (@(Get-ChildItem -LiteralPath $Root -Force | Sort-Object Name | ForEach-Object {
        $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join ',')
}

function Assert-Rejected([hashtable]$Arguments, [string]$Message) {
    $failed = $false
    try { & $package @Arguments | Out-Null } catch {
        if ($Message -and -not $_.Exception.Message.Contains($Message)) { throw }
        $failed = $true
    }
    if (-not $failed) { throw 'Invalid release package was accepted.' }
}

function Assert-PreflightRejected([hashtable]$Arguments, [string]$Message) {
    $before = Get-BuildCallCount
    $hashes = Get-ReleaseHashes $assets
    Assert-Rejected $Arguments $Message
    if ((Get-BuildCallCount) -ne $before) { throw 'Rejected package settings triggered a build.' }
    if ((Get-ReleaseHashes $assets) -cne $hashes) { throw 'Preflight rejection changed existing release assets.' }
}

function Assert-Package([string]$Root = $assets) {
    $entries = @(Get-ChildItem -LiteralPath $Root -Force)
    $actualNames = @($entries.Name | Sort-Object)
    if (@($entries | Where-Object PSIsContainer).Count -gt 0 -or
        ($actualNames -join ',') -cne (($expectedNames | Sort-Object) -join ',')) {
        throw 'Release output must contain exactly the six expected files.'
    }
    foreach ($name in $dllNames) {
        if ((Get-FileHash -LiteralPath (Join-Path $Root $name)).Hash -cne (Get-FileHash -LiteralPath $goodDlls[$name]).Hash) {
            throw "Standalone DLL differs from the fresh build: $name"
        }
    }
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $Root $zipName))
    try {
        if ($archive.Entries.Count -ne 2 -or
            (($archive.Entries.FullName | Sort-Object) -join ',') -cne (($zipEntries.Keys | Sort-Object) -join ',')) {
            throw 'ZIP must contain only the preloader and plugin at their installation paths.'
        }
        foreach ($entry in $archive.Entries) {
            $name = $zipEntries[$entry.FullName]
            $extracted = Join-Path $testRoot "extracted-$name"
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extracted, $true)
            if ((Get-FileHash -LiteralPath $extracted).Hash -cne (Get-FileHash -LiteralPath $goodDlls[$name]).Hash) {
                throw "Packaged DLL differs from the fresh build: $name"
            }
        }
    } finally { $archive.Dispose() }
    $zipPath = Join-Path $Root $zipName
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums = [IO.File]::ReadAllLines((Join-Path $Root 'SHA256SUMS.txt'))
    if ($checksums.Count -ne 1 -or $checksums[0] -cne "$zipHash  $zipName") { throw 'ZIP checksum manifest differs.' }
    $references = [IO.File]::ReadAllText((Join-Path $Root 'build-references.json')) | ConvertFrom-Json
    $metadata = [IO.File]::ReadAllText((Join-Path $Root 'windows-plugin-build.json')) | ConvertFrom-Json
    if (@($references.references).Count -ne 0 -or @($metadata.buildReferences).Count -ne 0 -or
        $metadata.schemaVersion -ne 1 -or $metadata.packageVersion -cne $version -or
        $metadata.includesBepInExRuntime -isnot [bool] -or $metadata.includesBepInExRuntime -ne $false) {
        throw 'Build metadata does not describe this plugin-only release and its empty reference fixture.'
    }
    if ($metadata.package.file -cne $zipName -or $metadata.package.sha256 -cne $zipHash -or
        $metadata.package.size -ne (Get-Item -LiteralPath $zipPath).Length) { throw 'Package metadata differs from the ZIP.' }
    foreach ($component in @(@{ Name = $dllNames[0]; Metadata = $metadata.preloader }, @{ Name = $dllNames[1]; Metadata = $metadata.plugin })) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Root $component.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($component.Metadata.version -cne $version -or $component.Metadata.sha256 -cne $hash) {
            throw "DLL metadata differs: $($component.Name)"
        }
    }
}

Invoke-PackageCase 'default packaging builds once and produces exact two-DLL ZIP, six assets and verified metadata' {
    & $package | Out-Null
    Assert-Package
    if ((Get-BuildCallCount) -ne 1) { throw 'Default package did not build exactly once.' }
    $call = [IO.File]::ReadAllLines($callsPath)[0] | ConvertFrom-Json
    if ($call.Version -cne $version -or $call.OutputRoot -cne $buildRoot -or $call.GameRoot -cne 'fixture-default-game') {
        throw 'Default package did not pass VERSION and its build output or retain the build default game root.'
    }
}
Invoke-PackageCase 'repeated default packaging rebuilds both stale DLLs and replaces obsolete ZIP entries' {
    foreach ($name in $dllNames) { [IO.File]::WriteAllText((Join-Path $buildRoot $name), 'stale DLL', $utf8) }
    $archive = [IO.Compression.ZipFile]::Open((Join-Path $assets $zipName), [IO.Compression.ZipArchiveMode]::Update)
    try { $archive.CreateEntry('obsolete.txt') | Out-Null } finally { $archive.Dispose() }
    & $package | Out-Null
    Assert-Package
    if ((Get-BuildCallCount) -ne 2) { throw 'Repeated package reused existing build outputs.' }
}
Invoke-PackageCase 'GameRoot, RefsRoot, WorkRoot and DotNetPath reach the build intact' {
    $paths = @{ GameRoot = 'D:\Steam Library\Astral Party\8vJXnINT'; RefsRoot = 'D:\Build References\BepInEx'; WorkRoot = 'D:\Package Work\SDK and References'; DotNetPath = 'D:\Dotnet SDK\dotnet.exe' }
    & $package @paths | Out-Null
    Assert-Package
    $call = [IO.File]::ReadAllLines($callsPath)[-1] | ConvertFrom-Json
    foreach ($key in $paths.Keys) { if ($call.$key -cne $paths[$key]) { throw "Package did not forward $key." } }
    if ((Get-BuildCallCount) -ne 3 -or $call.Version -cne $version -or $call.OutputRoot -cne $buildRoot) { throw 'Forwarded build lost version/output arguments.' }
}
Invoke-PackageCase 'matching canonical Version and Tag are accepted with a custom output directory' {
    $custom = Join-Path $automaticRoot 'custom-release'
    & $package -Version $version -Tag $tag -OutputRoot $custom | Out-Null
    Assert-Package $custom
    if ((Get-BuildCallCount) -ne 4) { throw 'Explicit version/tag skipped the fresh build.' }
}
foreach ($invalidTag in @('v01.0.0', '1.0.0', 'v1.0.0-rc.1')) {
    Invoke-PackageCase "noncanonical Tag rejected before build: $invalidTag" {
        Assert-PreflightRejected @{ Tag = $invalidTag } 'canonical vX.Y.Z'
    }
}
foreach ($invalidVersion in @('01.0.0', 'v1.0.0', '1.0.0-rc.1')) {
    Invoke-PackageCase "noncanonical Version rejected before build: $invalidVersion" {
        Assert-PreflightRejected @{ Version = $invalidVersion } 'canonical X.Y.Z'
    }
}
Invoke-PackageCase 'canonical Tag inconsistent with VERSION is rejected before build' {
    Assert-PreflightRejected @{ Tag = "v$otherVersion" } 'must match VERSION when building'
}
Invoke-PackageCase 'canonical Version inconsistent with VERSION is rejected before build' {
    Assert-PreflightRejected @{ Version = $otherVersion } 'must match VERSION when building'
}
Invoke-PackageCase 'conflicting Version and Tag are rejected before build' {
    Assert-PreflightRejected @{ Version = $otherVersion; Tag = $tag } 'Version and Tag must match'
}
Invoke-PackageCase 'malformed repository VERSION is rejected before build' {
    $path = Join-Path $automaticRoot 'VERSION'
    [IO.File]::WriteAllText($path, '01.0.0', $utf8)
    try { Assert-PreflightRejected @{} 'canonical X.Y.Z' }
    finally { [IO.File]::WriteAllText($path, $version, $utf8) }
}
Invoke-PackageCase 'unexpected output file is rejected before build and preserved' {
    $unexpected = Join-Path $assets 'unrelated.txt'
    [IO.File]::WriteAllText($unexpected, 'preserve', $utf8)
    try { Assert-PreflightRejected @{} 'unexpected file' }
    finally { Remove-Item -LiteralPath $unexpected }
}
Invoke-PackageCase 'unexpected output directory is rejected before build and preserved' {
    $root = Join-Path $automaticRoot 'unexpected-directory'
    $child = Join-Path $root 'unrelated'
    [IO.Directory]::CreateDirectory($child) | Out-Null
    Assert-PreflightRejected @{ OutputRoot = $root } 'unexpected file'
    if (-not (Test-Path -LiteralPath $child -PathType Container)) { throw 'Rejected output directory was removed.' }
}
foreach ($name in $dllNames) {
    foreach ($kind in @('identity', 'version', 'missing')) {
        Invoke-PackageCase "invalid $kind for $name preserves the existing release" {
            $inputPath = Join-Path $inputRoot $name
            $omit = Join-Path $automaticRoot "omit-$name"
            $before = Get-ReleaseHashes $assets
            $callsBefore = Get-BuildCallCount
            try {
                switch ($kind) {
                    'identity' { Copy-Item -LiteralPath $wrongIdentity -Destination $inputPath -Force }
                    'version' { Copy-Item -LiteralPath $wrongVersions[$name] -Destination $inputPath -Force }
                    'missing' { [IO.File]::WriteAllText($omit, '', $utf8) }
                }
                $message = switch ($kind) { 'identity' { 'Unexpected plugin assembly' } 'version' { 'must match the built DLL version' } 'missing' { 'Missing plugin DLL' } }
                Assert-Rejected @{} $message
                if ((Get-BuildCallCount) -ne $callsBefore + 1 -or (Get-ReleaseHashes $assets) -cne $before) {
                    throw 'Failed DLL validation skipped the build or changed the existing release.'
                }
            } finally {
                Copy-Item -LiteralPath $goodDlls[$name] -Destination $inputPath -Force
                if (Test-Path -LiteralPath $omit) { Remove-Item -LiteralPath $omit }
            }
        }
    }
}
Invoke-PackageCase 'failed default build preserves every existing release asset' {
    $before = Get-ReleaseHashes $assets
    [IO.File]::WriteAllText((Join-Path $automaticRoot 'fail-build'), '', $utf8)
    Assert-Rejected @{} 'Fixture build failed'
    if ((Get-ReleaseHashes $assets) -cne $before) { throw 'Failed build changed existing release assets.' }
}
Invoke-PackageCase 'failed build creates no package from previous DLLs' {
    $failedRoot = Join-Path $automaticRoot 'failed-release'
    Assert-Rejected @{ OutputRoot = $failedRoot } 'Fixture build failed'
    if (Test-Path -LiteralPath $failedRoot) { throw 'Failed build packaged an old DLL.' }
}
Invoke-PackageCase 'missing ZIP source preserves old ZIP, checksums and metadata and removes the temporary archive' {
    . (Join-Path $automaticScripts 'package-files.ps1')
    $before = Get-ReleaseHashes $assets
    $files = [ordered]@{
        'BepInEx/patchers/AstralPartyKoreanPlugin.dataUnity3dRedirect.dll' = $goodDlls[$dllNames[0]]
        'BepInEx/plugins/AstralPartyKoreanPatch/AstralPartyKoreanPlugin.dll' = (Join-Path $testRoot 'missing-source.dll')
    }
    $failed = $false
    try { New-AstralPluginPackage -Files $files -OutputRoot $assets -ZipName $zipName | Out-Null } catch [IO.FileNotFoundException] { $failed = $true }
    if (-not $failed -or (Get-ReleaseHashes $assets) -cne $before) { throw 'Failed ZIP replacement changed release assets or leaked a temporary archive.' }
    Assert-Package
}
Write-Output "$passed Korean release package checks passed. No game or external service was used."
$global:LASTEXITCODE = 0
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $cleanupRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).ProviderPath)
        $cleanupParent = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testParent).ProviderPath).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $cleanupRoot.StartsWith($cleanupParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($cleanupRoot) -cnotmatch '\A[a-f0-9]{32}\z') {
            throw 'Refusing to clean a package fixture outside the unique test directory.'
        }
        Remove-Item -LiteralPath $cleanupRoot -Recurse -Force
    }
}
