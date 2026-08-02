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

# _cp_rewrite SETTINGS_FILE PROFILE_DIR [SOURCE_DIR]
# Rewrites ~/.claude/ prefixes to PROFILE_DIR. When SOURCE_DIR is given and is
# not the base config dir, also rewrites SOURCE_DIR/ -> PROFILE_DIR/, which is
# what makes a profile forked from another profile point at itself.
_cp_rewrite() {
    _f="$1"; _p="$2"; _rsrc="${3:-}"
    [ -f "$_f" ] || return 0
    _t="$_f.tmp.$$"
    if ! sed -e "s#$HOME/\.claude/#$_p/#g" \
             -e "s#\$HOME/\.claude/#$_p/#g" \
             -e "s#~/\.claude/#$_p/#g" \
             "$_f" > "$_t"; then
        rm -f "$_t"
        return 1
    fi
    mv "$_t" "$_f" || { rm -f "$_t"; return 1; }
    if [ -n "$_rsrc" ]; then
        if ! sed -e "s#$_rsrc/#$_p/#g" "$_f" > "$_t"; then
            rm -f "$_t"
            return 1
        fi
        mv "$_t" "$_f" || { rm -f "$_t"; return 1; }
    fi
    return 0
}

# Populate $2 as a profile built from config dir $1.
_cp_build() {
    _src="$1"; _dest="$2"
    mkdir -p "$_dest" || return 1
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_skipped "$_b" && continue
        rm -rf "$_dest/$_b" || return 1
        if _cp_is_shared "$_b"; then
            # Explicit if, not `[ -e ] && ln -s`: as the last statement of a
            # branch, a false test would become the function's exit status.
            if [ -e "$HOME/.claude/$_b" ]; then
                ln -s "$HOME/.claude/$_b" "$_dest/$_b" || return 1
            fi
        else
            cp -R "$_e" "$_dest/$_b" || return 1
        fi
    done
    _cp_rewrite "$_dest/settings.json" "$_dest" "$_src" || return 1
    return 0
}

_cp_dir()    { printf '%s' "$(_cp_store)/profiles/$1"; }
_cp_exists() { [ -d "$(_cp_dir "$1")" ]; }
_cp_valid_name() {
    case "$1" in
        ""|.|..|*/*|-*) return 1 ;;
        *) return 0 ;;
    esac
}

_cp_cmd_create() {
    _n="$1"
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    if _cp_exists "$_n"; then
        printf 'claude-profile: profile "%s" already exists\n' "$_n" >&2
        return 1
    fi
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
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
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
    if [ -z "$_sel" ]; then
        printf 'active: none (using ~/.claude)\n'
    else
        printf 'active: %s  (%s)\n' "$_sel" "$_CP_SRC"
    fi
    printf 'profiles:\n'
    if [ -d "$(_cp_store)/profiles" ]; then
        for _p in "$(_cp_store)"/profiles/*; do
            [ -d "$_p" ] || continue
            printf '  %s\n' "${_p##*/}"
        done
    fi
}

_CP_RUNNER=${_CP_RUNNER:-}

_cp_run_claude() {
    if [ -n "$_CP_RUNNER" ]; then
        "$_CP_RUNNER" "$@"
    else
        command claude "$@"
    fi
}

_cp_cmd_run() {
    _n="$1"; shift
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    CLAUDE_CONFIG_DIR="$(_cp_dir "$_n")" _cp_run_claude "$@"
}

_cp_backup() {
    _n="$1"
    _stamp=$(date +%Y%m%d-%H%M%S)
    _dst="$(_cp_store)/.backups/$_n-$_stamp"
    mkdir -p "$(_cp_store)/.backups" || return 1
    mv "$(_cp_dir "$_n")" "$_dst" || return 1
    printf '%s' "$_dst"
}

_cp_cmd_update() {
    _n="$1"
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    _from=$(_cp_resolve)
    if [ "$_from" = "$(_cp_dir "$_n")" ]; then
        printf 'claude-profile: "%s" is the active source; switch away first\n' "$_n" >&2
        return 1
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not updating "%s"\n' "$_n" >&2
        return 1
    fi
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to rebuild "%s"; previous contents at %s\n' "$_n" "$_bk" >&2
        return 1
    fi
    printf 'backed up -> %s\n' "$_bk"
    printf 'updated %s <- %s\n' "$_n" "$_from"
}

_cp_cmd_delete() {
    _n="$1"
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    if [ "$(_cp_selected)" = "$_n" ]; then
        printf 'claude-profile: "%s" is active; run "claude profile default" first\n' "$_n" >&2
        return 1
    fi
    if [ -z "${_CP_YES:-}" ]; then
        printf 'delete profile "%s"? type the name to confirm: ' "$_n"
        read -r _answer
        if [ "$_answer" != "$_n" ]; then
            printf 'cancelled\n'
            return 1
        fi
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not deleting "%s"\n' "$_n" >&2
        return 1
    fi
    printf 'deleted %s (kept at %s)\n' "$_n" "$_bk"
}

_cp_cmd_rename() {
    _o="$1"; _n="$2"
    _cp_exists "$_o" || { printf 'claude-profile: no such profile "%s"\n' "$_o" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! mv "$(_cp_dir "$_o")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: rename failed\n' >&2
        return 1
    fi
    # Third argument is the OLD profile dir: after the mv, settings.json still
    # carries the old profile's paths, and that pass is what retargets them.
    if ! _cp_rewrite "$(_cp_dir "$_n")/settings.json" "$(_cp_dir "$_n")" "$(_cp_dir "$_o")"; then
        printf 'claude-profile: renamed to "%s" but path rewrite failed; fix settings.json paths manually\n' "$_n" >&2
        return 1
    fi
    if [ "$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)" = "$_o" ]; then
        printf '%s\n' "$_n" > "$(_cp_store)/active"
    fi
    printf 'renamed %s -> %s\n' "$_o" "$_n"
}

_cp_cmd_copy() {
    _s="$1"; _n="$2"
    _cp_exists "$_s" || { printf 'claude-profile: no such profile "%s"\n' "$_s" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! _cp_build "$(_cp_dir "$_s")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to copy "%s"\n' "$_s" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'copied %s -> %s\n' "$_s" "$_n"
}

_cp_main() {
    case "${1:-}" in
        "")                 _cp_cmd_status ;;
        default|--reset)    _cp_cmd_default ;;
        --create)           shift; _cp_cmd_create "$@" ;;
        --update)           shift; _cp_cmd_update "$@" ;;
        --delete)           shift; _cp_cmd_delete "$@" ;;
        --rename)           shift; _cp_cmd_rename "$@" ;;
        --copy)             shift; _cp_cmd_copy "$@" ;;
        -h|--help)          _cp_cmd_status ;;
        -*)                 printf 'claude-profile: unknown option %s\n' "$1" >&2; return 1 ;;
        *)
            _n="$1"; shift
            if [ "${1:-}" = "--" ]; then
                shift
                _cp_cmd_run "$_n" "$@"
            else
                _cp_cmd_set "$_n"
            fi
            ;;
    esac
}

claude() {
    if [ "${1:-}" = profile ]; then
        shift
        _cp_main "$@"
        return $?
    fi
    CLAUDE_CONFIG_DIR="$(_cp_resolve)" command claude "$@"
}
