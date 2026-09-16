#!/bin/sh
# agent-profile — switch AI coding tools between named configuration profiles.
# POSIX sh; runs under zsh and bash.
#
# Two ways in. Sourced from ~/.zshrc or ~/.bashrc — what install.sh sets up —
# you get an `agent-profile` function for every subcommand, and a bare `claude`
# picks up the active profile. Executed instead (./agent-profile.sh --create dev)
# nothing needs installing, and everything works except that shadowing: only a
# function already in your shell can make a plain `claude` follow the active
# profile.
#
# This file is the entry point only: it locates lib/, sources it, and holds the
# argument dispatch. The implementation is in lib/:
#
#   resolve.sh     which profile is selected, and where it lives
#   build.sh       building a profile dir from a config dir
#   profile.sh     profile names, validity, and the shared guards
#   commands.sh    read/set the active profile, launch claude
#   manage.sh      backup, update, reset, delete, rename, copy
#   inspect.sh     show, diff, export, import

# Path of this file, and whether we were executed or sourced.
#
# Executed, $0 is this file in every shell. Sourced, $0 belongs to the caller
# and each shell has to be asked its own way. Branching rather than nesting the
# fallbacks in one expansion is what keeps ${(%):-%x} away from dash, which
# parses it happily and then cannot expand it.
if [ -n "${BASH_SOURCE:-}" ]; then
    _CP_SELF="$BASH_SOURCE"
    [ "$BASH_SOURCE" = "$0" ] && _CP_EXEC=1
elif [ -n "${ZSH_VERSION:-}" ]; then
    # The redundant-looking ${BASH_SOURCE:-...} wrapper is load-bearing: dash
    # parses the nested form but rejects a bare ${(%):-%x} outright, and this
    # file has to survive `dash -n` even though dash never runs this branch.
    # BASH_SOURCE is empty here by definition, so zsh always takes the fallback.
    _CP_SELF="${BASH_SOURCE:-${(%):-%x}}"
    case "${ZSH_EVAL_CONTEXT:-}" in
        *file*) ;;
        *) _CP_EXEC=1 ;;
    esac
else
    # Plain sh: no BASH_SOURCE, no %x, so a sourced copy cannot find itself at
    # all and only the executed case is supportable — which is the one $0
    # answers. Matching the name rather than assuming keeps a source under dash
    # from running _cp_main on the caller's arguments.
    _CP_SELF="$0"
    case "$0" in
        agent-profile|agent-profile.sh|claude-profile|claude-profile.sh|*/agent-profile|*/agent-profile.sh|*/claude-profile|*/claude-profile.sh)
            _CP_EXEC=1 ;;
    esac
fi
[ -n "${_AP_COMPAT_EXEC:-}" ] && _CP_EXEC=1

# readlink -f would be shorter but is not portable; this loop is.
_cp_deref() {
    _dr_p="$1"
    while [ -L "$_dr_p" ]; do
        _dr_t=$(readlink "$_dr_p")
        case "$_dr_t" in
            /*) _dr_p="$_dr_t" ;;
            *)  _dr_p="$(dirname "$_dr_p")/$_dr_t" ;;
        esac
    done
    printf '%s' "$_dr_p"
}

# Interactive chpwd hooks may print output that command substitution mistakes for the path.
_cp_libdir() { (cd "$(dirname "$(_cp_deref "$1")")" >/dev/null 2>&1 && pwd); }
_CP_LIB="$(_cp_libdir "$_CP_SELF")/lib"

# Load order does not matter — sh resolves function references at call time, and
# the lib files only assign variables at the top level. Refusing to continue on
# a missing file is the point: a partial load leaves a `claude` wrapper that
# calls functions which do not exist.
for _cp_f in resolve build profile commands manage inspect migrate; do
    if [ -r "$_CP_LIB/$_cp_f.sh" ]; then
        . "$_CP_LIB/$_cp_f.sh"
    else
        printf 'claude-profile: cannot read %s/%s.sh; not loading\n' "$_CP_LIB" "$_cp_f" >&2
        unset _cp_f
        # `return` outside a function is an error in an executed script, so the
        # way out depends on how we got here.
        if [ -n "${_CP_EXEC:-}" ]; then exit 1; fi
        return 1
    fi
done
unset _cp_f

_cp_cmd_help() {
    cat <<'EOF'
agent-profile                       show active profile and list all
agent-profile <name>                set the active profile
agent-profile default               clear the active profile (back to ~/.claude)
agent-profile <name> -- <args>      run one session in <name>, active unchanged

agent-profile --create <name>       snapshot the current setup into a new profile
agent-profile --update <name>       mirror the current setup into an existing profile
agent-profile --reset [name]        wipe a profile back to a fresh config (default: active)
agent-profile --delete <name>       delete a profile (backed up first)
agent-profile --rename <a> <b>      rename a profile
agent-profile --copy <a> <b>        duplicate a profile

agent-profile --show [name]         model, plugins, skills, hooks, mcp servers
agent-profile --diff <a> <b>        the same, for two profiles
agent-profile --path [name]         print where a profile's config lives
agent-profile --open [name]         open that directory in your file manager

agent-profile --export <name> [f]   tarball to exports/ (no credentials)
agent-profile --import <file> [n]   create a profile from a tarball

agent-profile --migrate-store <dir>   move a store out of an old clone

Where [name] is optional it defaults to the profile you are in right now.

Resolution order: $CLAUDE_PROFILE, then .claude-profile walking up from the
current directory, then the active profile, then ~/.claude.
EOF
}

_cp_main() {
    case "${1:-}" in
        "")                 _cp_cmd_status ;;
        default)            _cp_cmd_default ;;
        --reset)            shift; _cp_cmd_reset "$@" ;;
        --create)           shift; _cp_cmd_create "$@" ;;
        --update)           shift; _cp_cmd_update "$@" ;;
        --delete)           shift; _cp_cmd_delete "$@" ;;
        --rename)           shift; _cp_cmd_rename "$@" ;;
        --copy)             shift; _cp_cmd_copy "$@" ;;
        --show)             shift; _cp_cmd_show "$@" ;;
        --diff)             shift; _cp_cmd_diff "$@" ;;
        --path)             shift; _cp_cmd_path "$@" ;;
        --open)             shift; _cp_cmd_open "$@" ;;
        --export)           shift; _cp_cmd_export "$@" ;;
        --import)           shift; _cp_cmd_import "$@" ;;
        --migrate-store)     shift; _cp_migrate_store "$@" ;;
        # Internal, and deliberately absent from --help: it exists for bin/claude, not for people.
        --run-active)        shift; _cp_launch "$(_cp_resolve)" "$@" ;;
        # Internal, and deliberately absent from --help: it is a hook, not a
        # command. The PowerShell wrapper starts claude itself — a TUI cannot be
        # run through a non-interactive `bash -c` — so it has no _cp_launch to
        # hang the prompt-state sync off, and calls this on either side instead.
        --sync-prompts)     shift; _cp_sync_prompts "$@" ;;
        -h|--help)          _cp_cmd_help ;;
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

# The whole reason the source line is worth having: a `claude` that follows the
# active profile rather than always reading ~/.claude. Management lives in
# agent-profile, not behind a subcommand of this.
claude() {
    _cp_launch "$(_cp_resolve)" "$@"
}

# The management surface, as a function and not only as the symlink install.sh
# puts on PATH. Sourcing is the thing install.sh guarantees; PATH is not —
# ~/.local/bin is absent from the default PATH on macOS — and a management
# command that exists in some shells and not others is worse than either.
#
# Through eval because a hyphen is legal in a bash or zsh function name and a
# parse error where it is not: inside a string it is not parsed until the eval
# runs, which is what keeps `dash -n` on this file working.
#
# The guard has to be a capability test, and it cannot be "try it and ignore the
# failure" — under dash and macOS sh that eval is fatal, exit 2, taking the rest
# of the rc with it. Nor is BASH_VERSION enough on its own: macOS /bin/sh is bash
# 3.2 in POSIX mode, where BASH_VERSION is set and hyphenated function names are
# rejected anyway. SHELLOPTS is what separates those two, and bash always sets it.
#
# Nothing is lost in the shells that miss out. A sourced copy cannot locate itself
# under plain sh at all (see the top of this file), so sourcing there is already
# unsupported — this simply does not add a second way to notice.
_cp_fn_hyphen=""
[ -n "${ZSH_VERSION:-}" ] && _cp_fn_hyphen=1
if [ -n "${BASH_VERSION:-}" ]; then
    case ":${SHELLOPTS:-}:" in
        *:posix:*) ;;
        *) _cp_fn_hyphen=1 ;;
    esac
fi
if [ -n "$_cp_fn_hyphen" ]; then
    eval 'agent-profile() { _cp_main "$@"; }'
    eval 'claude-profile() { _cp_main "$@"; }'
fi
unset _cp_fn_hyphen

# Executed rather than sourced: take the arguments straight to the dispatcher,
# so a fresh clone works before anything has been added to a shell rc. The two
# functions above are defined either way and simply go unused here — nothing
# outside this process can see them.
if [ -n "${_CP_EXEC:-}" ]; then
    _cp_main "$@"
    exit $?
fi

# Sourced: point everything in this shell at the active profile, not only the
# two functions above. See _cp_export_config_dir.
_cp_export_config_dir
