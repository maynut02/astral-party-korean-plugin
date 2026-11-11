#requires -Version 7.0
param([string]$DotNetPath = '')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/package-files.ps1')
. (Join-Path $repoRoot 'scripts/dotnet-sdk.ps1')
$dotnet = Get-AstralDotnet -Root $repoRoot -WorkRoot (Join-Path $repoRoot '.work') -DotNetPath $DotNetPath
$testRoot = Join-Path $repoRoot ('.work/package-tests/' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$version = '4.5.6'
$tag = "v$version"
$names = @(Get-AstralReleaseAssetNames $tag)
$passed = 0
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Rejected([scriptblock]$Body, [string]$Message = '') {
    $failed = $false
    try { & $Body | Out-Null } catch { if ($Message -and -not $_.Exception.Message.Contains($Message)) { throw }; $failed = $true }
    Assert-True $failed "Expected rejection: $Message"
}
function Test-Case([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Output "PASS package: $Name" }
function Get-Fingerprint([string]$Root) {
    (@(Get-ChildItem -LiteralPath $Root -File -Force | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|')
}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $assemblyRoot = Join-Path $testRoot 'assembly'
    [IO.Directory]::CreateDirectory($assemblyRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $assemblyRoot 'Fixture.csproj'), "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>net6.0</TargetFramework><AssemblyName>AstralPartyKoreanPlugin</AssemblyName><Version>$version</Version><IncludeSourceRevisionInInformationalVersion>false</IncludeSourceRevisionInInformationalVersion></PropertyGroup></Project>", $utf8)
    [IO.File]::WriteAllText((Join-Path $assemblyRoot 'Fixture.cs'), 'public static class Fixture { }', $utf8)
    [IO.File]::WriteAllText((Join-Path $assemblyRoot 'NuGet.Config'), '<configuration><packageSources><clear /></packageSources></configuration>', $utf8)
    $output = @(& $dotnet build (Join-Path $assemblyRoot 'Fixture.csproj') -c Release --nologo 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Package fixture build failed: $($output -join "`n")" }
    $dll = Join-Path $assemblyRoot 'bin/Release/net6.0/AstralPartyKoreanPlugin.dll'
    $root = Join-Path $testRoot 'fixture'
    foreach ($directory in @('scripts', 'installer', 'assets/third-party', 'build-input', '.work/bepinex')) { [IO.Directory]::CreateDirectory((Join-Path $root $directory)) | Out-Null }
    foreach ($name in @('package-release.ps1', 'project-version.ps1', 'release-notes.ps1', 'package-files.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/$name") -Destination (Join-Path $root "scripts/$name") }
    Copy-Item -LiteralPath $dll -Destination (Join-Path $root 'build-input/AstralPartyKoreanPlugin.dll')
    [IO.File]::WriteAllText((Join-Path $root 'build-input/astralkorean_fonts.bundle'), 'UnityFS fixture font bundle', $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'installer/install.bat'), '@echo off', $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'installer/install.ps1'), '# Offline installer fixture', $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'assets/third-party/LICENSE-BepInEx.txt'), 'fixture license', $utf8)
    $runtime = Join-Path $root '.work/bepinex/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788+5b766a3.zip'
    $runtimeFiles = [ordered]@{
        '.doorstop_version' = [Text.Encoding]::ASCII.GetBytes('4')
        'BepInEx/core/BepInEx.Core.dll' = [Text.Encoding]::ASCII.GetBytes('runtime fixture')
        'BepInEx/patchers/' = [byte[]]@()
        'BepInEx/plugins/' = [byte[]]@()
        'doorstop_config.ini' = [Text.Encoding]::ASCII.GetBytes('[General]')
        'dotnet/runtime.dll' = [Text.Encoding]::ASCII.GetBytes('dotnet fixture')
        'winhttp.dll' = [Text.Encoding]::ASCII.GetBytes('doorstop fixture')
        'changelog.txt' = [Text.Encoding]::ASCII.GetBytes('fixture changelog')
    }
    New-AstralZipPackage -Files $runtimeFiles -OutputRoot ([IO.Path]::GetDirectoryName($runtime)) -ZipName ([IO.Path]::GetFileName($runtime)) | Out-Null
    $runtimeHash = (Get-FileHash -LiteralPath $runtime).Hash.ToLowerInvariant()
    $runtimeSize = (Get-Item -LiteralPath $runtime).Length
    # Network access is forbidden even if a regression tries to fetch the fixture.
    function Invoke-WebRequest { throw 'Package tests must never access the network.' }
    Test-Case 'assembly-identity-version-and-presence-are-enforced' {
        Assert-AstralPluginAssembly -Path $dll -Name 'AstralPartyKoreanPlugin' -Version $version
        Assert-Rejected { Assert-AstralPluginAssembly -Path $dll -Name 'UnrelatedPlugin' -Version $version } 'Unexpected plugin assembly'
        Assert-Rejected { Assert-AstralPluginAssembly -Path $dll -Name 'AstralPartyKoreanPlugin' -Version '4.5.7' } 'must match the built DLL version'
        Assert-Rejected { Assert-AstralPluginAssembly -Path (Join-Path $testRoot 'missing.dll') -Name 'AstralPartyKoreanPlugin' -Version $version } 'Missing plugin DLL'
    }
    Test-Case 'pinned-cache-validates-size-and-sha256-without-network' {
        Assert-True ((Get-AstralBepInExArchive -WorkRoot (Join-Path $root '.work') -ExpectedSha256 $runtimeHash -ExpectedSize $runtimeSize) -ceq $runtime) 'Cache lookup differs.'
        Assert-Rejected { Get-AstralBepInExArchive -WorkRoot (Join-Path $root '.work') -ExpectedSha256 ('0' * 64) -ExpectedSize $runtimeSize } 'cache size or SHA-256 mismatch'
        Assert-Rejected { Get-AstralBepInExArchive -WorkRoot (Join-Path $root '.work') -ExpectedSha256 $runtimeHash -ExpectedSize ($runtimeSize + 1) } 'cache size or SHA-256 mismatch'
        Assert-Rejected { Get-AstralBepInExArchive -WorkRoot (Join-Path $root '.work') } 'cache size or SHA-256 mismatch'
    }
    $key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    try {
        $publicKey = [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo())
        $keyPath = Join-Path $root '.work/key.pem'
        [IO.File]::WriteAllText($keyPath, [string]::new([Security.Cryptography.PemEncoding]::Write('PRIVATE KEY', $key.ExportPkcs8PrivateKey())), $utf8)
    } finally { $key.Dispose() }
    # Override only the copied fixture's pin and trust key, never production inputs.
    $overrides = "`nfunction Get-AstralUpdatePublicKey { '$publicKey' }`nfunction Get-AstralBepInExArchive { param([string]`$WorkRoot) '$($runtime.Replace("'", "''"))' }`n"
    [IO.File]::AppendAllText((Join-Path $root 'scripts/package-files.ps1'), $overrides, $utf8)
    $buildStub = @'
param([string]$Version, [string]$GameRoot = 'fixture-default', [string]$RefsRoot, [string]$WorkRoot, [string]$OutputRoot, [string]$DotNetPath)
$root = Join-Path $PSScriptRoot '..'
[IO.File]::AppendAllText((Join-Path $root '.work/build-calls.jsonl'), (([ordered]@{ Version = $Version; GameRoot = $GameRoot; RefsRoot = $RefsRoot; WorkRoot = $WorkRoot; OutputRoot = $OutputRoot; DotNetPath = $DotNetPath } | ConvertTo-Json -Compress) + "`n"))
if (Test-Path (Join-Path $root '.work/fail-build')) { throw 'Fixture build failed.' }
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
foreach ($name in @('AstralPartyKoreanPlugin.dll', 'astralkorean_fonts.bundle')) { Copy-Item -LiteralPath (Join-Path $root "build-input/$name") -Destination (Join-Path $OutputRoot $name) -Force }
[IO.File]::WriteAllText((Join-Path $OutputRoot 'build-references.json'), '{"references":[]}', [Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText((Join-Path $root 'scripts/build.ps1'), $buildStub, $utf8)
    $package = Join-Path $root 'scripts/package-release.ps1'
    $arguments = @{ Version = $version; SigningKeyPath = $keyPath; Repository = 'owner/repo' }
    $assets = Join-Path $root "dist/release/$tag"
    Test-Case 'fresh-build-produces-both-zips-signed-manifest-and-three-checksums' {
        & $package @arguments | Out-Null
        $calls = [IO.File]::ReadAllLines((Join-Path $root '.work/build-calls.jsonl'))
        Assert-True ($calls.Count -eq 1 -and ($calls[0] | ConvertFrom-Json).Version -ceq $version) 'Packaging did not build exactly once at the release version.'
        Assert-AstralReleaseAssets -Tag $tag -Repository 'owner/repo' -Root $assets -PublicKey $publicKey | Out-Null
        Assert-True ([IO.File]::ReadAllLines((Join-Path $assets 'SHA256SUMS.txt')).Count -eq 3) 'Checksum list differs.'
        $bytes = [IO.File]::ReadAllBytes((Join-Path $assets 'update.json'))
        Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Manifest has a UTF-8 BOM.'
        $signature = [IO.File]::ReadAllText((Join-Path $assets 'update.json.sig'))
        Assert-True ([Convert]::FromBase64String($signature).Length -eq 64) 'Signature is not IEEE P1363 P-256.'
        $manifest = [IO.File]::ReadAllText((Join-Path $assets 'update.json')) | ConvertFrom-Json
        Assert-True ($manifest.version -ceq $version -and $manifest.minimumBepInEx -ceq '6.0.0-be.788' -and $manifest.files.Count -eq 2) 'Manifest contract differs.'
    }
    Test-Case 'full-zip-retains-every-runtime-entry-and-adds-offline-installation-layout' {
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $assets $names[1]))
        try {
            $expected = @($runtimeFiles.Keys) + @('BepInEx/config/BepInEx.cfg', 'BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll', 'BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle', 'LICENSE-BepInEx.txt', 'install.bat', 'install.ps1')
            Assert-True ((($archive.Entries.FullName | Sort-Object) -join '|') -ceq (($expected | Sort-Object) -join '|')) 'Full package entries differ.'
            foreach ($name in $runtimeFiles.Keys) {
                $memory = [IO.MemoryStream]::new()
                $stream = $archive.GetEntry($name).Open()
                try { $stream.CopyTo($memory); Assert-True ([Convert]::ToBase64String($memory.ToArray()) -ceq [Convert]::ToBase64String($runtimeFiles[$name])) "Runtime bytes changed: $name" }
                finally { $stream.Dispose(); $memory.Dispose() }
            }
            $reader = [IO.StreamReader]::new($archive.GetEntry('BepInEx/config/BepInEx.cfg').Open())
            try { Assert-True ($reader.ReadToEnd() -ceq "[Logging]`r`nUnityLogListening = false`r`n[Logging.Console]`r`nEnabled = false`r`n") 'Fresh config differs.' } finally { $reader.Dispose() }
            foreach ($name in @('LICENSE-BepInEx.txt', 'install.bat', 'install.ps1')) { Assert-True ($archive.GetEntry($name).Length -gt 0) "Missing full-package input: $name" }
        } finally { $archive.Dispose() }
    }
    Test-Case 'repackaging-rebuilds-but-zip-digests-are-reproducible' {
        $before = @($names[0], $names[1]) | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $assets $_)).Hash }
        & $package @arguments | Out-Null
        $after = @($names[0], $names[1]) | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $assets $_)).Hash }
        Assert-True (($before -join '|') -ceq ($after -join '|')) 'Identical inputs produced different ZIPs.'
        Assert-True ([IO.File]::ReadAllLines((Join-Path $root '.work/build-calls.jsonl')).Count -eq 2) 'Packaging reused stale binaries.'
    }
    Test-Case 'build-options-are-forwarded-and-custom-output-is-supported' {
        $custom = Join-Path $root 'custom-release'
        & $package @arguments -Tag $tag -GameRoot 'D:\Game Path' -RefsRoot 'D:\Refs Path' -DotNetPath 'D:\SDK Path\dotnet.exe' -OutputRoot $custom | Out-Null
        $call = [IO.File]::ReadAllLines((Join-Path $root '.work/build-calls.jsonl'))[-1] | ConvertFrom-Json
        Assert-True ($call.GameRoot -ceq 'D:\Game Path' -and $call.RefsRoot -ceq 'D:\Refs Path' -and $call.DotNetPath -ceq 'D:\SDK Path\dotnet.exe') 'Package lost explicit build paths.'
        Assert-AstralReleaseAssets -Tag $tag -Repository 'owner/repo' -Root $custom -PublicKey $publicKey | Out-Null
    }
    Test-Case 'invalid-options-and-unexpected-output-stop-before-build' {
        $before = [IO.File]::ReadAllLines((Join-Path $root '.work/build-calls.jsonl')).Count
        Assert-Rejected { & $package @arguments -Tag 'v9.0.0' } 'Version and Tag must match'
        Assert-Rejected { & $package -Version '1.2.3-rc.1' -SigningKeyPath $keyPath } 'canonical X.Y.Z'
        [IO.File]::WriteAllText((Join-Path $assets 'unrelated.txt'), 'keep', $utf8)
        try { Assert-Rejected { & $package @arguments } 'unexpected file' } finally { Remove-Item -LiteralPath (Join-Path $assets 'unrelated.txt') }
        Assert-True ([IO.File]::ReadAllLines((Join-Path $root '.work/build-calls.jsonl')).Count -eq $before) 'Invalid settings started a build.'
    }
    Test-Case 'build-failure-and-missing-font-preserve-existing-release' {
        $before = Get-Fingerprint $assets
        [IO.File]::WriteAllText((Join-Path $root '.work/fail-build'), '')
        try { Assert-Rejected { & $package @arguments } 'Fixture build failed' } finally { Remove-Item -LiteralPath (Join-Path $root '.work/fail-build') }
        Assert-True ((Get-Fingerprint $assets) -ceq $before) 'Build failure changed the existing release.'
        $font = Join-Path $root 'build-input/astralkorean_fonts.bundle'
        $fontBytes = [IO.File]::ReadAllBytes($font)
        Remove-Item -LiteralPath $font
        try { Assert-Rejected { & $package @arguments } } finally { [IO.File]::WriteAllBytes($font, $fontBytes) }
        Assert-True ((Get-Fingerprint $assets) -ceq $before) 'Missing font changed existing release assets.'
    }
    Test-Case 'wrong-signing-key-and-tampering-are-rejected' {
        Assert-Rejected { Get-AstralSigningKey -Path $keyPath } 'does not match the trusted'
        $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $assets 'update.json'))
        $signature = [IO.File]::ReadAllText((Join-Path $assets 'update.json.sig'))
        $modified = [byte[]]$manifestBytes.Clone()
        $modified[0] = $modified[0] -bxor 1
        Assert-Rejected { Assert-AstralUpdateSignature -Bytes $modified -Signature $signature -PublicKey $publicKey } 'signature does not match'
        Assert-Rejected { Assert-AstralUpdateSignature -Bytes $manifestBytes -Signature ([Convert]::ToBase64String([byte[]]::new(64))) -PublicKey $publicKey } 'signature does not match'
        Assert-Rejected { Assert-AstralUpdateSignature -Bytes $manifestBytes -Signature ([Convert]::ToBase64String([byte[]]::new(65))) -PublicKey $publicKey } 'signature does not match'
    }
    Test-Case 'failed-zip-replacement-removes-temporary-file-and-preserves-old-zip' {
        $before = Get-Fingerprint $assets
        Assert-Rejected { New-AstralZipPackage -Files ([ordered]@{ 'missing.bundle' = (Join-Path $testRoot 'missing.bundle') }) -OutputRoot $assets -ZipName $names[0] }
        Assert-True ((Get-Fingerprint $assets) -ceq $before) 'Failed ZIP replacement leaked or changed files.'
    }
    Write-Output "Package tests passed: $passed cases. Only local fixture archives and throwaway signing keys were used."
    $global:LASTEXITCODE = 0
} finally { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }
