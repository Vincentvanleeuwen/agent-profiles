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

# Which Python to run, printed as a command word list; fails if there is none.
#
# Callers used to run `python3` after a `command -v python3` guard. That guard
# is not enough on Windows, where `python3` on PATH is usually the Microsoft
# Store's App Execution Alias: a stub that exists, so `command -v` finds it,
# and then prints "Python was not found; run without arguments to install from
# the Microsoft Store" to stderr and exits 49 without running anything. A real
# Python is normally installed alongside it as `python` or the `py` launcher,
# so the answer is to probe rather than to give up.
#
# Probing means running each candidate and checking what came back, not just
# checking its exit status: the stub's 49 is undocumented and costs nothing to
# stop relying on. Cached because --show and --diff call this per profile and
# PATH does not change underneath a running command.
_cp_python() {
    if [ -z "${_CP_PYTHON_PROBED:-}" ]; then
        _CP_PYTHON_PROBED=1
        _CP_PYTHON=''
        # python3 first so a POSIX system stops at the first candidate. `py -3`
        # is Windows-only, and is the one that is still a real Python in the
        # case this whole function exists for.
        for _cp_py in python3 python "py -3"; do
            # shellcheck disable=SC2086 # deliberate: "py -3" must split
            if [ "$($_cp_py -c 'print(1)' 2>/dev/null)" = 1 ]; then
                _CP_PYTHON="$_cp_py"
                break
            fi
        done
    fi
    [ -n "$_CP_PYTHON" ] || return 1
    printf '%s' "$_CP_PYTHON"
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
