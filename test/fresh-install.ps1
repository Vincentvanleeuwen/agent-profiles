$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ("agent-profiles-fresh-" + [guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $root 'home'
$profilePath = Join-Path $fakeHome 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
$oldHome = $env:HOME
$oldStore = $env:CLAUDE_PROFILES_DIR

try {
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    $env:HOME = $fakeHome
    $env:CLAUDE_PROFILES_DIR = Join-Path $fakeHome '.agent-profiles'

    & (Join-Path $repoRoot 'install.ps1') -ProfilePath $profilePath
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
    if ($profileText -notmatch 'agent-profile\.psm1') {
        throw 'PowerShell profile does not import agent-profile.psm1'
    }
    if ($profileText -match 'claude-profile\.psm1') {
        throw 'PowerShell profile imports the compatibility module'
    }

    Write-Host 'fresh PowerShell clone install passed'
}
finally {
    $env:HOME = $oldHome
    $env:CLAUDE_PROFILES_DIR = $oldStore
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
