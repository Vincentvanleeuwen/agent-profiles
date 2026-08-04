# Commands that change a profile: backup, update, reset, delete, rename, copy.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_backup() {
    _n="$1"
    _stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$(_cp_store)/.backups" || return 1
    # Never write into an existing path: mv into an existing directory nests
    # inside it rather than failing, which would leave two generations stacked
    # with only the first reachable at the reported path.
    _dst="$(_cp_store)/.backups/$_n-$_stamp"
    _i=1
    while [ -e "$_dst" ]; do
        _dst="$(_cp_store)/.backups/$_n-$_stamp-$_i"
        _i=$((_i + 1))
    done
    mv "$(_cp_dir "$_n")" "$_dst" || return 1
    printf '%s' "$_dst"
}

_cp_cmd_update() {
    _n="$1"
    _cp_need "$_n" || return 1
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

# Wipe a profile back to a first-run ~/.claude: nothing profile-owned left, and
# shared paths still linked to base so you are not logged out. Building from an
# empty directory is exactly that, so there is no second teardown path to keep in
# sync with _cp_build. Never operates on ~/.claude itself.
_cp_cmd_reset() {
    _n="${1:-$(_cp_selected)}"
    if [ -z "$_n" ]; then
        printf 'claude-profile: no profile selected; --reset never touches ~/.claude\n' >&2
        return 1
    fi
    _cp_need "$_n" || return 1
    # Confirm even though the old contents are backed up: --reset used to be an
    # alias for "default", so muscle memory aims it at a profile people meant to
    # only switch away from.
    _cp_confirm "$_n" "reset profile \"$_n\" to a fresh ~/.claude? type the name to confirm: " || return 1
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not resetting "%s"\n' "$_n" >&2
        return 1
    fi
    _empty=$(mktemp -d) || return 1
    if ! _cp_build "$_empty" "$(_cp_dir "$_n")"; then
        rmdir "$_empty"
        printf 'claude-profile: failed to reset "%s"; previous contents at %s\n' "$_n" "$_bk" >&2
        return 1
    fi
    rmdir "$_empty"
    printf 'backed up -> %s\n' "$_bk"
    printf 'reset %s (fresh config; shared paths still linked to base)\n' "$_n"
}

_cp_cmd_delete() {
    _n="$1"
    _cp_need "$_n" || return 1
    if [ "$(_cp_selected)" = "$_n" ]; then
        printf 'claude-profile: "%s" is active; run "claude-profile default" first\n' "$_n" >&2
        return 1
    fi
    _cp_confirm "$_n" "delete profile \"$_n\"? type the name to confirm: " || return 1
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not deleting "%s"\n' "$_n" >&2
        return 1
    fi
    # $CLAUDE_PROFILE or a pin can outrank active, so the deleted profile can
    # be named in active without being the selected one — clear the dangling
    # pointer rather than warn on every invocation forever, same as rename.
    if [ "$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)" = "$_n" ]; then
        rm -f "$(_cp_store)/active"
    fi
    printf 'deleted %s (kept at %s)\n' "$_n" "$_bk"
}

_cp_cmd_rename() {
    _o="$1"; _n="$2"
    _cp_need "$_o" || return 1
    _cp_free "$_n" || return 1
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
    _cp_need "$_s" || return 1
    _cp_free "$_n" || return 1
    if ! _cp_build "$(_cp_dir "$_s")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to copy "%s"\n' "$_s" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'copied %s -> %s\n' "$_s" "$_n"
}

