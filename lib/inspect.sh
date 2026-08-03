# Commands that report on or move profiles: show, diff, export, import.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

_cp_summary() {
    _d="$1"
    python3 - "$_d" <<'PY'
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

_cp_cmd_show() {
    _n="$1"
    _cp_need "$_n" || return 1
    printf '%s\n' "$_n"
    _cp_summary "$(_cp_dir "$_n")"
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
    if [ -f "$_d/settings.json" ] && python3 -c 'import json,sys; sys.exit(0 if "env" in json.load(open(sys.argv[1])) else 1)' "$_d/settings.json" 2>/dev/null; then
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
    printf 'imported %s <- %s\n' "$_n" "$_f"
}
