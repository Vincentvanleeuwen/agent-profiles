# claude-profile — switch Claude Code between named configuration profiles.
# Source this from ~/.zshrc or ~/.bashrc. POSIX sh; runs under zsh and bash.

# Path of this file when sourced. $BASH_SOURCE is set under bash; the zsh
# fallback ${(%):-%x} is only ever expanded when it is not, so bash never
# parses it as a value.
_CP_SELF="${BASH_SOURCE:-${(%):-%x}}"
_CP_HOME=$(cd "$(dirname "$_CP_SELF")" && pwd)

_cp_store() {
    if [ -n "${CLAUDE_PROFILES_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROFILES_DIR"
    else
        printf '%s' "$_CP_HOME"
    fi
}

_cp_read_name() {
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" 2>/dev/null | grep -m1 .
}

_cp_find_pin() {
    _d="$PWD"
    while : ; do
        if [ -f "$_d/.claude-profile" ]; then
            printf '%s' "$_d/.claude-profile"
            return 0
        fi
        [ "$_d" = "/" ] && return 1
        _d=$(dirname "$_d")
    done
}

# Prints the selected profile name (possibly empty). Sets _CP_SRC.
_cp_selected() {
    if [ -n "${CLAUDE_PROFILE:-}" ]; then
        _CP_SRC="env"
        printf '%s' "$CLAUDE_PROFILE"
        return 0
    fi
    _pin=$(_cp_find_pin) && {
        _name=$(_cp_read_name "$_pin")
        if [ -n "$_name" ]; then
            _CP_SRC="pin:$_pin"
            printf '%s' "$_name"
            return 0
        fi
    }
    if [ -f "$(_cp_store)/active" ]; then
        _name=$(_cp_read_name "$(_cp_store)/active")
        if [ -n "$_name" ]; then
            _CP_SRC="active"
            printf '%s' "$_name"
            return 0
        fi
    fi
    _CP_SRC="none"
    return 0
}

# Prints the config directory to use.
_cp_resolve() {
    _sel=$(_cp_selected)
    if [ -z "$_sel" ]; then
        printf '%s' "$HOME/.claude"
        return 0
    fi
    if [ -d "$(_cp_store)/profiles/$_sel" ]; then
        printf '%s' "$(_cp_store)/profiles/$_sel"
    else
        printf 'claude-profile: unknown profile "%s", using ~/.claude\n' "$_sel" >&2
        printf '%s' "$HOME/.claude"
    fi
}

# Leading and trailing spaces are required: matched with case " $x " in *" $b "*
_CP_SHARED=" plugins projects history.jsonl .credentials.json context-mode \
file-history cache sessions shell-snapshots backups telemetry tasks \
paste-cache debug downloads ide chrome session-env \
.session-stats.json stats-cache.json claude-devtools-notifications.json "
_CP_SKIP=" .DS_Store "

_cp_is_shared() { case "$_CP_SHARED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
_cp_is_skipped(){ case "$_CP_SKIP"   in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# _cp_rewrite SETTINGS_FILE PROFILE_DIR [SOURCE_DIR]
# Rewrites ~/.claude/ prefixes to PROFILE_DIR. When SOURCE_DIR is given and is
# not the base config dir, also rewrites SOURCE_DIR/ -> PROFILE_DIR/, which is
# what makes a profile forked from another profile point at itself.
_cp_rewrite() {
    _rf="$1"; _p="$2"; _rsrc="${3:-}"
    [ -f "$_rf" ] || return 0
    _t="$_rf.tmp.$$"
    if ! sed -e "s#$HOME/\.claude/#$_p/#g" \
             -e "s#\$HOME/\.claude/#$_p/#g" \
             -e "s#~/\.claude/#$_p/#g" \
             "$_rf" > "$_t"; then
        rm -f "$_t"
        return 1
    fi
    mv "$_t" "$_rf" || { rm -f "$_t"; return 1; }
    if [ -n "$_rsrc" ]; then
        if ! sed -e "s#$_rsrc/#$_p/#g" "$_rf" > "$_t"; then
            rm -f "$_t"
            return 1
        fi
        mv "$_t" "$_rf" || { rm -f "$_t"; return 1; }
    fi
    return 0
}

# Populate $2 as a profile built from config dir $1.
_cp_build() {
    _src="$1"; _dest="$2"
    mkdir -p "$_dest" || return 1
    [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_skipped "$_b" && continue
        _cp_is_shared "$_b" && continue
        rm -rf "$_dest/$_b" || return 1
        # -L dereferences: relative symlink copied as link would resolve
        # against profile directory and dangle. A profile is a snapshot,
        # so copy content by value.
        cp -RL "$_e" "$_dest/$_b" || return 1
    done
    # Shared paths are linked from whatever currently exists in base, not from
    # what happened to exist in $_src at this moment — a profile forked before
    # first login, or from another profile that itself never got one of these
    # (e.g. .credentials.json), must still pick it up here and on every later
    # --update, same as --import already does.
    for _b in $(printf '%s' "$_CP_SHARED"); do
        [ -e "$HOME/.claude/$_b" ] || continue
        rm -rf "$_dest/$_b" || return 1
        ln -s "$HOME/.claude/$_b" "$_dest/$_b" || return 1
    done
    _cp_rewrite "$_dest/settings.json" "$_dest" "$_src" || return 1
    _cp_seed_auth "$_dest"
    _cp_sync_prompts "$_dest"
    return 0
}

# .claude.json stays per-profile (it carries mcpServers and per-project history
# that must not leak between profiles), but the login identity inside it is not
# profile-specific: the OAuth token itself lives in the macOS keychain, shared.
# Two cases leave a profile with no identity and drop you on the login screen:
# a profile built from base ~/.claude, whose .claude.json lives at $HOME level
# and so is never seen by the copy loop above, and --reset, which builds from an
# empty directory on purpose. Seed just the identity keys back from base so the
# keychain token is actually usable. Never overwrites a profile that already has
# an account, and never touches anything else in the file.
# ponytail: python3 only; if it is missing you get the old re-login, not a break.
_cp_seed_auth() {
    _sa_dest="$1/.claude.json"
    _sa_base="$HOME/.claude.json"
    [ -f "$_sa_base" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$_sa_dest" "$_sa_base" <<'EOF'
import json, os, sys

dest_path, base_path = sys.argv[1], sys.argv[2]
KEYS = ("oauthAccount", "userID", "hasCompletedOnboarding", "lastOnboardingVersion")

def load(p):
    try:
        with open(p) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None

base = load(base_path)
if base is None or "oauthAccount" not in base:
    sys.exit(0)

dest = load(dest_path)
if dest is None:
    if os.path.exists(dest_path):
        sys.exit(0)  # unreadable or not an object: leave it alone
    dest = {}
elif "oauthAccount" in dest:
    sys.exit(0)  # profile already has an identity

for k in KEYS:
    if k in base:
        dest[k] = base[k]

tmp = dest_path + ".tmp"
try:
    with open(tmp, "w") as fh:
        json.dump(dest, fh, indent=2)
    os.replace(tmp, dest_path)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(0)
EOF
    return 0
}

# Per-project "you already answered this" state — the trust dialog, the
# CLAUDE.md external-include approval, project onboarding — lives inside
# .claude.json, which is per-profile on purpose (it also carries mcpServers and
# per-project prompt history that must not leak between profiles). Re-answering
# the same trust prompt in every profile is pure friction though, so union just
# those flags through a shared registry in the store. Base ~/.claude.json is
# read as a seed but never written: Claude Code rewrites it constantly and a
# read-modify-write from here would race a live session.
# Called before a session to pick up what other profiles trusted, and after it
# to publish what this one accepted. Only ever sets a flag, never clears one,
# so untrusting a folder still has to be redone per profile.
# ponytail: python3 only; without it you get the old re-prompting, not a break.
# ponytail: no lock; a second session on the same profile can lose a flag,
# which costs one re-prompt. Add flock if that ever actually bites.
_cp_sync_prompts() {
    _sp_dir="$1"
    [ "$_sp_dir" = "$HOME/.claude" ] && return 0
    [ -f "$_sp_dir/.claude.json" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$_sp_dir/.claude.json" "$(_cp_store)/prompt-state.json" \
             "$HOME/.claude.json" <<'EOF'
import json, os, sys

prof_path, reg_path, base_path = sys.argv[1:4]
KEYS = (
    "hasTrustDialogAccepted",
    "hasCompletedProjectOnboarding",
    "hasClaudeMdExternalIncludesApproved",
    "hasClaudeMdExternalIncludesWarningShown",
)

def load(p):
    try:
        with open(p) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}

def projects(d):
    p = d.get("projects")
    return p if isinstance(p, dict) else {}

prof = load(prof_path)
if not prof:
    sys.exit(0)  # unreadable or empty: never overwrite it blind
reg = load(reg_path)

merged = {}
for src in (load(base_path), reg, prof):
    for path, cfg in projects(src).items():
        if isinstance(cfg, dict):
            for k in KEYS:
                if cfg.get(k):
                    merged.setdefault(path, {})[k] = True

def write(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass

# Registry is stored in the same {"projects": {...}} shape as the files it
# merges, so one accessor reads all three.
if merged != projects(reg):
    write(reg_path, {"projects": merged})

prof_projects = projects(prof)
changed = False
for path, flags in merged.items():
    cfg = prof_projects.get(path)
    if not isinstance(cfg, dict):
        cfg = {}
        prof_projects[path] = cfg
    for k in flags:
        if not cfg.get(k):
            cfg[k] = True
            changed = True
if changed:
    prof["projects"] = prof_projects
    write(prof_path, prof)
EOF
    return 0
}

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

_cp_cmd_create() {
    _n="$1"
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    if _cp_exists "$_n"; then
        printf 'claude-profile: profile "%s" already exists\n' "$_n" >&2
        return 1
    fi
    _from=$(_cp_resolve) || return 1
    mkdir -p "$(_cp_store)/profiles"
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to build "%s"\n' "$_n" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'created %s <- %s\n' "$_n" "$_from"
}

_cp_cmd_set() {
    _n="$1"
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    if ! printf '%s\n' "$_n" > "$(_cp_store)/active"; then
        printf 'claude-profile: could not write %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: %s\n' "$_n"
}

_cp_cmd_default() {
    rm -f "$(_cp_store)/active" 2>/dev/null
    if [ -e "$(_cp_store)/active" ]; then
        printf 'claude-profile: could not remove %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: none (using ~/.claude)\n'
}

_cp_cmd_status() {
    _sel=$(_cp_selected)
    # $(...) is a subshell: _CP_SRC set inside _cp_selected above never reached
    # here. Re-run it directly (stdout discarded, already captured in _sel) so
    # _CP_SRC lands in this shell.
    _cp_selected >/dev/null
    if [ -z "$_sel" ]; then
        printf 'active: none (using ~/.claude)\n'
    else
        printf 'active: %s  (%s)\n' "$_sel" "$_CP_SRC"
    fi
    printf 'store: %s\n' "$(_cp_store)"
    printf 'profiles:\n'
    if [ -d "$(_cp_store)/profiles" ]; then
        [ -n "${ZSH_VERSION:-}" ] && setopt localoptions nonomatch
        for _p in "$(_cp_store)"/profiles/*; do
            [ -d "$_p" ] || continue
            printf '  %s\n' "${_p##*/}"
        done
    fi
}

_CP_RUNNER=${_CP_RUNNER:-}

_cp_run_claude() {
    if [ -n "$_CP_RUNNER" ]; then
        "$_CP_RUNNER" "$@"
    else
        command claude "$@"
    fi
}

# Single choke point for starting a session: pull shared prompt state in,
# run, push back whatever this session accepted.
_cp_launch() {
    _l_dir="$1"; shift
    _cp_sync_prompts "$_l_dir"
    CLAUDE_CONFIG_DIR="$_l_dir" _cp_run_claude "$@"
    _l_rc=$?
    _cp_sync_prompts "$_l_dir"
    return $_l_rc
}

_cp_cmd_run() {
    _n="$1"; shift
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    _cp_launch "$(_cp_dir "$_n")" "$@"
}

_cp_backup() {
    _n="$1"
    _stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$(_cp_store)/.backups" || return 1
    # Never write into an existing path: mv into an existing directory nests
    # inside it rather than failing, which would leave two generations stacked
    # with only the first reachable at the reported path.
    _dst="$(_cp_store)/.backups/$_n-$_stamp"
    _i=1
    while [ -e "$_dst" ]; do
        _dst="$(_cp_store)/.backups/$_n-$_stamp-$_i"
        _i=$((_i + 1))
    done
    mv "$(_cp_dir "$_n")" "$_dst" || return 1
    printf '%s' "$_dst"
}

_cp_cmd_update() {
    _n="$1"
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    _from=$(_cp_resolve)
    if [ "$_from" = "$(_cp_dir "$_n")" ]; then
        printf 'claude-profile: "%s" is the active source; switch away first\n' "$_n" >&2
        return 1
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not updating "%s"\n' "$_n" >&2
        return 1
    fi
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to rebuild "%s"; previous contents at %s\n' "$_n" "$_bk" >&2
        return 1
    fi
    printf 'backed up -> %s\n' "$_bk"
    printf 'updated %s <- %s\n' "$_n" "$_from"
}

# Wipe a profile back to a first-run ~/.claude: nothing profile-owned left, and
# shared paths still linked to base so you are not logged out. Building from an
# empty directory is exactly that, so there is no second teardown path to keep in
# sync with _cp_build. Never operates on ~/.claude itself.
_cp_cmd_reset() {
    _n="${1:-$(_cp_selected)}"
    if [ -z "$_n" ]; then
        printf 'claude-profile: no profile selected; --reset never touches ~/.claude\n' >&2
        return 1
    fi
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    # Confirm even though the old contents are backed up: --reset used to be an
    # alias for "default", so muscle memory aims it at a profile people meant to
    # only switch away from.
    if [ -z "${_CP_YES:-}" ]; then
        printf 'reset profile "%s" to a fresh ~/.claude? type the name to confirm: ' "$_n"
        read -r _answer
        if [ "$_answer" != "$_n" ]; then
            printf 'cancelled\n'
            return 1
        fi
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not resetting "%s"\n' "$_n" >&2
        return 1
    fi
    _empty=$(mktemp -d) || return 1
    if ! _cp_build "$_empty" "$(_cp_dir "$_n")"; then
        rmdir "$_empty"
        printf 'claude-profile: failed to reset "%s"; previous contents at %s\n' "$_n" "$_bk" >&2
        return 1
    fi
    rmdir "$_empty"
    printf 'backed up -> %s\n' "$_bk"
    printf 'reset %s (fresh config; shared paths still linked to base)\n' "$_n"
}

_cp_cmd_delete() {
    _n="$1"
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    if [ "$(_cp_selected)" = "$_n" ]; then
        printf 'claude-profile: "%s" is active; run "claude profile default" first\n' "$_n" >&2
        return 1
    fi
    if [ -z "${_CP_YES:-}" ]; then
        printf 'delete profile "%s"? type the name to confirm: ' "$_n"
        read -r _answer
        if [ "$_answer" != "$_n" ]; then
            printf 'cancelled\n'
            return 1
        fi
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not deleting "%s"\n' "$_n" >&2
        return 1
    fi
    # $CLAUDE_PROFILE or a pin can outrank active, so the deleted profile can
    # be named in active without being the selected one — clear the dangling
    # pointer rather than warn on every invocation forever, same as rename.
    if [ "$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)" = "$_n" ]; then
        rm -f "$(_cp_store)/active"
    fi
    printf 'deleted %s (kept at %s)\n' "$_n" "$_bk"
}

_cp_cmd_rename() {
    _o="$1"; _n="$2"
    _cp_exists "$_o" || { printf 'claude-profile: no such profile "%s"\n' "$_o" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! mv "$(_cp_dir "$_o")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: rename failed\n' >&2
        return 1
    fi
    # Third argument is the OLD profile dir: after the mv, settings.json still
    # carries the old profile's paths, and that pass is what retargets them.
    if ! _cp_rewrite "$(_cp_dir "$_n")/settings.json" "$(_cp_dir "$_n")" "$(_cp_dir "$_o")"; then
        printf 'claude-profile: renamed to "%s" but path rewrite failed; fix settings.json paths manually\n' "$_n" >&2
        return 1
    fi
    if [ "$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)" = "$_o" ]; then
        printf '%s\n' "$_n" > "$(_cp_store)/active"
    fi
    printf 'renamed %s -> %s\n' "$_o" "$_n"
}

_cp_cmd_copy() {
    _s="$1"; _n="$2"
    _cp_exists "$_s" || { printf 'claude-profile: no such profile "%s"\n' "$_s" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! _cp_build "$(_cp_dir "$_s")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to copy "%s"\n' "$_s" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'copied %s -> %s\n' "$_s" "$_n"
}

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
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    printf '%s\n' "$_n"
    _cp_summary "$(_cp_dir "$_n")"
}

_cp_cmd_diff() {
    _a="$1"; _b="$2"
    _cp_exists "$_a" || { printf 'claude-profile: no such profile "%s"\n' "$_a" >&2; return 1; }
    _cp_exists "$_b" || { printf 'claude-profile: no such profile "%s"\n' "$_b" >&2; return 1; }
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
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    _out="${2:-./$_n.tar.gz}"
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
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
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
        rm -rf "$_d/$_b" || { rm -rf "$_d"; return 1; }
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

claude profile --export <name> [f]   write a shareable tarball (no credentials)
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
