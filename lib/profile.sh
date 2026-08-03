# Profile names: where they live, whether they are valid, and the guards every command opens with.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_dir()    { printf '%s' "$(_cp_store)/profiles/$1"; }
# _cp_valid_name gate is required here: _cp_dir "" is "<store>/profiles/",
# which is always a directory, so without it an omitted/empty name would
# validate as "exists" against the whole store.
_cp_exists() { _cp_valid_name "$1" && [ -d "$(_cp_dir "$1")" ]; }
_cp_valid_name() {
    case "$1" in
        ""|.|..|*/*|-*|*[[:space:]]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Every command opens with the same name checks, so the wording lives here:
# one place to fix a message, and callers read as a single guard line.
_cp_no_such()  { printf 'claude-profile: no such profile "%s"\n' "$1" >&2; return 1; }
_cp_bad_name() { printf 'claude-profile: bad name "%s"\n' "$1" >&2; return 1; }
_cp_taken()    { printf 'claude-profile: "%s" already exists\n' "$1" >&2; return 1; }

# Name must already be a profile.
_cp_need() { _cp_exists "$1" || _cp_no_such "$1"; }

# Name must be usable for a profile that does not exist yet.
_cp_free() {
    _cp_valid_name "$1" || { _cp_bad_name "$1"; return 1; }
    if _cp_exists "$1"; then _cp_taken "$1"; return 1; fi
    return 0
}

# Destructive commands make you type the profile name back. _CP_YES skips it.
_cp_confirm() {
    [ -n "${_CP_YES:-}" ] && return 0
    printf '%s' "$2"
    read -r _cf_answer
    [ "$_cf_answer" = "$1" ] && return 0
    printf 'cancelled\n'
    return 1
}
