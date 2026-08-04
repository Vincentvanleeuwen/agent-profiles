#!/bin/sh
# claude-profile — switch Claude Code between named configuration profiles.
# POSIX sh; runs under zsh and bash.
#
# Two ways in. Sourced from ~/.zshrc or ~/.bashrc — what install.sh sets up —
# every subcommand works and a bare `claude` picks up the active profile.
# Executed instead (./claude-profile.sh --create dev) nothing needs installing,
# and everything works except that shadowing: only a function already in your
# shell can make a plain `claude` follow the active profile.
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
#   statusline.sh  the ~/.claude/statusline.sh block

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
        claude-profile|claude-profile.sh|*/claude-profile|*/claude-profile.sh)
            _CP_EXEC=1 ;;
    esac
fi
_CP_HOME=$(cd "$(dirname "$_CP_SELF")" && pwd)

# Directory holding this file with symlinks resolved, so lib/ is still findable
# when claude-profile.sh is symlinked into a dotfiles repo or ~/bin.
#
# Deliberately not folded into _CP_HOME above: _CP_HOME is also the default
# profile store, so resolving symlinks there would silently relocate the
# profiles of anyone already installed that way. readlink -f would be shorter
# but is not portable; this loop is.
_cp_libdir() {
    _ld_p="$1"
    while [ -L "$_ld_p" ]; do
        _ld_t=$(readlink "$_ld_p")
        case "$_ld_t" in
            /*) _ld_p="$_ld_t" ;;
            *)  _ld_p="$(dirname "$_ld_p")/$_ld_t" ;;
        esac
    done
    (cd "$(dirname "$_ld_p")" && pwd)
}
_CP_LIB="$(_cp_libdir "$_CP_SELF")/lib"

# Load order does not matter — sh resolves function references at call time, and
# the lib files only assign variables at the top level. Refusing to continue on
# a missing file is the point: a partial load leaves a `claude` wrapper that
# calls functions which do not exist.
for _cp_f in resolve build profile commands manage inspect statusline; do
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
claude profile                       show active profile and list all
claude profile <name>                set the active profile
claude profile default               clear the active profile (back to ~/.claude)
claude profile <name> -- <args>      run one session in <name>, active unchanged

claude profile --create <name>       snapshot the current setup into a new profile
claude profile --update <name>       mirror the current setup into an existing profile
claude profile --reset [name]        wipe a profile back to a fresh config (default: active)
claude profile --delete <name>       delete a profile (backed up first)
claude profile --rename <a> <b>      rename a profile
claude profile --copy <a> <b>        duplicate a profile

claude profile --show <name>         model, plugins, skills, hooks, mcp servers
claude profile --diff <a> <b>        the same, for two profiles

claude profile --export <name> [f]   tarball to exports/ (no credentials)
claude profile --import <file> [n]   create a profile from a tarball

claude profile --install-statusline    show the running profile (or default) in your statusline
claude profile --uninstall-statusline  remove it

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
        --export)           shift; _cp_cmd_export "$@" ;;
        --import)           shift; _cp_cmd_import "$@" ;;
        --install-statusline)   _cp_cmd_install_statusline ;;
        --uninstall-statusline) _cp_cmd_uninstall_statusline ;;
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

claude() {
    if [ "${1:-}" = profile ]; then
        shift
        _cp_main "$@"
        return $?
    fi
    _cp_launch "$(_cp_resolve)" "$@"
}

# Executed rather than sourced: take the arguments straight to the dispatcher,
# so a fresh clone works before anything has been added to a shell rc. The
# `claude` function above is defined either way and simply goes unused here —
# nothing outside this process can see it.
if [ -n "${_CP_EXEC:-}" ]; then
    _cp_main "$@"
    exit $?
fi
