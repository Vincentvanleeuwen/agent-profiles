# Tests for the PowerShell wrapper, in the spirit of test.sh: a temporary store
# and a temporary HOME, never the real ~/.claude.
#
# The last block is the one worth keeping honest. Profile resolution is the only
# logic that exists twice -- once in lib/resolve.sh, once in agent-profile.psm1 --
# so it is checked against the sh implementation rather than against a hardcoded
# expectation, and drift between the two fails the suite.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\test.ps1
#
# ASCII only, for the reason given at the top of agent-profile.psm1.

$ErrorActionPreference = 'Stop'

$selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $selfDir 'agent-profile.psm1') -Force
$mod = Get-Module agent-profile

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        $script:Pass++
    } else {
        $script:Fail++
        Write-Host "FAIL $Name"
        Write-Host "     expected: $Expected"
        Write-Host "     actual:   $Actual"
    }
}

# --- the two exported surfaces -----------------------------------------------
#
# Needs nothing from the scratch fixtures below, but has to come after Check is
# defined: PowerShell resolves a command at the point of the call, and with
# $ErrorActionPreference = 'Stop' a forward reference would abort the whole file.
#
# The Import-Module above is deliberately plain, with no -DisableNameChecking,
# because that is what install.ps1 writes into $PROFILE. So this doubles as the
# guard on why claude-profile is an alias: name it a function instead and
# PowerShell reads the hyphen as Verb-Noun, finds "claude" among no approved
# verbs, and prints a warning on every single session start.
Check 'claude is exported as a function' 'Function' `
    (Get-Command claude -ErrorAction SilentlyContinue).CommandType
Check 'claude-profile is exported as an alias' 'Alias' `
    (Get-Command claude-profile -ErrorAction SilentlyContinue).CommandType
Check 'agent-profile is exported as an alias' 'Alias' `
    (Get-Command agent-profile -ErrorAction SilentlyContinue).CommandType
Check 'claude-profile resolves to the dispatcher' 'Invoke-CpProfile' `
    (Get-Command claude-profile -ErrorAction SilentlyContinue).Definition
# An exported alias whose target is not itself exported resolves only inside the
# module's session state, which is not where anyone types.
Check 'the alias target is exported too' 'Function' `
    (Get-Command Invoke-CpProfile -ErrorAction SilentlyContinue).CommandType

$freshInstall = Join-Path $selfDir 'test\fresh-install.ps1'
Check 'fresh PowerShell smoke exists' $true `
    (Test-Path -LiteralPath $freshInstall -PathType Leaf)
if (Test-Path -LiteralPath $freshInstall -PathType Leaf) {
    $parseTokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $freshInstall, [ref]$parseTokens, [ref]$parseErrors
    )
    Check 'fresh PowerShell smoke parses' 0 $parseErrors.Count
}
$package = Get-Content -Raw -LiteralPath (Join-Path $selfDir 'package.json') | ConvertFrom-Json
Check 'fresh PowerShell npm script is wired' `
    'powershell -ExecutionPolicy Bypass -File test/fresh-install.ps1' `
    $package.scripts.'test:fresh:windows'

Remove-Module agent-profile -Force
Import-Module (Join-Path $selfDir 'claude-profile.psm1') -Force
Check 'legacy module exports claude' 'Function' `
    (Get-Command claude -ErrorAction SilentlyContinue).CommandType
Check 'legacy module exports agent-profile' 'Alias' `
    (Get-Command agent-profile -ErrorAction SilentlyContinue).CommandType
Remove-Module claude-profile -Force
Import-Module (Join-Path $selfDir 'agent-profile.psm1') -Force
$mod = Get-Module agent-profile

# --- scratch -----------------------------------------------------------------

$root      = Join-Path ([IO.Path]::GetTempPath()) ("cp-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$store     = Join-Path $root 'store'
$fakeHome  = Join-Path $root 'home'
$work      = Join-Path $root 'work'
$nested    = Join-Path $work 'a\b\c'

New-Item -ItemType Directory -Force -Path (Join-Path $store 'profiles\work') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $store 'profiles\finance') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $store 'profiles\pinned') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null
New-Item -ItemType Directory -Force -Path $nested | Out-Null

$realHome = $env:HOME
$startDir = (Get-Location).Path

# PowerShell's $HOME is read-only, which is the other reason Get-CpBaseDir reads
# $env:HOME first: it is the only one of the two a test -- or a user -- can point
# somewhere else.
$env:HOME = $fakeHome
$env:CLAUDE_PROFILES_DIR = $store
$env:CLAUDE_PROFILE = $null

$env:CLAUDE_PROFILES_DIR = $null
Check 'store: defaults under HOME' (Join-Path $fakeHome '.agent-profiles') (& $mod { Get-CpStore })
$env:CLAUDE_PROFILES_DIR = $store
Check 'store: honours override' $store (& $mod { Get-CpStore })

function Utf8NoBom { param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    # --- pure helpers --------------------------------------------------------

    Check 'posix: drive path'      '/e/Codeshit/x'  (& $mod { ConvertTo-CpPosixPath 'E:\Codeshit\x' })
    Check 'posix: forward slashes' '/e/Codeshit/x'  (& $mod { ConvertTo-CpPosixPath 'E:/Codeshit/x' })
    Check 'posix: lowercases drive' '/c/Users'      (& $mod { ConvertTo-CpPosixPath 'C:\Users' })
    Check 'posix: bare drive'      '/e'             (& $mod { ConvertTo-CpPosixPath 'E:' })
    Check 'posix: relative left alone' 'a/b'        (& $mod { ConvertTo-CpPosixPath 'a\b' })

    # Mirrors _cp_valid_name. The "." case is the one with teeth: without it,
    # <store>/profiles/. is a real directory and an empty name would validate.
    Check 'name: ordinary'   $true  (& $mod { Test-CpValidName 'dev' })
    Check 'name: empty'      $false (& $mod { Test-CpValidName '' })
    Check 'name: dot'        $false (& $mod { Test-CpValidName '.' })
    Check 'name: dotdot'     $false (& $mod { Test-CpValidName '..' })
    Check 'name: star'       $false (& $mod { Test-CpValidName 'de*v' })
    Check 'name: leading -'  $false (& $mod { Test-CpValidName '-dev' })
    Check 'name: whitespace' $false (& $mod { Test-CpValidName 'de v' })

    # --- name parsing --------------------------------------------------------

    $nameFile = Join-Path $root 'name.txt'

    Utf8NoBom $nameFile "work`n"
    Check 'read: plain' 'work' (& $mod { Read-CpName $args[0] } $nameFile)

    Utf8NoBom $nameFile "# a comment`n  wo rk  # trailing`n"
    Check 'read: comments and inner whitespace' 'work' (& $mod { Read-CpName $args[0] } $nameFile)

    Utf8NoBom $nameFile "`n`n   `nfinance`n"
    Check 'read: skips blank lines' 'finance' (& $mod { Read-CpName $args[0] } $nameFile)

    # The regression that started all this: a file written by `>` in Windows
    # PowerShell 5.1 is UTF-16LE with a BOM.
    [IO.File]::WriteAllText($nameFile, "work`n", [Text.Encoding]::Unicode)
    Check 'read: UTF-16LE BOM' 'work' (& $mod { Read-CpName $args[0] } $nameFile)

    [IO.File]::WriteAllText($nameFile, "work`n", (New-Object System.Text.UTF8Encoding($true)))
    Check 'read: UTF-8 BOM' 'work' (& $mod { Read-CpName $args[0] } $nameFile)

    Check 'read: missing file' '' (& $mod { Read-CpName $args[0] } (Join-Path $root 'nope.txt'))

    $codexDir = Join-Path $fakeHome '.codex'
    $codexConfig = Join-Path $codexDir 'config.toml'
    $defaultCodex = Join-Path $store 'codex-default.config.toml'
    $workCodex = Join-Path $store 'profiles\work\codex.config.toml'
    $financeCodex = Join-Path $store 'profiles\finance\codex.config.toml'
    New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
    Utf8NoBom $codexConfig 'model = "default"'
    Utf8NoBom $workCodex 'model = "work"'
    Utf8NoBom $financeCodex 'model = "finance"'

    & $mod { Set-CpActiveProfile 'work' }
    Check 'codex: activates profile settings' 'model = "work"' ([IO.File]::ReadAllText($codexConfig).Trim())
    Check 'codex: preserves default settings' 'model = "default"' ([IO.File]::ReadAllText($defaultCodex).Trim())
    Check 'codex: live config is a real file' $false ((Get-Item -LiteralPath $codexConfig).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))

    Utf8NoBom $codexConfig 'model = "edited"'
    & $mod { Set-CpActiveProfile 'finance' }
    Check 'codex: snapshots outgoing profile' 'model = "edited"' ([IO.File]::ReadAllText($workCodex).Trim())
    Check 'codex: switches to next profile' 'model = "finance"' ([IO.File]::ReadAllText($codexConfig).Trim())

    & $mod { Set-CpDefaultProfile }
    Check 'codex: restores default settings' 'model = "default"' ([IO.File]::ReadAllText($codexConfig).Trim())
    Check 'codex: default clears active marker' $false (Test-Path -LiteralPath (Join-Path $store 'active'))

    Remove-Item -LiteralPath $financeCodex -Force
    & $mod { Set-CpActiveProfile 'finance' }
    Check 'codex: seeds missing profile settings' 'model = "default"' ([IO.File]::ReadAllText($financeCodex).Trim())
    & $mod { Set-CpDefaultProfile }

    # --- resolution precedence -----------------------------------------------

    Set-Location $work

    Check 'resolve: nothing set falls back to base' `
        (Join-Path $fakeHome '.claude') (& $mod { Resolve-CpConfigDir })

    Utf8NoBom (Join-Path $store 'active') "work`n"
    Check 'resolve: active file' `
        (Join-Path $store 'profiles\work') (& $mod { Resolve-CpConfigDir })
    Check 'resolve: source is active' 'active' (& $mod { (Get-CpSelected).Source })

    Utf8NoBom (Join-Path $work '.claude-profile') "pinned`n"
    Check 'resolve: pin beats active' `
        (Join-Path $store 'profiles\pinned') (& $mod { Resolve-CpConfigDir })

    Set-Location $nested
    Check 'resolve: pin found walking up' `
        (Join-Path $store 'profiles\pinned') (& $mod { Resolve-CpConfigDir })

    $env:CLAUDE_PROFILE = 'finance'
    Check 'resolve: env beats pin' `
        (Join-Path $store 'profiles\finance') (& $mod { Resolve-CpConfigDir })
    Check 'resolve: source is env' 'env' (& $mod { (Get-CpSelected).Source })

    # Unknown name warns and falls back rather than inventing a directory.
    $env:CLAUDE_PROFILE = 'ghost'
    Check 'resolve: unknown profile falls back to base' `
        (Join-Path $fakeHome '.claude') (& $mod { Resolve-CpConfigDir } 2>$null)
    $env:CLAUDE_PROFILE = $null

    # --- drift guard: PowerShell must agree with lib/resolve.sh ---------------

    $bash = & $mod { Get-CpBash }
    if (-not $bash) {
        Write-Host "SKIP drift guard: no Git Bash found"
    } else {
        $shPath    = & $mod { ConvertTo-CpPosixPath $args[0] } (Join-Path $selfDir 'agent-profile.sh')
        $storeSh   = & $mod { ConvertTo-CpPosixPath $args[0] } $store
        $homeSh    = & $mod { ConvertTo-CpPosixPath $args[0] } $fakeHome

        # Sourcing rather than executing: $0 is "bash" under -c, so the script
        # takes its sourced branch and _cp_resolve becomes callable directly.
        $probe = ". '$shPath' >/dev/null 2>&1; _cp_resolve"

        $cases = @(
            @{ Name = 'active';  Env = $null;     Dir = $root   },
            @{ Name = 'pin';     Env = $null;     Dir = $nested },
            @{ Name = 'env';     Env = 'finance'; Dir = $nested },
            @{ Name = 'unknown'; Env = 'ghost';   Dir = $nested }
        )

        foreach ($case in $cases) {
            Set-Location $case.Dir
            $env:CLAUDE_PROFILE = $case.Env

            $ps = & $mod { Resolve-CpConfigDir } 2>$null
            $psPosix = & $mod { ConvertTo-CpPosixPath $args[0] } $ps

            $oldHome  = $env:HOME
            $oldStore = $env:CLAUDE_PROFILES_DIR
            try {
                $env:HOME = $homeSh
                $env:CLAUDE_PROFILES_DIR = $storeSh
                $sh = (& $bash -c $probe) | Select-Object -Last 1
            } finally {
                $env:HOME = $oldHome
                $env:CLAUDE_PROFILES_DIR = $oldStore
            }

            Check ("drift: " + $case.Name) $psPosix "$sh".Trim()
        }
        $env:CLAUDE_PROFILE = $null
    }
}
finally {
    Set-Location $startDir
    $env:HOME = $realHome
    $env:CLAUDE_PROFILES_DIR = $null
    $env:CLAUDE_PROFILE = $null
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "passed: $script:Pass   failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
