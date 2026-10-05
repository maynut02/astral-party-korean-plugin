#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repoRoot 'scripts/dotnet-sdk.ps1')
$fixture = Join-Path $repoRoot ('.work/sdk-tests/' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS SDK: $Name"
}
function Set-FixtureVersion([string]$Version) {
    [IO.File]::WriteAllText((Join-Path $fixture 'global.json'), ('{"sdk":{"version":"' + $Version + '","rollForward":"latestPatch"}}'), $utf8)
}

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    Set-FixtureVersion '6.0.428'
    $work = Join-Path $fixture 'work'
    $hostPath = Join-Path $fixture 'sdk-host.ps1'
    [IO.File]::WriteAllText($hostPath, @'
if ((Get-Location).Path -ine $PSScriptRoot) { throw 'SDK resolution did not run from the project root.' }
$mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt'))
$global:LASTEXITCODE = 0
switch ($mode) {
    'sdk' { '6.0.428' }
    'runtime-only' { $global:LASTEXITCODE = 145; 'No .NET SDKs were found.' }
    'invalid-output' { 'Unexpected host output' }
    'broken' { throw 'Broken host' }
}
'@, $utf8)
    Test-Case 'validates-requested-sdk-version' {
        Assert-True ((Get-AstralSdkVersion $fixture) -ceq '6.0.428') 'Requested SDK version changed.'
        Set-FixtureVersion '6.0'
        $rejected = $false
        try { Get-AstralSdkVersion $fixture | Out-Null } catch { $rejected = $true }
        Assert-True $rejected 'Incomplete SDK version was accepted.'
        Set-FixtureVersion '6.0.428'
    }
    Test-Case 'resolves-sdk-from-project-root-and-restores-caller-directory' {
        [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'), 'sdk', $utf8)
        $before = (Get-Location).Path
        Assert-True (Test-AstralDotnetSdk $hostPath $fixture) 'Compatible SDK was rejected.'
        Assert-True ((Get-Location).Path -ceq $before) 'SDK probe changed the caller directory.'
    }
    foreach ($mode in @('runtime-only', 'invalid-output', 'broken')) {
        Test-Case "rejects-$mode-host-and-restores-caller-directory" {
            [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'), $mode, $utf8)
            $before = (Get-Location).Path
            Assert-True (-not (Test-AstralDotnetSdk $hostPath $fixture)) 'Unusable host was accepted as an SDK.'
            Assert-True ((Get-Location).Path -ceq $before) 'Failed SDK probe changed the caller directory.'
        }
    }

    # Replace external host/command lookup boundaries; selection tests need no installed SDK or network.
    $script:validPaths = @()
    $script:probes = @()
    $script:systemPaths = @()
    function Test-AstralDotnetSdk([string]$Path, [string]$Root) {
        $script:probes += $Path
        return $Path -in $script:validPaths
    }
    function Get-Command {
        param($Name, $CommandType, [switch]$All, $ErrorAction)
        if ($Name -eq 'dotnet') {
            foreach ($path in $script:systemPaths) { [pscustomobject]@{ Source = $path } }
        }
    }
    function Invoke-WebRequest { throw 'SDK selection or reuse attempted a network request.' }
    $local = Join-Path $work 'dotnet/dotnet.exe'
    $systemRuntime = Join-Path $fixture 'system-runtime/dotnet.exe'
    $systemSdk = Join-Path $fixture 'system-sdk/dotnet.exe'
    Test-Case 'prefers-compatible-local-sdk' {
        $script:validPaths = @($local, $systemSdk)
        $script:systemPaths = @($systemSdk)
        $script:probes = @()
        Assert-True ((Get-AstralDotnet $fixture $work) -ceq $local) 'Local SDK was not preferred.'
        Assert-True ($script:probes.Count -eq 1) 'Selection probed other hosts after finding the local SDK.'
    }
    Test-Case 'skips-incompatible-local-and-runtime-only-system-hosts' {
        $script:validPaths = @($systemSdk)
        $script:systemPaths = @($systemRuntime, $systemSdk)
        Assert-True ((Get-AstralDotnet $fixture $work) -ceq $systemSdk) 'Selection stopped at an unusable host.'
    }
    Test-Case 'missing-compatible-sdk-provides-setup-command' {
        $script:validPaths = @()
        $script:systemPaths = @($systemRuntime)
        $rejected = $false
        try { Get-AstralDotnet $fixture $work | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*6.0.428*scripts/setup.ps1*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'Missing SDK did not stop before the build.'
    }
    Test-Case 'honors-explicit-sdk-without-falling-back' {
        $script:validPaths = @($hostPath, $local, $systemSdk)
        $script:systemPaths = @($systemSdk)
        Assert-True ((Get-AstralDotnet $fixture $work $hostPath) -ceq $hostPath) 'Explicit SDK was ignored.'
        $script:validPaths = @($local, $systemSdk)
        $rejected = $false
        try { Get-AstralDotnet $fixture $work $hostPath | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*specified dotnet*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'Invalid explicit SDK silently fell back to another host.'
    }
    Test-Case 'reuses-prepared-local-sdk-without-downloading' {
        $script:validPaths = @($local)
        Assert-True ((Install-AstralLocalSdk $fixture $work) -ceq $local) 'SDK reuse returned a different path.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $work 'dotnet-install.ps1'))) 'SDK reuse downloaded an installer.'
    }
    Write-Output "SDK tests passed: $script:passed cases (no SDK downloads)."
    $global:LASTEXITCODE = 0
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work/sdk-tests')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected SDK test fixture location.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
