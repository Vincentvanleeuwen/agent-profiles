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
INSTALL_DIR=${CLAUDE_PROFILE_INSTALL_DIR:-$HOME/.claude-profile}
BIN_DIR="$INSTALL_DIR/bin"
LINK_DIR=${CP_LINK_DIR:-$HOME/.local/bin}
ZSHENV=${CP_ZSHENV:-$HOME/.zshenv}
TARGET="$INSTALL_DIR/claude-profile.sh"
LINE=". \"$TARGET\""
ZSHENV_MARK="# claude-profile PATH — added by install.sh"

say() { printf '%s\n' "$1"; }
die() { printf 'install: %s\n' "$1" >&2; exit 1; }

# INSTALL_DIR feeds rm -rf in copy_code; refuse before it runs if it canonicalises
# to $HOME, an ancestor of $HOME, or /. String checks alone miss ///, $HOME/.,
# relative paths and symlinks, so resolve with pwd -P and compare once.
if [ -d "$INSTALL_DIR" ]; then
    _id=$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P) || die "cannot resolve $INSTALL_DIR"
else
    _idp=$(cd "$(dirname "$INSTALL_DIR")" 2>/dev/null && pwd -P) \
        || die "cannot resolve the parent of $INSTALL_DIR"
    _id="${_idp%/}/$(basename "$INSTALL_DIR")"
fi
_home=$(cd "$HOME" 2>/dev/null && pwd -P) || die "cannot resolve \$HOME"
case "$_id" in /) die "CLAUDE_PROFILE_INSTALL_DIR resolves to /" ;; esac
[ "$_id" = "$_home" ] && die "CLAUDE_PROFILE_INSTALL_DIR is \$HOME ($HOME)"
case "$_home" in
    "$_id"/*) die "CLAUDE_PROFILE_INSTALL_DIR ($INSTALL_DIR) is an ancestor of \$HOME" ;;
esac
unset _id _idp _home

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --rc <path>        rc file to edit, skipping detection
  --shell bash|zsh   which shell's rc to edit, skipping detection
  --no-shim          skip installing the claude shim (bin/claude)
  --no-migrate       skip migrating a store found inside this clone
  --from-npm         skip the fresh-shell check; npm has no terminal to check
  --uninstall        reverse the install; your profile store is left alone
  -h, --help         this

With no options it copies the code to $INSTALL_DIR, links claude-profile onto
PATH, adds the source line to your shell rc, and checks that a fresh shell
picks it up.
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
no_shim=""
no_migrate=""
from_npm=""
uninstall=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rc)         [ $# -ge 2 ] || die "--rc needs a path";      rc="$2";         shift 2 ;;
        --shell)      [ $# -ge 2 ] || die "--shell needs a name";   want_shell="$2"; shift 2 ;;
        --no-shim)    no_shim=1;    shift ;;
        --no-migrate) no_migrate=1; shift ;;
        --from-npm)   from_npm=1;   shift ;;
        --uninstall)  uninstall=1;  shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument $1 (try --help)" ;;
    esac
done

[ -f "$SELF_DIR/claude-profile.sh" ] || die "cannot find $SELF_DIR/claude-profile.sh"
[ -d "$SELF_DIR/lib" ] || die "cannot find $SELF_DIR/lib — is the clone complete?"
[ -d "$SELF_DIR/bin" ] || die "cannot find $SELF_DIR/bin — is the clone complete?"

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

# Drop lines matching an extended-regex pattern, leaving the rest of the file
# byte-for-byte. No sed -i: it is not POSIX.
drop_lines() {
    _f="$1"
    _pat="$2"
    [ -f "$_f" ] || return 0
    _t="$_f.cp-tmp.$$"
    grep -vE "$_pat" "$_f" > "$_t"
    _gs=$?
    # grep exits 1 when the pattern matched every line, leaving the file
    # empty — that's normal here, not a failure. Anything past 1 is a real error.
    [ "$_gs" -le 1 ] || { rm -f "$_t"; die "could not rewrite $_f"; }
    mv "$_t" "$_f" || { rm -f "$_t"; die "could not rewrite $_f"; }
}

# Drops the PATH block add_zshenv_path wrote: the marker plus the two lines
# after it. Anchored on the marker, not on BIN_DIR, so a CLAUDE_PROFILE_INSTALL_DIR
# without "claude-profile" in its name still gets fully reversed.
drop_zshenv_block() {
    _f="$1"
    [ -f "$_f" ] || return 0
    _t="$_f.cp-tmp.$$"
    # add_zshenv_path always writes a blank separator line right before the
    # marker, so drop that too — hold each line back by one print so we know
    # whether it turned out to be that separator before deciding to print it.
    awk -v mark="$ZSHENV_MARK" '
        skip > 0    { skip--; next }
        $0 == mark  { skip = 2; have = 0; next }
        have        { print buf }
        { buf = $0; have = 1 }
        END { if (have) print buf }
    ' "$_f" > "$_t" || { rm -f "$_t"; die "could not rewrite $_f"; }
    mv "$_t" "$_f" || { rm -f "$_t"; die "could not rewrite $_f"; }
}

# rm -rf "$INSTALL_DIR" needs no extra guard: the canonicalising check at the
# top of this file already refused /, $HOME and its ancestors before any flag ran.
if [ -n "$uninstall" ]; then
    drop_lines "$rc" '^[[:space:]]*(\.|source)[[:space:]].*claude-profile\.sh'
    drop_lines "$rc" '^# claude-profile — added by install.sh$'
    drop_zshenv_block "$ZSHENV"
    # Only remove the symlink if it is actually ours: a foreign file or link
    # at the same path is the user's, not something uninstall gets to touch.
    case "$(readlink "$LINK_DIR/claude-profile" 2>/dev/null)" in
        "$BIN_DIR"/*) rm -f "$LINK_DIR/claude-profile" ;;
        *) [ -e "$LINK_DIR/claude-profile" ] && say "left $LINK_DIR/claude-profile alone: not ours" ;;
    esac
    rm -rf "$INSTALL_DIR"
    say "removed $INSTALL_DIR, the PATH line and the rc line"
    say ""
    say "Your profiles were not touched:"
    say ""
    say "    ${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
    exit 0
fi

copy_code() {
    [ "$SELF_DIR" = "$INSTALL_DIR" ] && return 0
    mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR; nothing was installed"
    for _item in claude-profile.sh lib bin claude-profile.psm1; do
        [ -e "$SELF_DIR/$_item" ] || continue
        rm -rf "${INSTALL_DIR:?}/$_item"
        # -R, not -r: -R is the POSIX spelling and it copies symlinks as
        # symlinks, which is what bin/claude-profile is.
        cp -R "$SELF_DIR/$_item" "$INSTALL_DIR/$_item" \
            || die "could not copy $_item into $INSTALL_DIR; $INSTALL_DIR exists but the copy is incomplete"
    done
    # npm strips symlinks from published tarballs, so a package install can
    # arrive without this one; a git clone already has it via the cp -R above.
    # Stays a symlink, not a wrapper: link_bin points ~/.local/bin/claude-profile here,
    # so a dirname "$0" wrapper would resolve its sibling against the wrong directory.
    [ -e "$BIN_DIR/claude-profile" ] || ln -s ../claude-profile.sh "$BIN_DIR/claude-profile"
    [ -n "$no_shim" ] && rm -f "$BIN_DIR/claude"
    say "installed the code to $INSTALL_DIR"
}

# A pre-stable-install clone can carry its own store at $SELF_DIR/profiles.
# --no-migrate exists so a live session's own $SELF_DIR/profiles is never moved by accident.
migrate_clone_store() {
    [ -n "$no_migrate" ] && return 0
    [ "$SELF_DIR" = "$INSTALL_DIR" ] && return 0
    [ -d "$SELF_DIR/profiles" ] || return 0
    say "found a store in $SELF_DIR, moving it out of the clone"
    "$TARGET" --migrate-store "$SELF_DIR" \
        || die "the code is installed but the store was not migrated. Run
     '\"$TARGET\" --migrate-store \"$SELF_DIR\"' by hand to see the error."
}

link_bin() {
    mkdir -p "$LINK_DIR" || die "the code is installed to $INSTALL_DIR, but could not create $LINK_DIR"
    ln -sf "$BIN_DIR/claude-profile" "$LINK_DIR/claude-profile" \
        || die "the code is installed to $INSTALL_DIR, but could not link $LINK_DIR/claude-profile"
    say "linked $LINK_DIR/claude-profile"
}

# .zshenv, not .zshrc: it is the only startup file a non-interactive zsh
# reads, which is the whole reason the claude shim needs it on PATH here.
add_zshenv_path() {
    [ -n "$no_shim" ] && return 0
    [ "$want_shell" = zsh ] || return 0
    if [ -f "$ZSHENV" ] && grep -qF "$BIN_DIR" "$ZSHENV"; then
        say "PATH line already in $ZSHENV"
        return 0
    fi
    {
        printf '\n%s\n' "$ZSHENV_MARK"
        printf 'case ":$PATH:" in *":%s:"*) ;; *) PATH="%s:$PATH" ;; esac\n' \
               "$BIN_DIR" "$BIN_DIR"
        printf 'export PATH\n'
    } >> "$ZSHENV" || die "the code is installed and linked onto PATH, but could not append to $ZSHENV"
    say "added the PATH line to $ZSHENV"
}

copy_code
migrate_clone_store
link_bin
add_zshenv_path

# Already mentioned: either it's our line already, or it points at a clone
# and needs repointing at the tree copy_code just installed — never refuse.
existing=$(grep -n 'claude-profile\.sh' "$rc" 2>/dev/null || true)
if [ -n "$existing" ]; then
    if grep -qxF "$LINE" "$rc"; then
        say "already installed in $rc"
    else
        # Collapse any duplicates to one line while we are here.
        _t="$rc.cp-tmp.$$"
        awk -v line="$LINE" '
            /claude-profile\.sh/ && /^[[:space:]]*(\.|source)[[:space:]]/ {
                if (!done) { print line; done = 1 }
                next
            }
            { print }
        ' "$rc" > "$_t" || { rm -f "$_t"; die "the code is installed and both PATH surfaces are set up, but could not rewrite $rc"; }
        if ! grep -qxF "$LINE" "$_t"; then
            rm -f "$_t"
            die "the code is installed and both PATH surfaces are set up, but $rc
     mentions claude-profile.sh in a form this script does not recognise as a
     source line. Fix it by hand, then run this again:

$(printf '%s\n' "$existing" | sed 's/^/         /')"
        fi
        mv "$_t" "$rc" || { rm -f "$_t"; die "the code is installed and both PATH surfaces are set up, but could not rewrite $rc"; }
        say "pointed the source line in $rc at $TARGET"
    fi
else
    {
        printf '\n# claude-profile — added by install.sh\n'
        printf '%s\n' "$LINE"
    } >> "$rc" || die "the code is installed and both PATH surfaces are set up, but could not append to $rc"
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
if [ -n "$from_npm" ]; then
    say "skipping the fresh-shell check: npm runs this without a terminal"
else
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
fi

if [ -n "$from_npm" ]; then
    say ""
    say "If you are moving off a git clone, move its store too:"
    say ""
    say "    claude-profile --migrate-store <path-to-old-clone>"
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
