# agent-profile -- PowerShell wrapper for Windows.
#
# The POSIX half of this tool works by defining a shell function named `claude`
# that shadows the real binary. PowerShell cannot see a POSIX function, so on
# Windows that mechanism has to be built a second time; this file is it.
#
# Only two things are reimplemented here: working out which profile is selected,
# and starting claude with CLAUDE_CONFIG_DIR pointed at it. Both are on the path
# you take every time you type `claude`, and spawning bash to answer them would
# be felt. Everything else -- create, update, delete, show, diff, export,
# import -- is handed to agent-profile.sh under Git Bash, so the logic with
# actual risk in it (copying trees, moving backups, rewriting JSON) keeps exactly
# one implementation.
#
# ASCII only, deliberately. Windows PowerShell 5.1 reads a script with no BOM as
# Windows-1252, so a UTF-8 em dash in a comment here would arrive as mojibake.
# The .sh files in this repo are free to use them; this one is not.

$script:CpRoot   = $PSScriptRoot
$script:CpScript = Join-Path $PSScriptRoot 'agent-profile.sh'
$script:CpBash   = $null

function Write-CpError {
    param([string]$Message)
    # Plain stderr line, the way the sh side prints. Write-Error would raise an
    # ErrorRecord with a stack trace attached, which is not what a CLI that is
    # standing in for a shell function should do to someone's terminal.
    [Console]::Error.WriteLine($Message)
}

# Assigning $null to an env var leaves an empty one behind rather than removing
# it, and an empty CLAUDE_CONFIG_DIR is not the same as an absent one.
function Set-CpEnv {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        if (Test-Path -LiteralPath "env:$Name") { Remove-Item -LiteralPath "env:$Name" }
    } else {
        Set-Item -LiteralPath "env:$Name" -Value $Value
    }
}

function Get-CpHome {
    # $env:HOME first, then PowerShell's $HOME. Git Bash takes HOME from the
    # environment whenever it is set, and a good number of Windows setups do set
    # it; PowerShell's $HOME comes from USERPROFILE and ignores it. Reading only
    # $HOME here would leave the two halves of this tool disagreeing about where
    # the base ~/.claude is, on exactly the machines that had customised it.
    if ($env:HOME) { return $env:HOME }
    return $HOME
}

function Get-CpStore {
    if ($env:CLAUDE_PROFILES_DIR) { return $env:CLAUDE_PROFILES_DIR }
    return (Join-Path (Get-CpHome) '.agent-profiles')
}

function Get-CpProfileDir {
    param([string]$Name)
    return (Join-Path (Join-Path (Get-CpStore) 'profiles') $Name)
}

function Get-CpBaseDir {
    return (Join-Path (Get-CpHome) '.claude')
}

# E:\Codeshit\x -> /e/Codeshit/x
#
# Done here rather than left to MSYS's own argument heuristics, which apply to
# some positions and not others. Bash and PowerShell see the same store path
# with different path syntax, and this conversion keeps them in sync.
function ConvertTo-CpPosixPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(/.*)?$') {
        return ('/' + $Matches[1].ToLowerInvariant() + $Matches[2])
    }
    return $p
}

function Test-CpWindowsPath {
    param([string]$Value)
    return ($Value -match '^[A-Za-z]:[\\/]')
}

# Where Git Bash is.
#
# Never `Get-Command bash`: on a machine with WSL installed that resolves to
# C:\Windows\System32\bash.exe, which is a different operating system with a
# different $HOME and a different filesystem. It would run, and it would quietly
# operate on the wrong store.
function Get-CpBash {
    if ($script:CpBash -and (Test-Path -LiteralPath $script:CpBash -PathType Leaf)) {
        return $script:CpBash
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_PROFILE_BASH) { $candidates.Add($env:CLAUDE_PROFILE_BASH) }
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)})) {
        if ($root) { $candidates.Add((Join-Path $root 'Git\bin\bash.exe')) }
    }
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($git) {
        # ...\Git\cmd\git.exe -> ...\Git\bin\bash.exe
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        if ($gitRoot) { $candidates.Add((Join-Path $gitRoot 'bin\bash.exe')) }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            $script:CpBash = $c
            return $c
        }
    }
    return $null
}

# The sh side's _cp_read_name: drop everything from a '#', drop all whitespace,
# take the first line with anything left. Whitespace goes everywhere, not just at
# the ends, so "my name" reads back as "myname" in both implementations.
function Read-CpName {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { $lines = [IO.File]::ReadAllLines($Path) } catch { return '' }
    foreach ($line in $lines) {
        # ReadAllLines strips a BOM it recognises, but a file hand-written from a
        # PowerShell 5.1 prompt is a real possibility here, so do not rely on it.
        $t = $line.TrimStart([char]0xFEFF)
        $t = ($t -replace '#.*$', '') -replace '\s', ''
        if ($t) { return $t }
    }
    return ''
}

# Nearest .claude-profile walking up from the current directory. Get-Location can
# be sitting on a non-filesystem provider (Cert:, HKLM:), which has no parent
# chain worth walking, hence ProviderPath and the try.
function Find-CpPin {
    try { $dir = (Get-Location -PSProvider FileSystem).ProviderPath } catch { return $null }
    while ($dir) {
        $candidate = Join-Path $dir '.claude-profile'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# Mirrors _cp_selected: $CLAUDE_PROFILE, then a .claude-profile pin, then the
# active file, then nothing. Returns the name and which of those answered.
function Get-CpSelected {
    if ($env:CLAUDE_PROFILE) {
        return [pscustomobject]@{ Name = $env:CLAUDE_PROFILE; Source = 'env' }
    }
    $pin = Find-CpPin
    if ($pin) {
        $name = Read-CpName $pin
        if ($name) { return [pscustomobject]@{ Name = $name; Source = "pin:$pin" } }
    }
    $active = Join-Path (Get-CpStore) 'active'
    $name = Read-CpName $active
    if ($name) { return [pscustomobject]@{ Name = $name; Source = 'active' } }
    return [pscustomobject]@{ Name = ''; Source = 'none' }
}

# Mirrors _cp_resolve, including the part that looks like a missing check: a
# selected name is used if a directory of that name exists, with no validity test
# first. The sh side is the same. Keeping the two identical is what lets test.ps1
# assert they agree.
function Resolve-CpConfigDir {
    $sel = Get-CpSelected
    if (-not $sel.Name) { return (Get-CpBaseDir) }
    $dir = Get-CpProfileDir $sel.Name
    if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    Write-CpError ('claude-profile: unknown profile "{0}", using ~/.claude' -f $sel.Name)
    return (Get-CpBaseDir)
}

function Get-CpCodexConfig {
    return (Join-Path (Join-Path (Get-CpHome) '.codex') 'config.toml')
}

function Get-CpCodexDefault {
    return (Join-Path (Get-CpStore) 'codex-default.config.toml')
}

function Get-CpCodexProfile {
    param([string]$Name)
    return (Join-Path (Get-CpProfileDir $Name) 'codex.config.toml')
}

function Copy-CpFileAtomic {
    param([string]$Source, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Destination.tmp.$PID"
    $backup = "$Destination.bak.$PID"
    try {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [IO.File]::Replace($tmp, $Destination, $backup)
        } else {
            [IO.File]::Move($tmp, $Destination)
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Write-CpTextAtomic {
    param([string]$Destination, [string]$Text)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$Destination.tmp.$PID"
    $backup = "$Destination.bak.$PID"
    try {
        [IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [IO.File]::Replace($tmp, $Destination, $backup)
        } else {
            [IO.File]::Move($tmp, $Destination)
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-CpCodexDefault {
    $default = Get-CpCodexDefault
    if (Test-Path -LiteralPath $default -PathType Leaf) { return }
    $live = Get-CpCodexConfig
    if (Test-Path -LiteralPath $live -PathType Leaf) {
        Copy-CpFileAtomic $live $default
    } else {
        Write-CpTextAtomic $default ''
    }
}

function Save-CpCodexCurrent {
    $live = Get-CpCodexConfig
    if (-not (Test-Path -LiteralPath $live -PathType Leaf)) { return }
    $active = Read-CpName (Join-Path (Get-CpStore) 'active')
    $destination = if ($active -and (Test-Path -LiteralPath (Get-CpProfileDir $active) -PathType Container)) {
        Get-CpCodexProfile $active
    } else {
        Get-CpCodexDefault
    }
    Copy-CpFileAtomic $live $destination
}

function Set-CpActiveProfile {
    param([string]$Name)
    $dir = Get-CpProfileDir $Name
    if (-not (Test-CpValidName $Name) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw ('claude-profile: no such profile "{0}"' -f $Name)
    }
    Initialize-CpCodexDefault
    Save-CpCodexCurrent
    $target = Get-CpCodexProfile $Name
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Copy-CpFileAtomic (Get-CpCodexDefault) $target
    }
    Copy-CpFileAtomic $target (Get-CpCodexConfig)
    Write-CpTextAtomic (Join-Path (Get-CpStore) 'active') "$Name`n"
    $env:CLAUDE_CONFIG_DIR = $dir
}

function Set-CpDefaultProfile {
    Initialize-CpCodexDefault
    Save-CpCodexCurrent
    Copy-CpFileAtomic (Get-CpCodexDefault) (Get-CpCodexConfig)
    Remove-Item -LiteralPath (Join-Path (Get-CpStore) 'active') -Force -ErrorAction SilentlyContinue
    $env:CLAUDE_CONFIG_DIR = (Get-CpBaseDir)
}

# Mirrors _cp_valid_name. Only used where the sh side uses it too (_cp_need,
# before running a session in a named profile). The guard that matters is "." --
# without it, <store>/profiles/. is a directory, so an empty or dotted name would
# validate as an existing profile.
function Test-CpValidName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    if ($Name.Contains('*'))             { return $false }
    if ($Name.StartsWith('-'))           { return $false }
    if ($Name -match '\s')               { return $false }
    return $true
}

# Hand a subcommand to agent-profile.sh under Git Bash.
function Invoke-CpBash {
    param([string[]]$CpArgs)

    $bash = Get-CpBash
    if (-not $bash) {
        Write-CpError 'claude-profile: cannot find Git Bash, which this subcommand needs.'
        Write-CpError 'Install Git for Windows, or point $env:CLAUDE_PROFILE_BASH at bash.exe.'
        Write-CpError '(Note: the bash.exe on PATH is WSL, which is a separate filesystem.)'
        $global:LASTEXITCODE = 127
        return
    }

    # Arguments that name a file (--import <file>, --export <name> <file>) arrive
    # in Windows form. Profile names never look like this, so the test is safe.
    $converted = @(foreach ($a in $CpArgs) {
        if (Test-CpWindowsPath $a) { ConvertTo-CpPosixPath $a } else { $a }
    })

    # A store set in Windows form has to cross over too, or bash builds paths out
    # of a string containing backslashes.
    $oldStore = $env:CLAUDE_PROFILES_DIR
    $oldWin   = $env:CLAUDE_PROFILE_WINPATH
    try {
        if (Test-CpWindowsPath $oldStore) {
            $env:CLAUDE_PROFILES_DIR = ConvertTo-CpPosixPath $oldStore
        }
        # Paths bash prints for a person to read (--path, --open, the path line
        # in --show) come back as /c/Users/... otherwise, which is correct in the
        # shell that produced it and unusable in the one that asked. Set here
        # rather than inside the .sh because being run by this wrapper is the
        # thing the sh side cannot work out for itself.
        $env:CLAUDE_PROFILE_WINPATH = '1'
        & $bash (ConvertTo-CpPosixPath $script:CpScript) @converted
    } finally {
        Set-CpEnv 'CLAUDE_PROFILES_DIR' $oldStore
        Set-CpEnv 'CLAUDE_PROFILE_WINPATH' $oldWin
    }
}

# _cp_launch wraps every session in this so a trust dialog answered once is not
# asked again in the next profile. A native launch has no _cp_launch, so call the
# same code directly. Best effort by design: no Git Bash, or no Python on the
# other side, costs you a repeated prompt, not a failed launch.
function Sync-CpPrompts {
    param([string]$Dir)
    if ($env:CLAUDE_PROFILE_NO_SYNC) { return }
    # Same early-out as _cp_sync_prompts, and the reason the default profile pays
    # nothing for any of this.
    if ($Dir -eq (Get-CpBaseDir)) { return }
    $bash = Get-CpBash
    if (-not $bash) { return }
    # Discarding stdout, which a successful sync does not produce anyway.
    # This used to be aimed at the Microsoft Store's App Execution Alias for
    # python3 printing "Python was not found" on every launch, on the belief
    # that the stub wrote to stdout. It writes to stderr and exits 49, so this
    # never suppressed it; the sh side now probes for a Python that runs
    # instead (_cp_python), which stops it at the source. Errors still show.
    & $bash (ConvertTo-CpPosixPath $script:CpScript) --sync-prompts (ConvertTo-CpPosixPath $Dir) | Out-Null
}

function Start-CpClaude {
    param([string]$Dir, [string[]]$ClaudeArgs)

    # -CommandType Application is what stops this resolving to the wrapper
    # function and recursing. Not pinned to .exe: a future npm-style install
    # could put a claude.cmd on PATH instead.
    $exe = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) {
        Write-CpError 'claude-profile: cannot find claude on PATH.'
        $global:LASTEXITCODE = 127
        return
    }

    Sync-CpPrompts $Dir

    $old = $env:CLAUDE_CONFIG_DIR
    $code = 0
    try {
        $env:CLAUDE_CONFIG_DIR = $Dir
        & $exe.Source @ClaudeArgs
        $code = $LASTEXITCODE
    } finally {
        Set-CpEnv 'CLAUDE_CONFIG_DIR' $old
    }

    # After, not before, restoring the caller's exit code: the sync spawns bash,
    # and bash's exit status would otherwise stand in for the session's.
    Sync-CpPrompts $Dir
    $global:LASTEXITCODE = $code
}

# The management surface: everything that is not "start a session".
#
# Reached as `claude-profile` through the alias below rather than by being named
# that outright. PowerShell reads every hyphenated command name as Verb-Noun and
# warns at import time when the verb is not one of its approved ones -- "claude"
# will never be one -- and since the line install.ps1 writes into $PROFILE is a
# plain Import-Module, that warning would print on every session start. Aliases
# are not verb-checked, so this is the one spelling that stays quiet.
function Invoke-CpProfile {
    # No param block and no [CmdletBinding()] on purpose. Both would make
    # PowerShell try to bind --create, -p and friends as parameters of this
    # function; with neither, every token lands in $args untouched.
    $rest = @($args)

    if ($rest.Count -eq 1 -and $rest[0] -eq 'default') {
        try {
            Set-CpDefaultProfile
            Write-Host 'active profile: none (using ~/.claude)'
            $global:LASTEXITCODE = 0
        } catch {
            Write-CpError $_.Exception.Message
            $global:LASTEXITCODE = 1
        }
        return
    }

    if ($rest.Count -eq 1 -and -not ([string]$rest[0]).StartsWith('-')) {
        try {
            Set-CpActiveProfile $rest[0]
            Write-Host ('active profile: {0}' -f $rest[0])
            $global:LASTEXITCODE = 0
        } catch {
            Write-CpError $_.Exception.Message
            $global:LASTEXITCODE = 1
        }
        return
    }

    # `claude-profile <name> -- <args>`: one session in <name>, active profile
    # untouched. Kept native because the thing it ends in is an interactive TUI,
    # which cannot be run down a non-interactive bash -c.
    #
    # The separator cannot be tested for. PowerShell's parser treats a bare `--`
    # as end-of-parameters and consumes it when calling a function, so
    # `claude-profile dev -- --version` arrives here as just dev, --version.
    # Quoting it ('--') does survive, and so does a second one, which is why the
    # strip below is conditional rather than assumed.
    #
    # Detecting the form by shape instead is safe: the setter takes exactly one
    # argument, so a bare name followed by anything at all can only have come
    # from a separator that was eaten. Reading it as a set would take the
    # trailing arguments and silently drop them.
    if ($rest.Count -ge 2 -and -not ([string]$rest[0]).StartsWith('-')) {
        $name = $rest[0]
        $from = if ($rest[1] -eq '--') { 2 } else { 1 }
        $runArgs = if ($rest.Count -gt $from) { @($rest[$from..($rest.Count - 1)]) } else { @() }
        $dir = Get-CpProfileDir $name
        if (-not (Test-CpValidName $name) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
            Write-CpError ('claude-profile: no such profile "{0}"' -f $name)
            $global:LASTEXITCODE = 1
            return
        }
        Start-CpClaude $dir $runArgs
        return
    }

    # Everything else is management. bash inherits this process's working
    # directory, so even a bare `claude-profile` walks up for a .claude-profile
    # from where you actually are and reports the same answer we would.
    Invoke-CpBash $rest
}

Set-Alias -Name claude-profile -Value Invoke-CpProfile
Set-Alias -Name agent-profile -Value Invoke-CpProfile

# The whole reason the import line is worth having: a `claude` that follows the
# active profile rather than always reading ~/.claude. Management lives in
# claude-profile, not behind a subcommand of this.
function claude {
    # No param block and no [CmdletBinding()] on purpose, for the same reason as
    # Invoke-CpProfile above: every token has to reach $args untouched.
    Start-CpClaude (Resolve-CpConfigDir) @($args)
}

# Invoke-CpProfile is exported alongside its alias deliberately. An exported
# alias whose target is not itself exported is resolvable only from inside the
# module's session state, which is not where anyone types.
Export-ModuleMember -Function claude, Invoke-CpProfile -Alias agent-profile, claude-profile
