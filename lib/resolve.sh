# Which profile is selected, and where its directory is.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_store() {
    if [ -n "${CLAUDE_PROFILES_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROFILES_DIR"
    else
        printf '%s' "$HOME/.agent-profiles"
    fi
}

_cp_install_dir() {
    printf '%s' "${CLAUDE_PROFILE_INSTALL_DIR:-$HOME/.agent-profile}"
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

# Every `claude` that misses the shell function reads ~/.claude: the raw binary
# further up PATH, another tool spawning it, a session's own shell. That is how
# `claude plugins install` writes enabledPlugins into the base config instead of
# the active profile. Exporting the resolved directory closes all of those at
# once, since Claude Code reads CLAUDE_CONFIG_DIR wherever it is started from.
# Only ever exported for a directory that exists — a stale profile name would
# otherwise point Claude Code at an empty config it then happily creates.
_cp_export_config_dir() {
    _xd=$(_cp_resolve 2>/dev/null) || return 0
    [ -d "$_xd" ] || return 0
    CLAUDE_CONFIG_DIR="$_xd"
    export CLAUDE_CONFIG_DIR
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
