# claude-profile — switch Claude Code between named configuration profiles.
# Source this from ~/.zshrc or ~/.bashrc. POSIX sh; runs under zsh and bash.

# Path of this file when sourced. $BASH_SOURCE is set under bash; the zsh
# fallback ${(%):-%x} is only ever expanded when it is not, so bash never
# parses it as a value.
_CP_SELF="${BASH_SOURCE:-${(%):-%x}}"
_CP_HOME=$(cd "$(dirname "$_CP_SELF")" && pwd)

_cp_store() {
    if [ -n "${CLAUDE_PROFILES_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROFILES_DIR"
    else
        printf '%s' "$_CP_HOME"
    fi
}

_cp_read_name() {
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" 2>/dev/null | grep -m1 .
}

_cp_find_pin() {
    _d="$PWD"
    while : ; do
        if [ -f "$_d/.claude-profile" ]; then
            printf '%s' "$_d/.claude-profile"
            return 0
        fi
        [ "$_d" = "/" ] && return 1
        _d=$(dirname "$_d")
    done
}

# Prints the selected profile name (possibly empty). Sets _CP_SRC.
_cp_selected() {
    if [ -n "${CLAUDE_PROFILE:-}" ]; then
        _CP_SRC="env"
        printf '%s' "$CLAUDE_PROFILE"
        return 0
    fi
    _pin=$(_cp_find_pin) && {
        _name=$(_cp_read_name "$_pin")
        if [ -n "$_name" ]; then
            _CP_SRC="pin:$_pin"
            printf '%s' "$_name"
            return 0
        fi
    }
    if [ -f "$(_cp_store)/active" ]; then
        _name=$(_cp_read_name "$(_cp_store)/active")
        if [ -n "$_name" ]; then
            _CP_SRC="active"
            printf '%s' "$_name"
            return 0
        fi
    fi
    _CP_SRC="none"
    return 0
}

# Prints the config directory to use.
_cp_resolve() {
    _sel=$(_cp_selected)
    if [ -z "$_sel" ]; then
        printf '%s' "$HOME/.claude"
        return 0
    fi
    if [ -d "$(_cp_store)/profiles/$_sel" ]; then
        printf '%s' "$(_cp_store)/profiles/$_sel"
    else
        printf 'claude-profile: unknown profile "%s", using ~/.claude\n' "$_sel" >&2
        printf '%s' "$HOME/.claude"
    fi
}

# Leading and trailing spaces are required: matched with case " $x " in *" $b "*
_CP_SHARED=" plugins projects history.jsonl .credentials.json context-mode \
file-history cache sessions shell-snapshots backups telemetry tasks \
paste-cache debug downloads ide chrome session-env \
.session-stats.json stats-cache.json claude-devtools-notifications.json "
_CP_SKIP=" .DS_Store "

_cp_is_shared() { case "$_CP_SHARED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
_cp_is_skipped(){ case "$_CP_SKIP"   in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Rewrite ~/.claude/ prefixes in a settings.json so a profile uses its own
# hooks, scripts and statusline. Paths outside the config dir are untouched.
_cp_rewrite() {
    _f="$1"; _p="$2"
    [ -f "$_f" ] || return 0
    _t="$_f.tmp.$$"
    sed -e "s#$HOME/\.claude/#$_p/#g" \
        -e "s#\$HOME/\.claude/#$_p/#g" \
        -e "s#~/\.claude/#$_p/#g" \
        "$_f" > "$_t" && mv "$_t" "$_f"
    # ponytail: forking from another profile (not base) leaves that profile's
    # own absolute path in settings.json; _src is set by _cp_build's caller
    # (no `local` in this codebase, so it's already in scope) — rewrite it
    # too so a fork doesn't keep pointing at its parent profile.
    if [ -n "$_src" ]; then
        sed -e "s#$_src/#$_p/#g" "$_f" > "$_t" && mv "$_t" "$_f"
    fi
}

# Populate $2 as a profile built from config dir $1.
_cp_build() {
    _src="$1"; _dest="$2"
    mkdir -p "$_dest"
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_skipped "$_b" && continue
        if _cp_is_shared "$_b"; then
            rm -rf "$_dest/$_b"
            [ -e "$HOME/.claude/$_b" ] && ln -s "$HOME/.claude/$_b" "$_dest/$_b"
        else
            rm -rf "$_dest/$_b"
            cp -R "$_e" "$_dest/$_b"
        fi
    done
    _cp_rewrite "$_dest/settings.json" "$_dest"
}
