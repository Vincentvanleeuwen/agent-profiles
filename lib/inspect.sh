# Commands that report on or move profiles: show, path, open, diff, export, import.
#
# Sourced by ../agent-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

# A path for a person to read, on its own line.
#
# Git Bash's /c/Users/... is the right answer in the shell it came from and an
# unusable one in PowerShell, which is where most Windows callers actually are.
# The sh side cannot tell the two apart, so the PowerShell wrapper says which it
# is (Invoke-CpBash sets this) and everything else keeps one implementation.
_cp_showpath() {
    if [ -n "${CLAUDE_PROFILE_WINPATH:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1" 2>/dev/null && return 0
    fi
    printf '%s\n' "$1"
}

_cp_summary() {
    _d="$1"
    # Printed here rather than handed to python below, which looks like the
    # obvious place for it. When python is a native Windows build, MSYS rewrites
    # anything argument-shaped into a Windows path on the way in, so the line
    # would come back converted on exactly the platform --path was not — and
    # printing it before the summary means a machine with no python still gets
    # told where the profile is.
    printf '  path     '
    _cp_showpath "$_d"
    # Unlike the sync helpers, --show and --diff are the summary: with no Python
    # there is nothing to fall back to, so say which command is missing rather
    # than letting the shell report a bare "python3: command not found".
    _sm_py=$(_cp_python) || {
        printf 'claude-profile: need python3, python or py to summarise a profile\n' >&2
        return 127
    }
    # shellcheck disable=SC2086 # deliberate: _cp_python may return "py -3"
    $_sm_py - "$_d" <<'PY'
import json, os, sys

d = sys.argv[1]

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

s = load(os.path.join(d, "settings.json"))

plugins = sorted(k for k, v in (s.get("enabledPlugins") or {}).items() if v)
hooks = sum(
    len(b.get("hooks") or []) if isinstance(b, dict) else 0
    for v in (s.get("hooks") or {}).values() if isinstance(v, list)
    for b in v
)

skills_dir = os.path.join(d, "skills")
skills = sorted(
    e for e in os.listdir(skills_dir)
    if not e.startswith(".") and os.path.isdir(os.path.join(skills_dir, e))
) if os.path.isdir(skills_dir) else []

mcp = sorted((load(os.path.join(d, ".claude.json")).get("mcpServers") or {}))

print("  model    %s" % (s.get("model") or "-"))
print("  plugins  %s" % (", ".join(plugins) or "-"))
print("  skills   %s" % (", ".join(skills) or "-"))
print("  hooks    %d" % hooks)
print("  mcp      %s" % (", ".join(mcp) or "-"))
PY
}

# The directory a session started here would use, for the commands that take an
# optional name. Sets _CP_CUR_DIR and _CP_CUR_LABEL instead of printing one of
# them: a $(...) call is a subshell, so a variable set inside would not survive,
# and these two answers have to arrive together.
#
# Deliberately not _cp_resolve, which prints the directory and nothing else.
# Reporting commands need the name and the reason it won as well.
_cp_current() {
    _cu_sel=$(_cp_selected)
    # $(...) again: _CP_SRC set inside the call above stayed in that subshell.
    # Re-run for the side effect, stdout already captured. Same as _cp_cmd_status.
    _cp_selected >/dev/null
    if [ -n "$_cu_sel" ] && _cp_exists "$_cu_sel"; then
        _CP_CUR_DIR=$(_cp_dir "$_cu_sel")
        _CP_CUR_LABEL="$_cu_sel  ($_CP_SRC)"
        return 0
    fi
    # A name that selects nothing is what you most want to be told about, so it
    # warns the way _cp_resolve does rather than quietly reading as "no profile".
    if [ -n "$_cu_sel" ]; then
        printf 'claude-profile: unknown profile "%s", using ~/.claude\n' "$_cu_sel" >&2
    fi
    _CP_CUR_DIR="$HOME/.claude"
    _CP_CUR_LABEL="none (using ~/.claude)"
}

_cp_cmd_show() {
    _n="${1:-}"
    if [ -z "$_n" ]; then
        _cp_current
        printf '%s\n' "$_CP_CUR_LABEL"
        _cp_summary "$_CP_CUR_DIR"
        return
    fi
    _cp_need "$_n" || return 1
    printf '%s\n' "$_n"
    _cp_summary "$(_cp_dir "$_n")"
}

# Just the path, on stdout, nothing else — the form that survives $( ) and cd.
_cp_cmd_path() {
    _n="${1:-}"
    if [ -z "$_n" ]; then
        _cp_current
        _cp_showpath "$_CP_CUR_DIR"
        return 0
    fi
    _cp_need "$_n" || return 1
    _cp_showpath "$(_cp_dir "$_n")"
}

_cp_cmd_open() {
    _n="${1:-}"
    if [ -z "$_n" ]; then
        _cp_current
        _op_d="$_CP_CUR_DIR"
    else
        _cp_need "$_n" || return 1
        _op_d=$(_cp_dir "$_n")
    fi
    # Printed before opening, and printed even when nothing can open it: a path
    # you can read is the useful half of this command, and the half that works
    # over ssh or in a container.
    _cp_showpath "$_op_d"
    # Same seam as _CP_RUNNER on the launch path, and for the same reason: the
    # test suite has to be able to run this without a file manager opening on
    # whoever is watching.
    if [ -n "${_CP_OPENER:-}" ]; then
        "$_CP_OPENER" "$_op_d"
        return $?
    fi
    case "$(uname -s 2>/dev/null)" in
        Darwin)
            open "$_op_d" ;;
        MINGW*|MSYS*|CYGWIN*)
            # Explorer wants a Windows path; under Git Bash $_op_d is /c/... and
            # would be read as a relative path off the current drive. It also
            # exits 1 on success, so its status is not worth passing on.
            _op_w=$(cygpath -w "$_op_d" 2>/dev/null) || _op_w="$_op_d"
            explorer.exe "$_op_w"
            return 0 ;;
        *)
            command -v xdg-open >/dev/null 2>&1 || {
                printf 'claude-profile: no xdg-open here; the path is above\n' >&2
                return 1
            }
            xdg-open "$_op_d" ;;
    esac
}

_cp_cmd_diff() {
    _a="$1"; _b="$2"
    _cp_need "$_a" || return 1
    _cp_need "$_b" || return 1
    printf '%s\n' "$_a"
    _cp_summary "$(_cp_dir "$_a")"
    printf '%s\n' "$_b"
    _cp_summary "$(_cp_dir "$_b")"
}

_cp_owned() {
    _d="$1"
    [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch
    for _e in "$_d"/* "$_d"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_shared "$_b" && continue
        _cp_is_skipped "$_b" && continue
        printf '%s\n' "$_b"
    done
}

_cp_cmd_export() {
    _n="$1"
    _cp_need "$_n" || return 1
    _cp_codex_ensure "$_n" || return 1
    if [ -n "${2:-}" ]; then
        _out="$2"
    else
        _out="$(_cp_store)/exports/$_n.tar.gz"
        mkdir -p "$(_cp_store)/exports" || return 1
    fi
    _d=$(_cp_dir "$_n")
    if [ -e "$_d/.credentials.json" ] && [ ! -L "$_d/.credentials.json" ]; then
        printf 'claude-profile: refusing to export "%s": .credentials.json is a real file\n' "$_n" >&2
        return 1
    fi
    _tmplist=$(mktemp)
    _cp_owned "$_d" > "$_tmplist"
    # No Python means no warning, same as before: the guard is best effort and
    # the archive is produced either way. See Security notes in the README.
    _ex_py=$(_cp_python) || _ex_py=''
    # shellcheck disable=SC2086 # deliberate: _cp_python may return "py -3"
    if [ -n "$_ex_py" ] && [ -f "$_d/settings.json" ] && $_ex_py -c 'import json,sys; sys.exit(0 if "env" in json.load(open(sys.argv[1])) else 1)' "$_d/settings.json" 2>/dev/null; then
        printf 'claude-profile: warning: "%s" settings.json has an "env" block; the archive will contain it\n' "$_n" >&2
    fi
    printf 'claude-profile: archiving:\n' >&2
    sed 's/^/  /' "$_tmplist" >&2
    # Remember whether $_out already existed: the redirect below truncates it
    # regardless (ordinary shell behaviour), but the failure path must not go
    # on to delete a file this tool did not create.
    [ -e "$_out" ] && _out_existed=1 || _out_existed=0
    ( cd "$_d" && tar czf - -T "$_tmplist" ) > "$_out"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmplist"
        [ "$_out_existed" -eq 0 ] && rm -f "$_out"
        printf 'claude-profile: failed to write archive "%s"\n' "$_out" >&2
        return 1
    fi
    rm -f "$_tmplist"
    printf 'exported %s -> %s\n' "$_n" "$_out"
}

_cp_cmd_import() {
    _f="$1"
    [ -f "$_f" ] || { printf 'claude-profile: no such file "%s"\n' "$_f" >&2; return 1; }
    _n="${2:-}"
    if [ -z "$_n" ]; then
        _n=$(basename "$_f")
        _n="${_n%.tar.gz}"
        _n="${_n%.tgz}"
    fi
    _cp_free "$_n" || return 1
    _d=$(_cp_dir "$_n")
    mkdir -p "$_d" || return 1
    # No explicit check here against "../" or absolute members in the archive:
    # containment relies on the tar binary's own behaviour (bsdtar and modern
    # GNU tar refuse to escape -C; unverified on older tar implementations).
    tar xzf "$_f" -C "$_d" || { rm -rf "$_d"; return 1; }
    # Relink every shared path that exists in base. Command substitution, not
    # a bare $_CP_SHARED: zsh does not word-split an unquoted parameter
    # expansion, so `for _b in $_CP_SHARED` runs once with the whole list as
    # one word under zsh (21 iterations under bash) — it does split command
    # substitution output, so that's what forces per-word iteration in both.
    for _b in $(printf '%s' "$_CP_SHARED"); do
        [ -e "$HOME/.claude/$_b" ] || continue
        rm -rf "${_d:?}/$_b" || { rm -rf "$_d"; return 1; }
        ln -s "$HOME/.claude/$_b" "$_d/$_b" || { rm -rf "$_d"; return 1; }
    done
    # The archive carries the exporting machine's profile paths. Rewrite any
    # absolute path ending in /profiles/<something>/ to this profile, then the
    # ~/.claude/ prefixes as usual.
    if [ -f "$_d/settings.json" ]; then
        _t="$_d/settings.json.tmp.$$"
        if ! sed -e "s#[^\"]*/profiles/[^\"/]*/#$_d/#g" "$_d/settings.json" > "$_t"; then
            rm -f "$_t"
            rm -rf "$_d"
            return 1
        fi
        mv "$_t" "$_d/settings.json" || { rm -f "$_t"; rm -rf "$_d"; return 1; }
        # Two arguments only: the sed above already retargeted the exporting
        # machine's profile paths, and there is no meaningful source dir here.
        _cp_rewrite "$_d/settings.json" "$_d" || { rm -rf "$_d"; return 1; }
    fi
    _cp_codex_ensure "$_n" || { rm -rf "$_d"; return 1; }
    printf 'imported %s <- %s\n' "$_n" "$_f"
}
