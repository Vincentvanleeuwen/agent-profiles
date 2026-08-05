# Building a profile directory from a config dir: copy, symlink the shared paths, rewrite embedded paths, carry over auth and prompt state.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e,
# and it assumes the other lib files are loaded (shell resolves function
# references at call time, so load order does not matter).

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
        # ${_dest:?} on every rm -rf: the mkdir -p above already fails on an
        # empty $_dest, but that guard is far enough away that it should not be
        # the only thing standing between a typo and "rm -rf /".
        rm -rf "${_dest:?}/$_b" || return 1
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
        rm -rf "${_dest:?}/$_b" || return 1
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
# ponytail: Python only; if it is missing you get the old re-login, not a break.
_cp_seed_auth() {
    _sa_dest="$1/.claude.json"
    _sa_base="$HOME/.claude.json"
    [ -f "$_sa_base" ] || return 0
    _sa_py=$(_cp_python) || return 0
    # shellcheck disable=SC2086 # deliberate: _cp_python may return "py -3"
    $_sa_py - "$_sa_dest" "$_sa_base" <<'EOF'
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
# ponytail: Python only; without it you get the old re-prompting, not a break.
# ponytail: no lock; a second session on the same profile can lose a flag,
# which costs one re-prompt. Add flock if that ever actually bites.
_cp_sync_prompts() {
    _sp_dir="$1"
    [ "$_sp_dir" = "$HOME/.claude" ] && return 0
    [ -f "$_sp_dir/.claude.json" ] || return 0
    _sp_py=$(_cp_python) || return 0
    # shellcheck disable=SC2086 # deliberate: _cp_python may return "py -3"
    $_sp_py - "$_sp_dir/.claude.json" "$(_cp_store)/prompt-state.json" \
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
