# Commands that read or set the active profile, and launching claude.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_cmd_create() {
    _n="$1"
    _cp_free "$_n" || return 1
    _from=$(_cp_resolve) || return 1
    mkdir -p "$(_cp_store)/profiles"
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to build "%s"\n' "$_n" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'created %s <- %s\n' "$_n" "$_from"
}

_cp_cmd_set() {
    _n="$1"
    _cp_need "$_n" || return 1
    if ! printf '%s\n' "$_n" > "$(_cp_store)/active"; then
        printf 'claude-profile: could not write %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: %s\n' "$_n"
}

_cp_cmd_default() {
    rm -f "$(_cp_store)/active" 2>/dev/null
    if [ -e "$(_cp_store)/active" ]; then
        printf 'claude-profile: could not remove %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: none (using ~/.claude)\n'
}

_cp_cmd_status() {
    _sel=$(_cp_selected)
    # $(...) is a subshell: _CP_SRC set inside _cp_selected above never reached
    # here. Re-run it directly (stdout discarded, already captured in _sel) so
    # _CP_SRC lands in this shell.
    _cp_selected >/dev/null
    if [ -z "$_sel" ]; then
        printf 'active: none (using ~/.claude)\n'
    else
        printf 'active: %s  (%s)\n' "$_sel" "$_CP_SRC"
    fi
    printf 'store: %s\n' "$(_cp_store)"
    printf 'profiles:\n'
    if [ -d "$(_cp_store)/profiles" ]; then
        [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch
        for _p in "$(_cp_store)"/profiles/*; do
            [ -d "$_p" ] || continue
            printf '  %s\n' "${_p##*/}"
        done
    fi
}

_CP_RUNNER=${_CP_RUNNER:-}

# A shim named claude sits ahead of the real binary on PATH once installed, so
# `command claude` would resolve back to us and loop. Walk PATH by hand and skip
# anything that resolves inside the install dir.
_cp_real_claude() {
    _rc_skip=$(_cp_install_dir)
    _rc_ifs=$IFS
    IFS=:
    # shellcheck disable=SC2086 # splitting PATH on colons is the point
    set -- $PATH
    IFS=$_rc_ifs
    for _rc_d in "$@"; do
        [ -n "$_rc_d" ] || _rc_d=.
        [ -f "$_rc_d/claude" ] && [ -x "$_rc_d/claude" ] || continue
        case "$(_cp_deref "$_rc_d/claude")" in
            "$_rc_skip"/*) continue ;;
        esac
        printf '%s' "$_rc_d/claude"
        return 0
    done
    return 1
}

_cp_run_claude() {
    if [ -n "$_CP_RUNNER" ]; then
        "$_CP_RUNNER" "$@"
    else
        _rc_bin=$(_cp_real_claude) || {
            printf 'claude-profile: no claude binary on PATH\n' >&2
            return 127
        }
        "$_rc_bin" "$@"
    fi
}

# Single choke point for starting a session: pull shared prompt state in,
# run, push back whatever this session accepted.
_cp_launch() {
    _l_dir="$1"; shift
    _cp_sync_prompts "$_l_dir"
    CLAUDE_CONFIG_DIR="$_l_dir" _cp_run_claude "$@"
    _l_rc=$?
    _cp_sync_prompts "$_l_dir"
    return $_l_rc
}

_cp_cmd_run() {
    _n="$1"; shift
    _cp_need "$_n" || return 1
    _cp_launch "$(_cp_dir "$_n")" "$@"
}

