# Installing and removing the statusline block in ~/.claude/statusline.sh.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_CP_SL_START="# CLAUDE_PROFILE_BLOCK start"
_CP_SL_END="# CLAUDE_PROFILE_BLOCK end"

# Backs up $1 to $1.bak, unless .bak already exists — that's the pre-block
# original and the most valuable thing to preserve, so it is never
# overwritten. A later call instead writes a timestamped sibling and says so.
_cp_backup_statusline() {
    if [ -f "$1.bak" ]; then
        _stamp=$(date +%Y%m%d-%H%M%S)
        _dst="$1.bak.$_stamp"
        _i=1
        while [ -e "$_dst" ]; do
            _dst="$1.bak.$_stamp-$_i"
            _i=$((_i + 1))
        done
        cp "$1" "$_dst" || { printf 'claude-profile: failed to back up %s\n' "$1" >&2; return 1; }
        printf 'claude-profile: %s.bak already exists, wrote %s instead\n' "$1" "$_dst" >&2
    else
        cp "$1" "$1.bak" || { printf 'claude-profile: failed to back up %s\n' "$1" >&2; return 1; }
    fi
}

# Appends a guarded, idempotent block to ~/.claude/statusline.sh that prints
# the config the session is actually running on. The only command in this tool
# that writes to the real ~/.claude — everything else is profile-scoped. Always
# prints something: the profile name when one is active, "default" when the
# session is on the base ~/.claude, so the statusline never leaves you guessing
# which of the two you are in.
_cp_cmd_install_statusline() {
    _f="$HOME/.claude/statusline.sh"
    if [ -f "$_f" ]; then
        if grep -q "$_CP_SL_START" "$_f"; then
            printf 'statusline block already installed\n'
            return 0
        fi
        _cp_backup_statusline "$_f" || return 1
    else
        mkdir -p "$HOME/.claude" || return 1
        printf '#!/bin/sh\n' > "$_f" || { printf 'claude-profile: failed to create %s\n' "$_f" >&2; return 1; }
        _cp_backup_statusline "$_f" || return 1
    fi
    {
        printf '%s\n' "$_CP_SL_START"
        printf 'if [ -z "$CLAUDE_CONFIG_DIR" ] || [ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude" ]; then printf '"'"' · [default]'"'"'; else printf '"'"' · [%%s]'"'"' "${CLAUDE_CONFIG_DIR##*/}"; fi\n'
        printf '%s\n' "$_CP_SL_END"
    } >> "$_f" || { printf 'claude-profile: failed to write %s\n' "$_f" >&2; return 1; }
    chmod +x "$_f" || return 1
    printf 'statusline block installed\n'
}

_cp_cmd_uninstall_statusline() {
    _f="$HOME/.claude/statusline.sh"
    [ -f "$_f" ] || { printf 'no statusline.sh\n'; return 0; }
    grep -q "$_CP_SL_START" "$_f" || { printf 'statusline block not installed\n'; return 0; }
    # A hand-edited or truncated marker leaves the range unbalanced. sed's
    # /start/,/end/d with no matching end deletes to EOF, so refuse rather
    # than risk eating everything after the start marker.
    if ! grep -q "$_CP_SL_END" "$_f"; then
        printf 'claude-profile: "%s" has a start marker but no end marker; refusing to touch it\n' "$_f" >&2
        return 1
    fi
    _t="$_f.tmp.$$"
    sed -e "/$_CP_SL_START/,/$_CP_SL_END/d" "$_f" > "$_t" || { rm -f "$_t"; printf 'claude-profile: failed to rewrite %s\n' "$_f" >&2; return 1; }
    mv "$_t" "$_f" || { rm -f "$_t"; printf 'claude-profile: failed to rewrite %s\n' "$_f" >&2; return 1; }
    chmod +x "$_f" || return 1
    printf 'statusline block removed\n'
}
