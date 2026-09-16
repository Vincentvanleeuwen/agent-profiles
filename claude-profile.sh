#!/bin/sh
# Compatibility entry point. New integrations use agent-profile.sh.

_ap_compat_exec=""
if [ -n "${BASH_SOURCE:-}" ]; then
    _ap_compat_self="$BASH_SOURCE"
    [ "$BASH_SOURCE" = "$0" ] && _ap_compat_exec=1
elif [ -n "${ZSH_VERSION:-}" ]; then
    _ap_compat_self="${BASH_SOURCE:-${(%):-%x}}"
    case "${ZSH_EVAL_CONTEXT:-}" in *file*) ;; *) _ap_compat_exec=1 ;; esac
else
    _ap_compat_self="$0"
    case "$0" in
        claude-profile|claude-profile.sh|*/claude-profile|*/claude-profile.sh) _ap_compat_exec=1 ;;
    esac
fi

while [ -L "$_ap_compat_self" ]; do
    _ap_compat_target=$(readlink "$_ap_compat_self") || break
    case "$_ap_compat_target" in
        /*) _ap_compat_self="$_ap_compat_target" ;;
        *)  _ap_compat_self="$(dirname "$_ap_compat_self")/$_ap_compat_target" ;;
    esac
done

_ap_compat_dir=$(cd "$(dirname "$_ap_compat_self")" >/dev/null 2>&1 && pwd) || {
    printf 'claude-profile: cannot locate agent-profile.sh\n' >&2
    if [ -n "$_ap_compat_exec" ]; then exit 1; fi
    return 1
}
[ -n "$_ap_compat_exec" ] && _AP_COMPAT_EXEC=1
. "$_ap_compat_dir/agent-profile.sh"
_ap_compat_status=$?
unset _AP_COMPAT_EXEC _ap_compat_exec _ap_compat_self _ap_compat_target _ap_compat_dir
if [ -n "${_CP_EXEC:-}" ]; then exit "$_ap_compat_status"; fi
unset _ap_compat_status
