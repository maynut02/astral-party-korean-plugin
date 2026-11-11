#requires -Version 7.2

function Assert-AstralPackageDirectory([string]$Root, [string[]]$AllowedFiles) {
    if (-not (Test-Path -LiteralPath $Root)) { return }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'Release output must be a directory.' }
    foreach ($entry in Get-ChildItem -LiteralPath $Root -Force) {
        if ($entry.PSIsContainer -or $entry.Name -cnotin $AllowedFiles) {
            throw 'Release output directory contains an unexpected file. Use a separate empty directory.'
        }
    }
}

function Assert-AstralPluginAssembly([string]$Path, [string]$Name, [string]$Version) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing plugin DLL: $Path" }
    if ([Reflection.AssemblyName]::GetAssemblyName($Path).Name -cne $Name) { throw "Unexpected plugin assembly: $Path" }
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductVersion -cne $Version) {
        throw 'Package tag must match the built DLL version. Rebuild with the requested release version.'
    }
}

# [0] is the two-file package the plugin's updater downloads; [1] is the installer package players download.
function Get-AstralReleaseAssetNames([string]$Tag) {
    @("update-$Tag.zip", "AstralPartyKoreanPlugin-$Tag.zip", 'update.json', 'update.json.sig', 'SHA256SUMS.txt')
}

function Get-AstralBepInExArchive {
    param([string]$WorkRoot, [string]$ExpectedSha256 = 'f4cc496bd098a0df4164b81e3737297707f13a47c2478dba2f60eefab784817a', [long]$ExpectedSize = 34336405)

    $name = 'BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788+5b766a3.zip'
    $path = Join-Path $WorkRoot "bepinex/$name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        $temporary = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            Invoke-WebRequest -Uri 'https://builds.bepinex.dev/projects/bepinex_be/788/BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.788%2B5b766a3.zip' -OutFile $temporary
            if ((Get-Item -LiteralPath $temporary).Length -ne $ExpectedSize -or
                (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
                throw 'Pinned BepInEx download size or SHA-256 mismatch.'
            }
            Move-Item -LiteralPath $temporary -Destination $path
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    if ((Get-Item -LiteralPath $path).Length -ne $ExpectedSize -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
        throw 'Pinned BepInEx cache size or SHA-256 mismatch. Remove the corrupt cache file and retry.'
    }
    return $path
}

function New-AstralZipPackage {
    param([Collections.IDictionary]$Files, [string]$OutputRoot, [string]$ZipName, [Parameter(Mandatory)][DateTimeOffset]$Timestamp, [string]$BaseArchive = '')

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    $zipPath = Join-Path $OutputRoot $ZipName
    $temporary = Join-Path $OutputRoot ('.' + $ZipName + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($BaseArchive) {
                $source = [IO.Compression.ZipFile]::OpenRead($BaseArchive)
                try {
                    foreach ($entry in $source.Entries) {
                        if (-not $names.Add($entry.FullName)) { throw 'Duplicate BepInEx ZIP entry.' }
                        $copy = $archive.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                        $copy.LastWriteTime = $Timestamp
                        $inputStream = $entry.Open()
                        $outputStream = $copy.Open()
                        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                    }
                } finally { $source.Dispose() }
            }
            foreach ($file in $Files.GetEnumerator()) {
                if (-not $names.Add($file.Key)) { throw "Package path collides with BepInEx: $($file.Key)" }
                $entry = $archive.CreateEntry($file.Key, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $Timestamp
                $stream = $entry.Open()
                try {
                    if ($file.Value -is [byte[]]) { $stream.Write($file.Value, 0, $file.Value.Length) }
                    else {
                        $inputStream = [IO.File]::OpenRead($file.Value)
                        try { $inputStream.CopyTo($stream) } finally { $inputStream.Dispose() }
                    }
                } finally { $stream.Dispose() }
            }
        } finally { $archive.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $zipPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{ Path = $zipPath; Sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(); Size = (Get-Item -LiteralPath $zipPath).Length }
}

function Get-AstralSigningKeyPath([string]$Path = '') {
    if ($Path) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    if ($env:ASTRAL_UPDATE_SIGNING_KEY) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:ASTRAL_UPDATE_SIGNING_KEY) }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.astral-party/plugin-update-signing.pem'
}

function Get-AstralUpdatePublicKey {
    return 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEylLFkAOyq5ioR6NxNYMWG5R6d1tocK4EeRzPIf6r6Ia4U5mn9lKCi9nwkm8g6LoAfulbxhT8954C9+/Lrj4UJA=='
}

function Get-AstralSigningKey {
    param([string]$Path, [string]$PublicKey = (Get-AstralUpdatePublicKey))

    $Path = Get-AstralSigningKeyPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing update signing key: $Path" }
    $key = [Security.Cryptography.ECDsa]::Create()
    try {
        # ImportFromPem rejects encrypted PEM; the public-key match below rejects every other key.
        $key.ImportFromPem([IO.File]::ReadAllText($Path))
        if ($key.KeySize -ne 256 -or [Convert]::ToBase64String($key.ExportSubjectPublicKeyInfo()) -cne $PublicKey) {
            throw 'Update signing key does not match the trusted P-256 public key. Rotate the embedded trust key deliberately before release.'
        }
        return $key
    } catch { $key.Dispose(); throw }
}

function Assert-AstralUpdateSignature {
    param([byte[]]$Bytes, [string]$Signature, [string]$PublicKey = (Get-AstralUpdatePublicKey))

    $key = [Security.Cryptography.ECDsa]::Create()
    try {
        $read = 0
        $der = [Convert]::FromBase64String($PublicKey)
        $key.ImportSubjectPublicKeyInfo($der, [ref]$read)
        $signatureBytes = [Convert]::FromBase64String($Signature)
        if ($read -ne $der.Length -or $key.KeySize -ne 256 -or $signatureBytes.Length -ne 64 -or
            -not $key.VerifyData($Bytes, $signatureBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)) {
            throw 'Update manifest signature does not match the trusted public key.'
        }
    } finally { $key.Dispose() }
}

function New-AstralUpdateManifest {
    param([string]$Version, [string]$Repository, [string]$OutputRoot, [Collections.IDictionary]$Files, [string]$SigningKeyPath = '', [string]$PublicKey = (Get-AstralUpdatePublicKey))

    $names = @(Get-AstralReleaseAssetNames "v$Version")
    $name = $names[0]
    $package = Join-Path $OutputRoot $name
    $manifest = [ordered]@{
        schemaVersion = 1
        version = $Version
        package = [ordered]@{
            name = $name
            url = "https://github.com/$Repository/releases/download/v$Version/$name"
            size = (Get-Item -LiteralPath $package).Length
            sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        files = @(foreach ($file in $Files.GetEnumerator()) {
            [ordered]@{ path = $file.Key; size = (Get-Item -LiteralPath $file.Value).Length; sha256 = (Get-FileHash -LiteralPath $file.Value -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        minimumBepInEx = '6.0.0-be.788'
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 5) + "`n")
    $key = Get-AstralSigningKey -Path $SigningKeyPath -PublicKey $PublicKey
    try { $signature = [Convert]::ToBase64String($key.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)) }
    finally { $key.Dispose() }
    Assert-AstralUpdateSignature -Bytes $bytes -Signature $signature -PublicKey $PublicKey
    [IO.File]::WriteAllBytes((Join-Path $OutputRoot 'update.json'), $bytes)
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'update.json.sig'), $signature, [Text.Encoding]::ASCII)
    $checksums = foreach ($asset in @($names[0], $names[1], 'update.json')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $OutputRoot $asset) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $asset"
    }
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'SHA256SUMS.txt'), ($checksums -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function Assert-AstralReleaseAssets {
    param([string]$Tag, [string]$Repository, [string]$Root, [string]$PublicKey = (Get-AstralUpdatePublicKey))

    $names = @(Get-AstralReleaseAssetNames $Tag)
    $hashes = @{}
    foreach ($name in $names) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release asset: $name. Run scripts/package-release.ps1 first." }
        $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $expectedChecksums = @($names[0], $names[1], 'update.json') | ForEach-Object { "$($hashes[$_])  $_" }
    $checksums = [IO.File]::ReadAllLines((Join-Path $Root 'SHA256SUMS.txt'))
    if (($checksums -join "`n") -cne ($expectedChecksums -join "`n")) { throw 'Release checksums must match both ZIPs and update.json, with no extra entries.' }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Root 'update.json'))
    Assert-AstralUpdateSignature -Bytes $bytes -Signature ([IO.File]::ReadAllText((Join-Path $Root 'update.json.sig'))) -PublicKey $PublicKey
    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
    $zip = Join-Path $Root $names[0]
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -cne $Tag.Substring(1) -or $manifest.minimumBepInEx -cne '6.0.0-be.788' -or
        $manifest.package.name -cne $names[0] -or $manifest.package.url -cne "https://github.com/$Repository/releases/download/$Tag/$($names[0])" -or
        $manifest.package.size -ne (Get-Item -LiteralPath $zip).Length -or $manifest.package.sha256 -cne $hashes[$names[0]]) {
        throw 'Update manifest does not describe this release package.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $expected = @('BepInEx/plugins/AstralPartyKoreanPlugin/AstralPartyKoreanPlugin.dll', 'BepInEx/plugins/AstralPartyKoreanPlugin/astralkorean_fonts.bundle')
        if ($archive.Entries.Count -ne 2 -or (($archive.Entries.FullName | Sort-Object) -join "`n") -cne (($expected | Sort-Object) -join "`n") -or @($manifest.files).Count -ne 2 -or
            (($manifest.files.path | Sort-Object) -join "`n") -cne (($expected | Sort-Object) -join "`n")) { throw 'Release ZIP and update manifest must contain exactly the plugin DLL and font bundle.' }
        foreach ($entry in $archive.Entries) {
            $file = @($manifest.files | Where-Object { $_.path -ceq $entry.FullName })[0]
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() } finally { $sha.Dispose(); $stream.Dispose() }
            if ($file.size -ne $entry.Length -or $file.sha256 -cne $hash) { throw 'Update manifest file size or SHA-256 mismatch.' }
        }
    } finally { $archive.Dispose() }
    return $hashes
}
