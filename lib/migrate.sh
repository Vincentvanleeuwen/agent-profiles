# Moving the store out of the clone. Everything a profile baked into its own
# config as an absolute path has to move with it, or every hook silently stops
# firing.
#
# Sourced by ../agent-profile.sh. Not standalone: no shebang, no set -e.

_CP_MIGRATE_ENTRIES="profiles active exports .backups prompt-state.json codex-default.config.toml gemini-default.settings.json"

_cp_migrate_store() {
    [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch shwordsplit
    _ms_from="$1"
    if [ -z "$_ms_from" ]; then
        printf 'claude-profile: --migrate-store needs a directory\n' >&2
        return 1
    fi
    _ms_from=$(cd "$_ms_from" >/dev/null 2>&1 && pwd) || {
        printf 'claude-profile: no such directory "%s"\n' "$1" >&2
        return 1
    }
    _ms_to=$(_cp_store)
    if [ "$_ms_from" = "$_ms_to" ]; then
        printf 'claude-profile: "%s" is already the store\n' "$_ms_from" >&2
        return 1
    fi
    if [ ! -d "$_ms_from/profiles" ]; then
        _ms_partial=0
        for _ms_e in $_CP_MIGRATE_ENTRIES; do
            [ -e "$_ms_to/$_ms_e" ] && _ms_partial=1
        done
        if [ "$_ms_partial" = 1 ]; then
            printf 'claude-profile: "%s" has no profiles/, but "%s" already holds migrated data -- this looks like an interrupted migration; do not delete "%s" until you check what remains there\n' \
                "$_ms_from" "$_ms_to" "$_ms_from" >&2
        else
            printf 'claude-profile: "%s" has no profiles/ to migrate\n' "$_ms_from" >&2
        fi
        return 1
    fi
    for _ms_e in $_CP_MIGRATE_ENTRIES; do
        if { [ -e "$_ms_from/$_ms_e" ] || [ -L "$_ms_from/$_ms_e" ]; } &&
           { [ -e "$_ms_to/$_ms_e" ] || [ -L "$_ms_to/$_ms_e" ]; }; then
            printf 'claude-profile: "%s" already has %s; refusing to merge\n' "$_ms_to" "$_ms_e" >&2
            return 1
        fi
    done
    # sed builds the rewrite expression from these paths, so a path containing
    # a delimiter or an escape would silently corrupt the file instead.
    case "$_ms_from$_ms_to" in
        *[\\\&\|]*)
            printf 'claude-profile: paths contain \\, & or |, cannot rewrite safely\n' >&2
            return 1 ;;
    esac
    mkdir -p "$_ms_to" || return 1
    _ms_moved=""
    for _ms_e in $_CP_MIGRATE_ENTRIES; do
        [ -e "$_ms_from/$_ms_e" ] || continue
        if ! mv "$_ms_from/$_ms_e" "$_ms_to/$_ms_e"; then
            if [ -n "$_ms_moved" ]; then
                printf 'claude-profile: already moved %s to "%s"; "%s" failed -- do not delete "%s" yet\n' \
                    "$_ms_moved" "$_ms_to" "$_ms_e" "$_ms_from" >&2
            else
                printf 'claude-profile: could not move %s\n' "$_ms_e" >&2
            fi
            return 1
        fi
        printf 'moved %s\n' "$_ms_e"
        _ms_moved="${_ms_moved:+$_ms_moved }$_ms_e"
    done
    _cp_migrate_rewrite "$_ms_from" "$_ms_to" || return 1
    _ms_codex_link=$(readlink "$HOME/.codex/config.toml" 2>/dev/null)
    case "$_ms_codex_link" in
        "$_ms_from"/*)
            _ms_codex_target="$_ms_to/${_ms_codex_link#"$_ms_from"/}"
            [ -e "$_ms_codex_target" ] && _cp_codex_link "$_ms_codex_target" || return 1
            ;;
    esac
    _ms_gemini_link=$(readlink "$HOME/.gemini/settings.json" 2>/dev/null)
    case "$_ms_gemini_link" in
        "$_ms_from"/*)
            _ms_gemini_target="$_ms_to/${_ms_gemini_link#"$_ms_from"/}"
            [ -e "$_ms_gemini_target" ] && _cp_gemini_link "$_ms_gemini_target" || return 1
            ;;
    esac
    printf 'store is now %s\n' "$_ms_to"
}

# Only the files a profile owns. .claude.json and teams/*/config.json hold
# project history for the old clone directory, which still exists and must
# keep pointing there.
_cp_migrate_rewrite() {
    [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch shwordsplit
    _mr_from="$1"
    _mr_to="$2"
    _mr_backup="$_mr_to/.backups/migrate-$(date +%Y%m%d-%H%M%S)"
    _mr_rewrote=0
    # $_mr_from is used as a regex below; a literal . * [ ] ^ $ in a real
    # path would otherwise be read as regex syntax and silently mismatch.
    # grep -F sidesteps that on the match gate; sed has no fixed-string mode,
    # so its pattern copy is escaped instead. The bracket order (] first)
    # matters: it is the one position where ] can appear literal.
    _mr_pat=$(printf '%s' "$_mr_from" | sed 's/[].[*^$\\]/\\&/g')
    for _mr_p in "$_mr_to"/profiles/*/settings.json \
                 "$_mr_to"/profiles/*/settings.local.json \
                 "$_mr_to"/profiles/*/statusline.sh \
                 "$_mr_to"/profiles/*/hooks/*; do
        [ -f "$_mr_p" ] || continue
        grep -Fq "$_mr_from/profiles/" "$_mr_p" 2>/dev/null || continue
        _mr_rel=${_mr_p#"$_mr_to"/}
        if ! mkdir -p "$_mr_backup/$(dirname "$_mr_rel")"; then
            printf 'claude-profile: could not create %s\n' "$_mr_backup" >&2
            return 1
        fi
        # Captured before cp: cp's mode is subject to umask, the source file's
        # own bit is not.
        _mr_was_exec=0
        [ -x "$_mr_p" ] && _mr_was_exec=1
        cp "$_mr_p" "$_mr_backup/$_mr_rel" || {
            printf 'claude-profile: could not back up %s\n' "$_mr_rel" >&2
            return 1
        }
        _mr_t="$_mr_p.cp-tmp.$$"
        if ! sed "s|$_mr_pat/profiles/|$_mr_to/profiles/|g" "$_mr_p" > "$_mr_t"; then
            rm -f "$_mr_t"
            printf 'claude-profile: could not rewrite %s\n' "$_mr_rel" >&2
            return 1
        fi
        if ! mv "$_mr_t" "$_mr_p"; then
            rm -f "$_mr_t"
            printf 'claude-profile: could not replace %s\n' "$_mr_rel" >&2
            return 1
        fi
        # mv over the original drops the mode bits the temp file was created
        # with; restore the executable bit if the original had it.
        [ "$_mr_was_exec" = 1 ] && chmod +x "$_mr_p"
        printf 'rewrote %s\n' "$_mr_rel"
        _mr_rewrote=1
    done
    # `&&` here would leak its own pass/fail as this function's return value
    # once nothing follows it -- `if` always returns 0 regardless of the branch.
    if [ "$_mr_rewrote" = 1 ]; then
        printf 'backups in %s\n' "$_mr_backup"
    fi
}
