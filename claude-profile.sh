# claude-profile — switch Claude Code between named configuration profiles.
# Source this from ~/.zshrc or ~/.bashrc. POSIX sh; runs under zsh and bash.
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

# Path of this file when sourced. $BASH_SOURCE is set under bash; the zsh
# fallback ${(%):-%x} is only ever expanded when it is not, so bash never
# parses it as a value.
_CP_SELF="${BASH_SOURCE:-${(%):-%x}}"
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
