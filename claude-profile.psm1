# claude-profile -- PowerShell wrapper for Windows.
#
# The POSIX half of this tool works by defining a shell function named `claude`
# that shadows the real binary. PowerShell cannot see a POSIX function, so on
# Windows that mechanism has to be built a second time; this file is it.
#
# Only two things are reimplemented here: working out which profile is selected,
# and starting claude with CLAUDE_CONFIG_DIR pointed at it. Both are on the path
# you take every time you type `claude`, and spawning bash to answer them would
# be felt. Everything else -- create, update, delete, show, diff, export, import,
# statusline -- is handed to claude-profile.sh under Git Bash, so the logic with
# actual risk in it (copying trees, moving backups, rewriting JSON) keeps exactly
# one implementation.
#
# ASCII only, deliberately. Windows PowerShell 5.1 reads a script with no BOM as
# Windows-1252, so a UTF-8 em dash in a comment here would arrive as mojibake.
# The .sh files in this repo are free to use them; this one is not.

$script:CpRoot   = $PSScriptRoot
$script:CpScript = Join-Path $PSScriptRoot 'claude-profile.sh'
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

function Get-CpStore {
    if ($env:CLAUDE_PROFILES_DIR) { return $env:CLAUDE_PROFILES_DIR }
    return $script:CpRoot
}

function Get-CpProfileDir {
    param([string]$Name)
    return (Join-Path (Join-Path (Get-CpStore) 'profiles') $Name)
}

function Get-CpBaseDir {
    # $env:HOME first, then PowerShell's $HOME. Git Bash takes HOME from the
    # environment whenever it is set, and a good number of Windows setups do set
    # it; PowerShell's $HOME comes from USERPROFILE and ignores it. Reading only
    # $HOME here would leave the two halves of this tool disagreeing about where
    # the base ~/.claude is, on exactly the machines that had customised it.
    $h = if ($env:HOME) { $env:HOME } else { $HOME }
    return (Join-Path $h '.claude')
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

# Hand a subcommand to claude-profile.sh under Git Bash.
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
    try {
        if (Test-CpWindowsPath $oldStore) {
            $env:CLAUDE_PROFILES_DIR = ConvertTo-CpPosixPath $oldStore
        }
        & $bash (ConvertTo-CpPosixPath $script:CpScript) @converted
    } finally {
        Set-CpEnv 'CLAUDE_PROFILES_DIR' $oldStore
    }
}

# _cp_launch wraps every session in this so a trust dialog answered once is not
# asked again in the next profile. A native launch has no _cp_launch, so call the
# same code directly. Best effort by design: no Git Bash, or no python3 on the
# other side, costs you a repeated prompt, not a failed launch.
function Sync-CpPrompts {
    param([string]$Dir)
    if ($env:CLAUDE_PROFILE_NO_SYNC) { return }
    # Same early-out as _cp_sync_prompts, and the reason the default profile pays
    # nothing for any of this.
    if ($Dir -eq (Get-CpBaseDir)) { return }
    $bash = Get-CpBash
    if (-not $bash) { return }
    # Discarding stdout, which a successful sync does not produce anyway. The
    # case this is really for: where python3 on PATH is the Microsoft Store's
    # App Execution Alias rather than Python, it prints an advert and exits 0 --
    # passing the `command -v python3` guard on the sh side and then printing
    # that advert on every single launch. Errors still go to stderr and show.
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

function claude {
    # No param block and no [CmdletBinding()] on purpose. Both would make
    # PowerShell try to bind --create, -p and friends as parameters of this
    # function; with neither, every token lands in $args untouched.
    $rest = @($args)

    if ($rest.Count -ge 1 -and $rest[0] -eq 'profile') {
        $sub = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

        # `claude profile <name> -- <args>`: one session in <name>, active
        # profile untouched. Kept native because the thing it ends in is an
        # interactive TUI, which cannot be run down a non-interactive bash -c.
        #
        # The separator cannot be tested for. PowerShell's parser treats a bare
        # `--` as end-of-parameters and consumes it when calling a function, so
        # `claude profile dev -- --version` arrives here as just dev, --version.
        # Quoting it ('--') does survive, and so does a second one, which is why
        # the strip below is conditional rather than assumed.
        #
        # Detecting the form by shape instead is safe: the setter takes exactly
        # one argument, so a bare name followed by anything at all can only have
        # come from a separator that was eaten. Reading it as a set would take
        # the trailing arguments and silently drop them.
        if ($sub.Count -ge 2 -and -not $sub[0].StartsWith('-')) {
            $name = $sub[0]
            $from = if ($sub[1] -eq '--') { 2 } else { 1 }
            $runArgs = if ($sub.Count -gt $from) { @($sub[$from..($sub.Count - 1)]) } else { @() }
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
        # directory, so even bare `claude profile` walks up for a .claude-profile
        # from where you actually are and reports the same answer we would.
        Invoke-CpBash $sub
        return
    }

    Start-CpClaude (Resolve-CpConfigDir) $rest
}

Export-ModuleMember -Function claude
