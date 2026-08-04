#!/bin/sh
# Add the `source` line for claude-profile.sh to your shell rc, then prove it
# worked. Safe to re-run: an install that is already correct is a no-op.
#
# The failure this exists to prevent: without that line there is no `claude`
# shell function, so `claude profile --create dev` reaches the real Claude Code
# binary, which knows nothing about --create and answers with a bare
# "error: unknown option '--create'" — which says nothing about the actual
# problem, that the tool was never installed.
#
# Usage: ./install.sh [--rc <path>] [--shell bash|zsh]

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="$SELF_DIR/claude-profile.sh"
LINE=". \"$TARGET\""

say() { printf '%s\n' "$1"; }
die() { printf 'install: %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --rc <path>        rc file to edit, skipping detection
  --shell bash|zsh   which shell's rc to edit, skipping detection
  -h, --help         this

With no options it works out which rc file your shell reads, adds the source
line, and checks that a fresh shell picks it up.
EOF
}

# A stop that ends with the manual instructions, since every caller needs to
# say the same thing afterwards.
manual() {
    printf 'install: %s\n' "$1" >&2
    printf '\nNothing was changed. Either re-run with --rc <path> or --shell <name>,\n' >&2
    printf 'or add this line by hand to the file your shell reads at startup:\n\n    %s\n\n' "$LINE" >&2
    exit 1
}

rc=""
want_shell=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rc)      [ $# -ge 2 ] || die "--rc needs a path";      rc="$2";         shift 2 ;;
        --shell)   [ $# -ge 2 ] || die "--shell needs a name";   want_shell="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown argument $1 (try --help)" ;;
    esac
done

[ -f "$TARGET" ]       || die "cannot find $TARGET"
[ -d "$SELF_DIR/lib" ] || die "cannot find $SELF_DIR/lib — is the clone complete?"

# CP_RC stays supported: it is how the test suite keeps this off a real rc.
[ -n "$rc" ] || rc=${CP_RC:-}

# An rc named on the command line can point anywhere, including at a file no
# shell would ever read. That limits what the verify step is allowed to claim,
# so remember how we arrived at it.
rc_explicit=""
[ -n "$rc" ] && rc_explicit=1

# Set when interactive shells work but login shells do not. Not fatal — the
# install is real, just half-reachable — but it must not exit 0.
login_gap=""

case "$want_shell" in
    ''|bash|zsh) ;;
    *) die "--shell takes bash or zsh, not $want_shell" ;;
esac

# Reduce a path like /bin/bash.exe to "bash", and only for shells we handle.
# The .exe matters on Git Bash, where $SHELL is /bin/bash.exe.
shell_name() {
    _s=$(basename "${1:-}" 2>/dev/null)
    _s=${_s%.exe}
    case "${_s#-}" in bash|zsh) printf '%s' "${_s#-}" ;; esac
}

# Which shell to install for.
#
# $SHELL is the login shell from the password database, which is the right
# answer on a normal desktop and useless in a container, WSL image, cron job,
# or anything reached through `su` — there it is commonly /bin/sh or empty
# while you are quite clearly typing into bash. So it is one source, not the
# source: fall back to the process that invoked this script, then to whichever
# rc files exist.
if [ -z "$want_shell" ]; then
    want_shell=$(shell_name "${SHELL:-}")
fi
if [ -z "$want_shell" ]; then
    # `bash ./install.sh` and an interactive bash both answer bash here. A
    # leading "-" marks a login shell and is not part of the name. Git Bash
    # ships a cut-down ps without -o, hence the redirect and the next fallback.
    parent=$(ps -o comm= -p "$PPID" 2>/dev/null | tr -d ' ')
    want_shell=$(shell_name "$parent")
fi

# Which file that shell reads at startup. The split matters: a login shell
# reads .bash_profile and never .bashrc unless .bash_profile says so, and
# macOS Terminal and Git Bash both start login shells where Linux terminals
# start non-login ones.
bash_rc() {
    case "$(uname -s 2>/dev/null)" in
        Darwin)
            if [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"
            else printf '%s' "$HOME/.bashrc"; fi ;;
        *)
            if   [ -f "$HOME/.bashrc" ];       then printf '%s' "$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"
            else printf '%s' "$HOME/.bashrc"; fi ;;
    esac
}

# The file a login bash reads: the first of these that exists, with no
# fallback to the others and none at all to .bashrc.
login_entry() {
    for _c in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -f "$_c" ]; then printf '%s' "$_c"; return 0; fi
    done
    return 1
}

# Make sure a login bash reaches ~/.bashrc, where the source line lives.
#
# This is the gap that makes an install look fine and do nothing: bash reads
# .bashrc for interactive non-login shells only, so `bash -l`, `su -` and most
# container entrypoints never see it. zsh needs no equivalent — it reads
# .zshrc for every interactive shell, login or not.
link_login_shell() {
    if _le=$(login_entry); then
        grep -q '\.bashrc' "$_le" && return 0
        printf 'install: %s is what your login shells read, and it does not\n' "$_le" >&2
        printf 'source ~/.bashrc, so `bash -l`, `su -` and most container shells\n' >&2
        printf 'will not pick up the wrapper. Add this to %s:\n\n' "$_le" >&2
        printf '    if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n\n' >&2
        return 1
    fi
    # Nothing in the login chain at all — a fresh account or a bare container
    # image. Creating .bash_profile is safe precisely because none of the three
    # exist; doing it while ~/.profile was present would shadow that file and
    # silently drop whatever it sets up.
    {
        printf '# added by claude-profile install.sh\n'
        printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n'
    } > "$HOME/.bash_profile" || die "could not create $HOME/.bash_profile"
    say "created $HOME/.bash_profile so login shells read .bashrc"
}

# Last resort, when nothing identified the shell: go by what is on disk. One
# candidate is an answer; two is a coin flip, and this does not flip coins.
guess_rc() {
    _z=""; _b=""
    [ -f "$HOME/.zshrc" ] && _z="$HOME/.zshrc"
    if   [ -f "$HOME/.bashrc" ];       then _b="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then _b="$HOME/.bash_profile"; fi
    if [ -n "$_z" ] && [ -z "$_b" ]; then printf '%s' "$_z"; return 0; fi
    if [ -n "$_b" ] && [ -z "$_z" ]; then printf '%s' "$_b"; return 0; fi
    [ -n "$_z" ] && [ -n "$_b" ] && return 2
    return 1
}

if [ -z "$rc" ]; then
    case "$want_shell" in
        zsh)  rc="$HOME/.zshrc" ;;
        bash) rc=$(bash_rc) ;;
        *)
            rc=$(guess_rc) || case $? in
                2) manual "both ~/.zshrc and a bash rc exist and \$SHELL is ${SHELL:-unset}, so there is no way to tell which one you use" ;;
                *) manual "could not tell which shell you use (\$SHELL is ${SHELL:-unset}) and found no ~/.zshrc, ~/.bashrc or ~/.bash_profile" ;;
            esac
            ;;
    esac
fi

# guess_rc can settle on a file without ever naming a shell, but the verify
# step needs one to start. The rc file implies it.
if [ -z "$want_shell" ]; then
    case "$rc" in
        */.zshrc)                   want_shell=zsh ;;
        */.bashrc|*/.bash_profile)  want_shell=bash ;;
    esac
fi

# A named shell with no rc file yet is a fresh account, not an ambiguity —
# create it. Anything genuinely ambiguous stopped above.
if [ ! -f "$rc" ]; then
    : > "$rc" || die "could not create $rc"
    say "created $rc"
fi

# Already mentioned? Then either it is our line and there is nothing to do, or
# it points somewhere else and this is not a decision to make on someone's
# behalf — a second clone, a moved directory, a hand-written variant.
existing=$(grep -n 'claude-profile\.sh' "$rc" 2>/dev/null || true)
if [ -n "$existing" ]; then
    if grep -qxF "$LINE" "$rc"; then
        say "already installed in $rc"
    else
        printf 'install: %s already refers to claude-profile.sh, but not the\n' "$rc" >&2
        printf 'way this script would write it:\n\n' >&2
        printf '%s\n' "$existing" | sed 's/^/    /' >&2
        printf '\nExpected:\n\n    %s\n\n' "$LINE" >&2
        printf 'Remove or fix that line, then run this again. Nothing was changed.\n' >&2
        exit 1
    fi
else
    {
        printf '\n# claude-profile — added by install.sh\n'
        printf '%s\n' "$LINE"
    } >> "$rc" || die "could not append to $rc"
    say "added the source line to $rc"
fi

# The source line only pays off in a shell that reads the file it went into.
# Only for a ~/.bashrc we chose ourselves: an explicit --rc is the caller's
# arrangement, and .zshrc needs nothing.
if [ -z "$rc_explicit" ] && [ "$rc" = "$HOME/.bashrc" ]; then
    link_login_shell || login_gap=1
fi

# Prove it. A line in a file is not an install; the test is whether the shell
# you type into ends up with `claude` as a function.
#
# The shell that does the checking has to be the one whose rc was edited —
# falling back to another would read a different startup file and pass no
# matter what was written. Only the explicit-rc case can be checked with any
# shell, because there it is a plain source of a named file.
verify_bin=""
if [ -n "$rc_explicit" ]; then
    for cand in "$want_shell" bash zsh; do
        [ -n "$cand" ] || continue
        if command -v "$cand" >/dev/null 2>&1; then
            verify_bin=$(command -v "$cand")
            break
        fi
    done
elif [ -n "$want_shell" ] && command -v "$want_shell" >/dev/null 2>&1; then
    verify_bin=$(command -v "$want_shell")
fi

if [ -z "$verify_bin" ]; then
    say "note: no ${want_shell:-bash or zsh} on PATH, skipping the load check"
elif [ -n "$rc_explicit" ]; then
    # An --rc can point anywhere, and no interactive shell would read an
    # arbitrary path, so the honest claim is narrower: sourcing that file
    # defines the wrapper. Whether anything reads it is the caller's business.
    if "$verify_bin" -c '. "$1" || exit 1
case $(command -v claude) in
    claude) exit 0 ;;
    *) exit 1 ;;
esac' _ "$rc" >/dev/null 2>&1; then
        say "verified: sourcing $rc defines the claude wrapper"
        say "note: --rc given, so whether a shell reads that file was not checked"
    else
        die "wrote $rc, but sourcing it does not define the claude wrapper.
     Run '. \"$TARGET\"' by hand to see the error."
    fi
else
    # The real check: start the shell the way a terminal does and look at what
    # `claude` resolves to. This runs the actual rc, side effects and all —
    # that is the point, and every new shell already does it.
    #
    # `command -v` is the probe because its output separates every case that
    # matters: a bare name for a function, an `alias ...=` line for an alias,
    # and a path for a binary. Aliases exist only in interactive shells, which
    # is the second reason this is not a `-c` away.
    seen=$("$verify_bin" -i -c 'command -v claude' 2>/dev/null)
    case "$seen" in
        claude) say "verified: a new interactive $want_shell defines the wrapper" ;;
        alias*)
            die "an alias in $rc shadows the wrapper:

         $seen

     Alias expansion happens before function lookup, so the alias always
     wins. Remove it, then run this again." ;;
        *)
            die "wrote $rc, but a new interactive $want_shell does not define the
     claude wrapper. Run '. \"$TARGET\"' by hand to see the error." ;;
    esac

    # Login shells read a different file, and that difference is the whole bug
    # this check exists for: a source line in .bashrc that `bash -l` never
    # reaches, on an install that otherwise looks perfect.
    if [ "$("$verify_bin" -l -i -c 'command -v claude' 2>/dev/null)" = claude ]; then
        say "verified: login shells pick it up too"
    else
        login_gap=1
        printf 'install: interactive shells pick up the wrapper but a login shell\n' >&2
        printf 'does not, so `bash -l`, `su -` and most container entrypoints will\n' >&2
        printf 'silently use ~/.claude instead of the active profile.\n' >&2
    fi
fi

say ""
say "Start a new shell, or run this in the current one:"
say ""
say "    $LINE"
say ""
say "Then:"
say ""
say "    claude profile --create development"
say "    claude profile development"

# Git Bash only shadows `claude` inside Git Bash. PowerShell and cmd run
# claude.exe directly and never see a POSIX shell function, so silently getting
# the base ~/.claude there is worth one sentence now. PowerShell has its own
# installer; cmd cannot be helped.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        say ""
        say "Note: this only applies to this shell. PowerShell needs its own install,"
        say "which defines the same wrapper as a PowerShell function:"
        say ""
        say "    powershell -File \"$SELF_DIR/install.ps1\""
        say ""
        say "Both share one store. cmd.exe cannot be supported at all — from there,"
        say "use 'claude profile <name> -- <args>' from this shell instead."
        ;;
esac

# A half-reachable install still installed something, so the instructions above
# are worth printing — but it is not a success and must not report as one.
[ -z "$login_gap" ] || exit 1
exit 0
