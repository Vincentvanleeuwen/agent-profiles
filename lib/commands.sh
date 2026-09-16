# Commands that read or set the active profile, and launching claude.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_codex_config() { printf '%s' "$HOME/.codex/config.toml"; }
_cp_codex_default() { printf '%s' "$(_cp_store)/codex-default.config.toml"; }
_cp_codex_profile() { printf '%s' "$(_cp_dir "$1")/codex.config.toml"; }

_cp_codex_copy() {
    _cc_src="$1"
    _cc_dest="$2"
    _cc_tmp="$_cc_dest.tmp.$$"
    rm -f "$_cc_tmp"
    cp -L "$_cc_src" "$_cc_tmp" || { rm -f "$_cc_tmp"; return 1; }
    mv -f "$_cc_tmp" "$_cc_dest" || { rm -f "$_cc_tmp"; return 1; }
}

_cp_codex_prepare_default() {
    _cd_default=$(_cp_codex_default)
    [ -e "$_cd_default" ] && return 0
    mkdir -p "$(_cp_store)" || return 1
    if [ -f "$(_cp_codex_config)" ]; then
        _cp_codex_copy "$(_cp_codex_config)" "$_cd_default"
    else
        _cd_tmp="$_cd_default.tmp.$$"
        : > "$_cd_tmp" || { rm -f "$_cd_tmp"; return 1; }
        mv -f "$_cd_tmp" "$_cd_default" || { rm -f "$_cd_tmp"; return 1; }
    fi
}

_cp_codex_snapshot() {
    _cs_dest=$(_cp_codex_profile "$1")
    if [ -f "$(_cp_codex_config)" ]; then
        _cp_codex_copy "$(_cp_codex_config)" "$_cs_dest"
    else
        _cp_codex_prepare_default && _cp_codex_copy "$(_cp_codex_default)" "$_cs_dest"
    fi
}

_cp_codex_ensure() {
    _ce_name="$1"
    _ce_profile=$(_cp_codex_profile "$_ce_name")
    [ -e "$_ce_profile" ] && return 0
    _cp_codex_prepare_default && _cp_codex_copy "$(_cp_codex_default)" "$_ce_profile"
}

_cp_codex_link() {
    _cl_target="$1"
    _cl_config=$(_cp_codex_config)
    _cl_tmp="$_cl_config.tmp.$$"
    mkdir -p "$HOME/.codex" || return 1
    rm -f "$_cl_tmp"
    ln -s "$_cl_target" "$_cl_tmp" || return 1
    mv -f "$_cl_tmp" "$_cl_config" || { rm -f "$_cl_tmp"; return 1; }
}

_cp_codex_activate() {
    _ca_name="$1"
    _cp_codex_prepare_default || return 1
    _cp_codex_ensure "$_ca_name" || return 1
    _cp_codex_link "$(_cp_codex_profile "$_ca_name")"
}

_cp_codex_activate_default() {
    _cp_codex_prepare_default && _cp_codex_link "$(_cp_codex_default)"
}

_cp_codex_sync_active() {
    _csa_name=$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)
    if [ -n "$_csa_name" ] && _cp_exists "$_csa_name"; then
        _cp_codex_activate "$_csa_name"
    else
        _cp_codex_activate_default
    fi
}

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
    if ! _cp_codex_snapshot "$_n"; then
        printf 'claude-profile: failed to snapshot Codex config for "%s"\n' "$_n" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'created %s <- %s\n' "$_n" "$_from"
}

_cp_cmd_set() {
    _n="$1"
    _cp_need "$_n" || return 1
    _cp_codex_activate "$_n" || {
        printf 'claude-profile: could not activate Codex config for "%s"\n' "$_n" >&2
        return 1
    }
    if ! printf '%s\n' "$_n" > "$(_cp_store)/active"; then
        _cp_codex_sync_active >/dev/null 2>&1
        printf 'claude-profile: could not write %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    _cp_export_config_dir
    printf 'active profile: %s\n' "$_n"
}

_cp_cmd_default() {
    _cp_codex_activate_default || {
        printf 'claude-profile: could not restore the default Codex config\n' >&2
        return 1
    }
    rm -f "$(_cp_store)/active" 2>/dev/null
    if [ -e "$(_cp_store)/active" ]; then
        _cp_codex_sync_active >/dev/null 2>&1
        printf 'claude-profile: could not remove %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    _cp_export_config_dir
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

# Skips anything inside the install dir so `command claude` cannot loop back into our own shim.
_cp_real_claude() {
    _rc_skip=$(_cp_install_dir)
    # Split PATH on ':' by hand: zsh does not word-split unquoted $PATH, so
    # `set -- $PATH` would hand us the whole string as one element.
    _rc_rest=$PATH
    while [ -n "$_rc_rest" ]; do
        case "$_rc_rest" in
            *:*) _rc_d=${_rc_rest%%:*}; _rc_rest=${_rc_rest#*:} ;;
            *)   _rc_d=$_rc_rest; _rc_rest= ;;
        esac
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
