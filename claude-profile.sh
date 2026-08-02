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
