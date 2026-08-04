# Add the Import-Module line for claude-profile.psm1 to your PowerShell profile,
# then prove it worked. Safe to re-run: an install that is already correct is a
# no-op. The PowerShell counterpart of install.sh, and it exists for the same
# reason -- without that line there is no `claude` function, so `claude profile`
# reaches claude.exe, which treats "profile" as your opening prompt and drops you
# into a session. Nothing about that says "this was never installed".
#
# Usage: .\install.ps1 [-ProfilePath <path>] [-Help]
#
# ASCII only, for the reason given at the top of claude-profile.psm1.

param(
    [string] $ProfilePath,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Usage: .\install.ps1 [options]

  -ProfilePath <path>   PowerShell profile to edit, skipping detection
  -Help                 this

With no options it edits $PROFILE for the current user and host, adds the
Import-Module line, and checks that a fresh PowerShell picks it up.
'@
    exit 0
}

$selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$module  = Join-Path $selfDir 'claude-profile.psm1'
$shim    = Join-Path $selfDir 'claude-profile.sh'

function Say  { param([string]$m) Write-Host $m }
function Warn { param([string]$m) [Console]::Error.WriteLine($m) }
function Die  { param([string]$m) [Console]::Error.WriteLine("install: $m"); exit 1 }

if (-not (Test-Path -LiteralPath $module)) { Die "cannot find $module" }
if (-not (Test-Path -LiteralPath (Join-Path $selfDir 'lib'))) {
    Die "cannot find $selfDir\lib -- is the clone complete?"
}

# Single-quoted so nothing in the path is expanded at profile-load time; a quote
# inside the path is escaped the PowerShell way, by doubling it.
$line = "Import-Module '" + ($module -replace "'", "''") + "'"

$target = if ($ProfilePath) { $ProfilePath } else { $PROFILE }
$explicit = [bool]$ProfilePath

$dir = Split-Path -Parent $target
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Say "created $dir"
}

# Already mentioned? Then either it is our line and there is nothing to do, or it
# points somewhere else, and that is not a decision to make on someone's behalf:
# a second clone, a moved directory, a hand-written variant.
$existingText = ''
if (Test-Path -LiteralPath $target -PathType Leaf) {
    $existingText = [IO.File]::ReadAllText($target)
}

if ($existingText -match 'claude-profile\.psm1') {
    $hasExact = $false
    foreach ($l in ($existingText -split "`r?`n")) {
        if ($l.Trim() -eq $line) { $hasExact = $true; break }
    }
    if ($hasExact) {
        Say "already installed in $target"
    } else {
        Warn "install: $target already refers to claude-profile.psm1, but not the"
        Warn "way this script would write it:"
        foreach ($l in ($existingText -split "`r?`n")) {
            if ($l -match 'claude-profile\.psm1') { Warn "    $l" }
        }
        Warn ""
        Warn "Expected:"
        Warn ""
        Warn "    $line"
        Warn ""
        Die  "remove or fix that line, then run this again. Nothing was changed."
    }
} else {
    $block = "`r`n# claude-profile -- added by install.ps1`r`n$line`r`n"
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        # Append, and append without a BOM. AppendAllText with a BOM-emitting
        # encoding would plant one in the middle of the file. The text is ASCII,
        # which is byte-identical in UTF-8 and Windows-1252, so this is safe
        # whatever the existing file happens to be.
        [IO.File]::AppendAllText($target, $block, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        # A new file does get a BOM: Windows PowerShell 5.1 reads a BOM-less
        # script as Windows-1252, and the BOM is what makes that unambiguous.
        [IO.File]::WriteAllText($target, $block, (New-Object System.Text.UTF8Encoding($true)))
    }
    Say "added the import line to $target"
}

# Execution policy decides whether that file is read at all. Report it; do not
# change it. Silently loosening a security setting on someone's machine is not
# this script's business.
$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted', 'AllSigned')) {
    Warn ""
    Warn "install: the execution policy is $effective, so PowerShell will refuse to"
    Warn "load your profile and the wrapper will never be defined. To allow local"
    Warn "unsigned scripts for your account only:"
    Warn ""
    Warn "    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    Warn ""
}

# Management subcommands shell out to claude-profile.sh. Resolution and launching
# do not, so a missing Git Bash is a partial install, not a broken one -- say so
# now rather than at the first --create.
$bash = $null
foreach ($c in @($env:CLAUDE_PROFILE_BASH,
                 (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
                 (Join-Path "$env:ProgramW6432" 'Git\bin\bash.exe'),
                 (Join-Path "${env:ProgramFiles(x86)}" 'Git\bin\bash.exe'))) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $bash = $c; break }
}
if ($bash) {
    Say "found Git Bash: $bash"
} else {
    Warn ""
    Warn "install: no Git Bash found. Switching and launching profiles will work,"
    Warn "but every management subcommand (--create, --show, --export ...) needs it."
    Warn "Install Git for Windows, or set `$env:CLAUDE_PROFILE_BASH to a bash.exe."
    Warn "Do not point it at the bash.exe on PATH if that is WSL: different HOME,"
    Warn "different filesystem, different store."
    Warn ""
}

if ($target -like '*OneDrive*') {
    Say ""
    Say "note: your PowerShell profile lives under OneDrive, so this line will sync"
    Say "to your other machines. It points at $selfDir, which has to exist there too."
}

# Prove it. A line in a file is not an install; the test is whether the shell you
# type into ends up with `claude` as a function rather than an application.
$hostExe = $null
try { $hostExe = (Get-Process -Id $PID).Path } catch { }
if (-not $hostExe) { $hostExe = 'powershell.exe' }

if ($explicit) {
    # An explicit path can point anywhere, including at a file no host would read,
    # so the honest claim is narrower: dot-sourcing it defines the wrapper.
    $probe = ". '" + ($target -replace "'", "''") + "'; (Get-Command claude -ErrorAction SilentlyContinue).CommandType"
    $seen = & $hostExe -NoLogo -NonInteractive -NoProfile -Command $probe
    if ("$seen".Trim() -eq 'Function') {
        Say "verified: loading $target defines the claude wrapper"
        Say "note: -ProfilePath given, so whether a shell reads that file was not checked"
    } else {
        Die "wrote $target, but loading it does not define the claude wrapper (got '$seen')."
    }
} else {
    $seen = & $hostExe -NoLogo -NonInteractive -Command '(Get-Command claude -ErrorAction SilentlyContinue).CommandType'
    if ("$seen".Trim() -eq 'Function') {
        Say "verified: a new PowerShell session defines the wrapper"
    } else {
        Die @"
wrote $target, but a new PowerShell session does not define the claude
     wrapper (got '$seen'). Run this by hand to see the error:

         $line
"@
    }
}

Say ""
Say "Start a new PowerShell session, or run this in the current one:"
Say ""
Say "    $line"
Say ""
Say "Then:"
Say ""
Say "    claude profile --create development"
Say "    claude profile development"
Say ""
Say "This covers PowerShell only. Git Bash needs its own install:"
Say ""
Say "    $shim  ->  run ./install.sh from Git Bash"
Say ""
Say "Both share one store, so a profile created in either is visible in both."
exit 0
