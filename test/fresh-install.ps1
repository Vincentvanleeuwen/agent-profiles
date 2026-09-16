param([string]$PackagePath)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ("agent-profiles-fresh-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $root 'home'
$profilePath = Join-Path $fakeHome 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
$oldHome = $env:HOME
$oldStore = $env:CLAUDE_PROFILES_DIR
$oldInstall = $env:CLAUDE_PROFILE_INSTALL_DIR

try {
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $env:HOME = $fakeHome
    $env:CLAUDE_PROFILES_DIR = Join-Path $fakeHome '.agent-profiles'
    $env:CLAUDE_PROFILE_INSTALL_DIR = Join-Path $fakeHome '.agent-profile'

    if ($PackagePath) {
        $prefix = Join-Path $root 'npm-prefix'
        npm install --global --ignore-scripts --prefix $prefix $PackagePath
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
        & (Join-Path $prefix 'agent-profile-install.cmd') -ProfilePath $profilePath
        if ($LASTEXITCODE -ne 0) { throw 'agent-profile-install failed' }
    } else {
        & (Join-Path $repoRoot 'install.ps1') -ProfilePath $profilePath
    }
    . $profilePath

    if ((Get-Command claude).CommandType -ne 'Function') {
        throw 'claude is not a function'
    }
    if ((Get-Command agent-profile).CommandType -ne 'Alias') {
        throw 'agent-profile is not an alias'
    }
    if ((Get-Command claude-profile).CommandType -ne 'Alias') {
        throw 'claude-profile compatibility alias is missing'
    }

    $profileText = [IO.File]::ReadAllText($profilePath)
    $installedModule = Join-Path $env:CLAUDE_PROFILE_INSTALL_DIR 'agent-profile.psm1'
    if ($profileText -notmatch [regex]::Escape($installedModule)) {
        throw 'PowerShell profile does not import the stable agent-profile.psm1'
    }
    if ($profileText -match 'claude-profile\.psm1') {
        throw 'PowerShell profile imports the compatibility module'
    }

    if (-not (Test-Path -LiteralPath $installedModule -PathType Leaf)) {
        throw 'stable install does not contain agent-profile.psm1'
    }

    $mode = if ($PackagePath) { 'package' } else { 'clone' }
    Write-Host "fresh PowerShell $mode install passed"
}
finally {
    $env:HOME = $oldHome
    $env:CLAUDE_PROFILES_DIR = $oldStore
    $env:CLAUDE_PROFILE_INSTALL_DIR = $oldInstall
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
