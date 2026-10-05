#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $root 'scripts/reference-files.ps1')
$fixture = Join-Path $root ('.work/reference-tests/' + [Guid]::NewGuid().ToString('N'))
$gameRoot = Join-Path $fixture 'game'
$workRoot = Join-Path $fixture 'cache'
$sourceRoot = Join-Path $gameRoot 'BepInEx'
$sampleAssembly = [System.Management.Automation.PSObject].Assembly.Location
$relativePaths = @(Get-AstralReferencePaths)

try {
    foreach ($relative in $relativePaths) {
        $path = Join-Path $sourceRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Copy-Item -LiteralPath $sampleAssembly -Destination $path
    }
    Sync-AstralReferences -GameRoot $gameRoot -WorkRoot $workRoot | Out-Null
    $refs = Join-Path $workRoot 'refs'
    $record = Get-Content -LiteralPath (Join-Path $refs 'versions.json') -Raw | ConvertFrom-Json
    if ($record.references.Count -ne $relativePaths.Count) { throw 'Reference inventory is incomplete.' }
    foreach ($entry in $record.references) {
        if ((Get-FileHash -LiteralPath (Join-Path $refs $entry.file)).Hash.ToLowerInvariant() -cne $entry.sha256) {
            throw 'Cached reference hash differs from its recorded version.'
        }
    }
    Write-Output 'PASS references: copies local DLLs and records their actual versions without downloads.'

    # A missing later dependency must not partially overwrite an existing cache.
    $cached = Join-Path $refs $relativePaths[0]
    [IO.File]::WriteAllText($cached, 'preserve existing cached reference')
    $before = (Get-FileHash -LiteralPath $cached).Hash
    Remove-Item -LiteralPath (Join-Path $sourceRoot $relativePaths[-1])
    $rejected = $false
    try { Sync-AstralReferences -GameRoot $gameRoot -WorkRoot $workRoot | Out-Null }
    catch {
        if ($_.Exception.Message -notlike '*Missing build reference:*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Get-FileHash -LiteralPath $cached).Hash -cne $before) {
        throw 'Incomplete references changed the existing cache.'
    }
    Write-Output 'PASS references: incomplete game references fail before changing the cache.'
    $global:LASTEXITCODE = 0
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $root '.work/reference-tests')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test fixture location.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
