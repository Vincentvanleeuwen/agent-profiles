#!/bin/sh
# Test harness for claude-profile.sh
# Runs against a temporary store and a temporary fake home.

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
no()   { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fake base config dir, shaped like a real ~/.claude
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME/.claude/hooks" "$FAKEHOME/.claude/skills/demo" \
         "$FAKEHOME/.claude/plugins/cache" "$FAKEHOME/.claude/projects"
printf 'echo hook\n' > "$FAKEHOME/.claude/hooks/demo.sh"
printf 'name: demo\n'  > "$FAKEHOME/.claude/skills/demo/SKILL.md"
printf 'base instructions\n' > "$FAKEHOME/.claude/CLAUDE.md"
printf 'secret\n' > "$FAKEHOME/.claude/.credentials.json"
printf 'history\n'  > "$FAKEHOME/.claude/history.jsonl"
cat > "$FAKEHOME/.claude/settings.json" <<JSON
{
  "model": "opus-5",
  "enabledPlugins": { "alpha@m": true, "beta@m": false },
  "statusLine": { "type": "command", "command": "$FAKEHOME/.claude/statusline.sh" },
  "hooks": {
    "SessionStart": [
      { "hooks": [
          { "type": "command", "command": "$FAKEHOME/.claude/hooks/demo.sh" },
          { "type": "command", "command": "$FAKEHOME/.claude/hooks/demo.sh" }
        ] }
    ]
  },
  "env": { "TOOL": "$FAKEHOME/.local/bin/tool" }
}
JSON
printf 'printf hud\n' > "$FAKEHOME/.claude/statusline.sh"
cat > "$FAKEHOME/.claude/.claude.json" <<JSON
{ "mcpServers": { "figma": {}, "atlassian": {} } }
JSON

HOME="$FAKEHOME"
export HOME
CLAUDE_PROFILES_DIR="$TMP/store"
export CLAUDE_PROFILES_DIR
mkdir -p "$CLAUDE_PROFILES_DIR"

. "$HERE/claude-profile.sh"
_cp_test_runner() { printf 'CFG=%s ARGS=%s\n' "$CLAUDE_CONFIG_DIR" "$*"; }

echo "== Task 1: resolution =="

eq "store honours CLAUDE_PROFILES_DIR" "$(_cp_store)" "$TMP/store"

mkdir -p "$TMP/store/profiles/dev"
printf 'dev\n' > "$TMP/store/active"
eq "active file selects profile" "$(_cp_selected)" "dev"
# $(...) runs in a subshell, so _CP_SRC set inside it never reaches here —
# call directly (as below for pin/env) to read the real value.
_cp_selected >/dev/null
eq "source is active" "$_CP_SRC" "active"
eq "resolve returns profile dir" "$(_cp_resolve)" "$TMP/store/profiles/dev"

mkdir -p "$TMP/repo/nested/deep"
printf 'fin  # inline comment\n' > "$TMP/repo/.claude-profile"
mkdir -p "$TMP/store/profiles/fin"
# Never call eq inside ( ... ): the subshell discards the fails counter, so a
# broken assertion prints FAIL and the suite still exits 0. Capture in the
# subshell, assert outside it.
got=$(cd "$TMP/repo/nested/deep" && _cp_selected)
eq "pin beats active" "$got" "fin"
got=$(cd "$TMP/repo/nested/deep" && CLAUDE_PROFILE=other _cp_selected)
eq "env beats pin" "$got" "other"

printf 'ghost\n' > "$TMP/store/active"
eq "unknown profile falls back to base" "$(_cp_resolve 2>/dev/null)" "$FAKEHOME/.claude"
check "unknown profile warns on stderr" '[ -n "$(_cp_resolve 2>&1 >/dev/null)" ]'

rm -f "$TMP/store/active"
eq "no active resolves to base" "$(_cp_resolve)" "$FAKEHOME/.claude"
_cp_selected >/dev/null
eq "no active has source none" "$_CP_SRC" "none"

echo "== Task 2: build =="

_cp_build "$FAKEHOME/.claude" "$TMP/store/profiles/built"
B="$TMP/store/profiles/built"

check "settings.json is a real file"   '[ -f "$B/settings.json" ] && [ ! -L "$B/settings.json" ]'
check "skills copied as real dir"      '[ -d "$B/skills/demo" ] && [ ! -L "$B/skills" ]'
check "CLAUDE.md copied"               '[ -f "$B/CLAUDE.md" ]'
check "hooks copied as real dir"       '[ -d "$B/hooks" ] && [ ! -L "$B/hooks" ]'
check "plugins symlinked"              '[ -L "$B/plugins" ]'
check "projects symlinked"             '[ -L "$B/projects" ]'
check "credentials symlinked"          '[ -L "$B/.credentials.json" ]'
check "history symlinked"              '[ -L "$B/history.jsonl" ]'
eq    "symlink points at base"         "$(readlink "$B/plugins")" "$FAKEHOME/.claude/plugins"

check "hook path rewritten to profile" 'grep -q "$B/hooks/demo.sh" "$B/settings.json"'
check "statusline path rewritten"      'grep -q "$B/statusline.sh" "$B/settings.json"'
check "no base config paths remain"    '! grep -q "$FAKEHOME/.claude/" "$B/settings.json"'
check "non-config abs path preserved"  'grep -q "$FAKEHOME/.local/bin/tool" "$B/settings.json"'
check "settings.json still valid json" 'python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$B/settings.json"'

printf 'x\n' > "$FAKEHOME/.claude/.DS_Store"
_cp_build "$FAKEHOME/.claude" "$TMP/store/profiles/built2"
check "DS_Store skipped" '[ ! -e "$TMP/store/profiles/built2/.DS_Store" ]'

# Building from a profile must still link shared paths to base, not chain.
_cp_build "$B" "$TMP/store/profiles/forked"
eq "fork links to base not source" \
   "$(readlink "$TMP/store/profiles/forked/plugins")" "$FAKEHOME/.claude/plugins"
check "fork rewrote paths to itself" \
   'grep -q "$TMP/store/profiles/forked/hooks/demo.sh" "$TMP/store/profiles/forked/settings.json"'

# Regression: _cp_rewrite used to read $_src, a global _cp_build leaves set
# after it returns (no `local` in POSIX sh). Call it directly with only 2
# args on an unrelated file and confirm the stale global is never consulted.
OTHER="$TMP/store/other-settings.json"
printf '{"path": "%s/leftover"}\n' "$TMP/store/profiles/built" > "$OTHER"
_cp_rewrite "$OTHER" "$TMP/store/profiles/unrelated"
check "_cp_rewrite ignores stale global _src" \
   'grep -q "$TMP/store/profiles/built/leftover" "$OTHER"'

echo "== Task 3: create and activate =="

rm -rf "$TMP/store/profiles" "$TMP/store/active"
mkdir -p "$TMP/store/profiles"

_cp_main --create dev >/dev/null
check "create makes profile dir"  '[ -d "$TMP/store/profiles/dev" ]'
check "create built settings"     '[ -f "$TMP/store/profiles/dev/settings.json" ]'
check "create is not active yet"  '[ ! -f "$TMP/store/active" ]'

_cp_main --create dev >/dev/null 2>&1
eq "create refuses duplicate" "$?" "1"

_cp_main dev >/dev/null
eq "set writes active"   "$(cat "$TMP/store/active")" "dev"
eq "resolve follows it"  "$(_cp_resolve)" "$TMP/store/profiles/dev"

# Creating while a profile is active forks from that profile.
printf 'dev only\n' > "$TMP/store/profiles/dev/MARKER.md"
_cp_main --create fin >/dev/null
check "create forks from active" '[ -f "$TMP/store/profiles/fin/MARKER.md" ]'

_cp_main default >/dev/null
check "default clears active" '[ ! -f "$TMP/store/active" ]'
eq    "default falls back"    "$(_cp_resolve)" "$FAKEHOME/.claude"

_cp_main --reset >/dev/null
check "--reset is an alias for default" '[ ! -f "$TMP/store/active" ]'

_cp_main unknown-name >/dev/null 2>&1
eq "set refuses unknown profile" "$?" "1"
check "refused set left active alone" '[ ! -f "$TMP/store/active" ]'

check "status lists profiles" '_cp_main | grep -q dev'
_cp_main dev >/dev/null
check "status names active"   '_cp_main | grep -q "active: dev"'
# Regression: _cp_cmd_status read $_CP_SRC after $(_cp_selected), a subshell —
# the assignment inside never reached the caller, so this used to pass only
# because the literal word "active:" is always in the format string, not
# because the source was actually reported. Assert the parenthesised value.
check "status names source"   '_cp_main | grep -q "(active)"'

# _cp_valid_name rejection paths reach _cp_cmd_create unfiltered: _cp_main only
# inspects $1, and --create) shift; _cp_cmd_create "$@" passes the next arg
# through untouched. Confirm each rejected name is both a non-zero exit and
# leaves the profile set exactly as it was (count, not just one guessed path).
before=$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)

_cp_main --create -foo >/dev/null 2>&1
eq "create rejects leading-dash name" "$?" "1"
eq "leading-dash name made no dir" "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$before"

_cp_main --create ../../evil >/dev/null 2>&1
eq "create rejects path traversal" "$?" "1"
check "path traversal escaped nowhere" '[ ! -e "$TMP/evil" ] && [ ! -e "$HOME/evil" ]'
eq "path traversal made no dir" "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$before"

_cp_main --create "" >/dev/null 2>&1
eq "create rejects empty name" "$?" "1"
eq "empty name made no dir" "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$before"

# Write guards on an unwritable store. chmod cannot deny root, so the
# assertion would pass for the wrong reason under a root-run CI — skip
# explicitly rather than assert something chmod never enforced.
if [ "$(id -u)" -eq 0 ]; then
    printf '  skip write-guard tests (running as root, chmod cannot deny)\n'
else
    _cp_main default >/dev/null
    chmod 555 "$TMP/store"
    _cp_main dev >/dev/null 2>&1
    eq "set fails loudly on unwritable store" "$?" "1"
    check "set wrote nothing" '[ ! -f "$TMP/store/active" ]'
    chmod 755 "$TMP/store"

    _cp_main dev >/dev/null
    chmod 555 "$TMP/store"
    _cp_main default >/dev/null 2>&1
    eq "default fails loudly on unwritable store" "$?" "1"
    eq "default left previous active intact" "$(cat "$TMP/store/active")" "dev"
    chmod 755 "$TMP/store"

    # A failed backup must abort before _cp_build ever touches the profile —
    # the backup is the only rollback this tool has, so a false "backed up"
    # immediately preceding an overwrite is the worst lie it can tell.
    mkdir -p "$TMP/store/.backups"
    chmod 555 "$TMP/store/.backups"
    _cp_main dev >/dev/null
    out=$(_cp_main --update fin 2>&1)
    eq "update fails loudly on unwritable backups dir" "$?" "1"
    check "update backup failure errors on stderr" 'printf "%s" "$out" | grep -q "backup failed"'
    check "failed backup left profile untouched" '[ -f "$TMP/store/profiles/fin/CLAUDE.md" ]'
    chmod 755 "$TMP/store/.backups"

    # Task 5b: a failed copy/rewrite mid-_cp_build must fail the whole
    # build, not silently report success with a half-populated profile.
    chmod 000 "$FAKEHOME/.claude/skills/demo/SKILL.md"
    _cp_main default >/dev/null
    _cp_main --create propfail >/dev/null 2>&1
    eq "create fails loudly when copy fails" "$?" "1"
    check "create removed the partial profile" '[ ! -d "$TMP/store/profiles/propfail" ]'
    chmod 644 "$FAKEHOME/.claude/skills/demo/SKILL.md"

    _cp_main dev >/dev/null
    chmod 000 "$TMP/store/profiles/dev/skills/demo/SKILL.md"
    out=$(_cp_main --update fin 2>&1)
    eq "update fails loudly when rebuild fails" "$?" "1"
    check "update failure names the backup path" 'printf "%s" "$out" | grep -q "previous contents at"'
    check "update backup still exists after failed rebuild" 'ls -d "$TMP/store/.backups/fin-"* >/dev/null 2>&1'
    chmod 644 "$TMP/store/profiles/dev/skills/demo/SKILL.md"
    # Clean up so later glob-based backup checks (Task 5) only see their own backup.
    rm -rf "$TMP/store/.backups"/fin-*

    mkdir -p "$TMP/rwtest"
    printf '{"a":"%s/.claude/x"}' "$HOME" > "$TMP/rwtest/settings.json"
    chmod 555 "$TMP/rwtest"
    _cp_rewrite "$TMP/rwtest/settings.json" "$TMP/store/profiles/dev" 2>/dev/null
    eq "rewrite fails when it cannot write" "$?" "1"
    chmod 755 "$TMP/rwtest"
    rm -rf "$TMP/rwtest"

    check "no temp files left behind" '[ -z "$(find "$TMP/store/profiles" -name "*.tmp.*" 2>/dev/null)" ]'
fi

echo "== Task 4: one-shot run =="

_cp_main dev >/dev/null

out=$(_CP_RUNNER='_cp_test_runner' _cp_main fin -- --version 2>&1)
eq "one-shot used fin dir" "$out" "CFG=$TMP/store/profiles/fin ARGS=--version"
eq "active unchanged after one-shot" "$(cat "$TMP/store/active")" "dev"

out=$(_CP_RUNNER='_cp_test_runner' _cp_main ghost -- --version 2>&1)
check "one-shot on unknown profile errors" 'printf "%s" "$out" | grep -q "no such profile"'
unset _CP_RUNNER

echo "== Task 5: update =="

_cp_main default >/dev/null
printf 'tuned by hand\n' > "$TMP/store/profiles/fin/LOCAL.md"
rm -f "$TMP/store/profiles/fin/CLAUDE.md"

_cp_main --update fin >/dev/null
check "update restored file from source" '[ -f "$TMP/store/profiles/fin/CLAUDE.md" ]'
check "update removed profile-only file" '[ ! -f "$TMP/store/profiles/fin/LOCAL.md" ]'
check "update made a backup"             'ls -d "$TMP/store/.backups/fin-"* >/dev/null 2>&1'
check "backup kept the removed file"     'cat "$TMP/store/.backups/fin-"*/LOCAL.md >/dev/null 2>&1'
check "update relinked shared paths"     '[ -L "$TMP/store/profiles/fin/plugins" ]'
check "update rewrote settings paths"    'grep -q "$TMP/store/profiles/fin/hooks/demo.sh" "$TMP/store/profiles/fin/settings.json"'

_cp_main --update ghost >/dev/null 2>&1
eq "update refuses unknown profile" "$?" "1"

_cp_main fin >/dev/null
_cp_main --update fin >/dev/null 2>&1
eq "update refuses self as source" "$?" "1"
check "self-update left profile intact" '[ -f "$TMP/store/profiles/fin/settings.json" ]'
_cp_main default >/dev/null

echo "== Task 6: delete, rename, copy =="

_cp_main --create tmp1 >/dev/null
_CP_YES=1 _cp_main --delete tmp1 >/dev/null
# _CP_YES prefixed on a shell function (unlike an external command) leaks
# into the rest of this script, same as _CP_RUNNER above — unset it so later
# deletes still exercise the stdin confirmation prompt.
unset _CP_YES
check "delete removes profile"  '[ ! -d "$TMP/store/profiles/tmp1" ]'
check "delete backs up"         'ls -d "$TMP/store/.backups/tmp1-"* >/dev/null 2>&1'

_cp_main --create tmp2 >/dev/null
_cp_main tmp2 >/dev/null
_CP_YES=1 _cp_main --delete tmp2 >/dev/null 2>&1
eq "delete refuses active profile" "$?" "1"
unset _CP_YES
check "active profile survived"    '[ -d "$TMP/store/profiles/tmp2" ]'
_cp_main default >/dev/null

printf 'no\n' | _cp_main --delete tmp2 >/dev/null 2>&1
check "delete without confirmation keeps profile" '[ -d "$TMP/store/profiles/tmp2" ]'

# Pair with proof the stdin-confirmation path actually deletes, so the check
# above cannot pass vacuously against a delete that is entirely broken/no-op.
_cp_main --create tmp2b >/dev/null
printf 'tmp2b\n' | _cp_main --delete tmp2b >/dev/null 2>&1
check "delete with typed confirmation removes profile" '[ ! -d "$TMP/store/profiles/tmp2b" ]'

_cp_main --rename tmp2 tmp3 >/dev/null
check "rename moved dir"     '[ -d "$TMP/store/profiles/tmp3" ] && [ ! -d "$TMP/store/profiles/tmp2" ]'
check "rename fixed paths"   'grep -q "$TMP/store/profiles/tmp3/hooks/demo.sh" "$TMP/store/profiles/tmp3/settings.json"'

_cp_main --copy tmp3 tmp4 >/dev/null
check "copy made a new dir"  '[ -d "$TMP/store/profiles/tmp4" ]'
check "copy fixed paths"     'grep -q "$TMP/store/profiles/tmp4/hooks/demo.sh" "$TMP/store/profiles/tmp4/settings.json"'
check "copy kept symlinks"   '[ -L "$TMP/store/profiles/tmp4/plugins" ]'
eq    "copy symlink to base" "$(readlink "$TMP/store/profiles/tmp4/plugins")" "$FAKEHOME/.claude/plugins"

_cp_main --copy tmp3 tmp4 >/dev/null 2>&1
eq "copy refuses existing target" "$?" "1"

_CP_YES=1 _cp_main --delete tmp3 >/dev/null
_CP_YES=1 _cp_main --delete tmp4 >/dev/null
unset _CP_YES

echo "== Task 7: show and diff =="

out=$(_cp_main --show dev)
check "show reports model"          'printf "%s" "$out" | grep -q "model .*opus-5"'
check "show lists enabled plugin"   'printf "%s" "$out" | grep -q "alpha@m"'
check "show omits disabled plugin"  '! printf "%s" "$out" | grep -q "beta@m"'
check "show lists skills"           'printf "%s" "$out" | grep -q "demo"'
check "show counts hooks"           'printf "%s" "$out" | grep -q "hooks .*2"'
check "show lists mcp servers"      'printf "%s" "$out" | grep -q "figma" && printf "%s" "$out" | grep -q "atlassian"'

python3 - "$TMP/store/profiles/fin/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["model"] = "haiku-4-5"
d["enabledPlugins"] = {"alpha@m": False, "beta@m": True}
json.dump(d, open(p, "w"), indent=2)
PY
rm -rf "$TMP/store/profiles/fin/skills/demo"

out=$(_cp_main --diff dev fin)
check "diff shows both models"  'printf "%s" "$out" | grep -q "opus-5" && printf "%s" "$out" | grep -q "haiku-4-5"'
check "diff shows plugin delta" 'printf "%s" "$out" | grep -q "alpha@m"'

_cp_main --show ghost >/dev/null 2>&1
eq "show refuses unknown profile" "$?" "1"

echo "== Task 8: export and import =="

_experr=$(_cp_main --export dev "$TMP/dev.tar.gz" 2>&1 >/dev/null)
check "export wrote archive" '[ -s "$TMP/dev.tar.gz" ]'
check "archive has settings" 'tar tzf "$TMP/dev.tar.gz" | grep -q "settings.json"'
check "archive has skills"   'tar tzf "$TMP/dev.tar.gz" | grep -q "skills/demo"'
check "archive omits credentials" '! tar tzf "$TMP/dev.tar.gz" | grep -q "credentials"'
check "archive omits plugins"     '! tar tzf "$TMP/dev.tar.gz" | grep -q "^plugins"'
check "archive omits projects"    '! tar tzf "$TMP/dev.tar.gz" | grep -q "^projects"'
# dev's settings.json carries a top-level "env" block (see fake home setup).
check "export warns about env block" 'printf "%s" "$_experr" | grep -q "env"'
check "export manifest lists a known entry" 'printf "%s" "$_experr" | grep -q "settings.json"'

_impout=$(_cp_main --import "$TMP/dev.tar.gz" imported)
check "import created profile"    '[ -d "$TMP/store/profiles/imported" ]'
check "import relinked plugins"   '[ -L "$TMP/store/profiles/imported/plugins" ]'
check "import relinked creds"     '[ -L "$TMP/store/profiles/imported/.credentials.json" ]'
check "import rewrote paths"      'grep -q "$TMP/store/profiles/imported/hooks/demo.sh" "$TMP/store/profiles/imported/settings.json"'
check "import left no dev paths"  '! grep -q "profiles/dev/" "$TMP/store/profiles/imported/settings.json"'
# Regression: _cp_rewrite used to assign its own _f, clobbering the caller's
# _f (the archive path) in _cp_cmd_import — the message named settings.json
# instead of the tarball.
eq "import message names archive, not settings.json" "$_impout" "imported imported <- $TMP/dev.tar.gz"

_cp_main --import "$TMP/dev.tar.gz" imported >/dev/null 2>&1
eq "import refuses existing name" "$?" "1"

# A profile carrying a real credentials file must never be exported.
_cp_main --create leaky >/dev/null
rm -f "$TMP/store/profiles/leaky/.credentials.json"
printf 'token\n' > "$TMP/store/profiles/leaky/.credentials.json"
_cp_main --export leaky "$TMP/leaky.tar.gz" >/dev/null 2>&1
eq "export refuses real credentials file" "$?" "1"
check "no archive written" '[ ! -e "$TMP/leaky.tar.gz" ]'
_CP_YES=1 _cp_main --delete leaky >/dev/null
_CP_YES=1 _cp_main --delete imported >/dev/null

echo "== Task 9: statusline =="

# Uninstalling a block that was never installed must be a harmless no-op,
# not a false "removed" message, and must not touch the file.
_slorig=$(cat "$FAKEHOME/.claude/statusline.sh")
_cp_main --uninstall-statusline >/dev/null 2>&1
eq "uninstall on pristine file is a no-op" "$?" "0"
eq "pristine file untouched" "$(cat "$FAKEHOME/.claude/statusline.sh")" "$_slorig"

# A hand-truncated end marker leaves the range unbalanced. sed's
# /start/,/end/d with no matching end deletes to EOF — must refuse instead.
printf '\n# CLAUDE_PROFILE_BLOCK start\nunterminated block content\n' >> "$FAKEHOME/.claude/statusline.sh"
_cp_main --uninstall-statusline >/dev/null 2>&1
eq "uninstall refuses unbalanced markers" "$?" "1"
check "unbalanced file left untouched" 'grep -q "unterminated block content" "$FAKEHOME/.claude/statusline.sh"'
printf '%s\n' "$_slorig" > "$FAKEHOME/.claude/statusline.sh"

_cp_main --install-statusline >/dev/null
check "statusline backed up"  '[ -f "$FAKEHOME/.claude/statusline.sh.bak" ]'
check "block installed"       'grep -q "CLAUDE_PROFILE_BLOCK start" "$FAKEHOME/.claude/statusline.sh"'
check "original preserved"    'grep -q "printf hud" "$FAKEHOME/.claude/statusline.sh"'

_cp_main --install-statusline >/dev/null
eq "install is idempotent" \
   "$(grep -c 'CLAUDE_PROFILE_BLOCK start' "$FAKEHOME/.claude/statusline.sh")" "1"

out=$(CLAUDE_CONFIG_DIR="$TMP/store/profiles/dev" sh "$FAKEHOME/.claude/statusline.sh")
check "statusline shows profile" 'printf "%s" "$out" | grep -q "\[dev\]"'

out=$(sh "$FAKEHOME/.claude/statusline.sh")
check "statusline silent without profile" '! printf "%s" "$out" | grep -q "\["'

_cp_main --uninstall-statusline >/dev/null
check "block removed"      '! grep -q "CLAUDE_PROFILE_BLOCK" "$FAKEHOME/.claude/statusline.sh"'
check "original still there" 'grep -q "printf hud" "$FAKEHOME/.claude/statusline.sh"'

# A second install must never clobber the first backup — it holds the true
# pre-block original, which is the most valuable thing to preserve.
printf 'hand edited after uninstall\n' >> "$FAKEHOME/.claude/statusline.sh"
_cp_main --install-statusline >/dev/null
eq "first backup still holds the true original" \
   "$(cat "$FAKEHOME/.claude/statusline.sh.bak")" "$_slorig"
_bakcount=$(ls "$FAKEHOME"/.claude/statusline.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
eq "timestamped sibling backup created" "$_bakcount" "1"
check "timestamped sibling holds the edited state" \
  'grep -q "hand edited after uninstall" "$FAKEHOME"/.claude/statusline.sh.bak.*'
rm -f "$FAKEHOME"/.claude/statusline.sh.bak.*
_cp_main --uninstall-statusline >/dev/null

# Two backups landing in the same wall-clock second must not collide either —
# the timestamped sibling name needs its own uniqueness check.
date() { printf '%s\n' "20260101-000000"; }
printf 'stub original\n' > "$FAKEHOME/.claude/statusline.sh"
cp "$FAKEHOME/.claude/statusline.sh" "$FAKEHOME/.claude/statusline.sh.bak"
printf 'edit one\n' > "$FAKEHOME/.claude/statusline.sh"
_cp_backup_statusline "$FAKEHOME/.claude/statusline.sh" >/dev/null 2>&1
printf 'edit two\n' > "$FAKEHOME/.claude/statusline.sh"
_cp_backup_statusline "$FAKEHOME/.claude/statusline.sh" >/dev/null 2>&1
unset -f date
check "same-second sibling one exists" '[ -e "$FAKEHOME/.claude/statusline.sh.bak.20260101-000000" ]'
check "same-second sibling two exists" '[ -e "$FAKEHOME/.claude/statusline.sh.bak.20260101-000000-1" ]'
check "sibling one holds edit one" 'grep -q "edit one" "$FAKEHOME/.claude/statusline.sh.bak.20260101-000000"'
check "sibling two holds edit two" 'grep -q "edit two" "$FAKEHOME/.claude/statusline.sh.bak.20260101-000000-1"'
rm -f "$FAKEHOME"/.claude/statusline.sh.bak*
printf '%s\n' "$_slorig" > "$FAKEHOME/.claude/statusline.sh"

# A profile created before install must NOT carry the block — the contrast
# that proves inherit-after-install isn't just always-present.
_cp_main --create noblock >/dev/null
check "profile created before install has no block" \
  '! grep -q "CLAUDE_PROFILE_BLOCK" "$TMP/store/profiles/noblock/statusline.sh"'
_CP_YES=1 _cp_main --delete noblock >/dev/null

# A profile created after install inherits the block through the normal copy.
_cp_main --install-statusline >/dev/null
_cp_main --create sl >/dev/null
check "new profile inherits block" 'grep -q "CLAUDE_PROFILE_BLOCK" "$TMP/store/profiles/sl/statusline.sh"'
_CP_YES=1 _cp_main --delete sl >/dev/null
_cp_main --uninstall-statusline >/dev/null

echo "== Task 5c: backup collision =="

_cp_main --create colla >/dev/null
printf 'gen1\n' > "$TMP/store/profiles/colla/GEN.md"

# Force both backups into the same timestamp.
date() { printf '20260101-000000\n'; }

bk1=$(_cp_backup colla)
_cp_main --create colla >/dev/null
printf 'gen2\n' > "$TMP/store/profiles/colla/GEN.md"
bk2=$(_cp_backup colla)

unset -f date

check "collision produced two distinct paths" '[ "$bk1" != "$bk2" ]'
check "first backup holds gen1"  'grep -q gen1 "$bk1/GEN.md"'
check "second backup holds gen2" 'grep -q gen2 "$bk2/GEN.md"'
check "no nesting inside first backup" '[ ! -d "$bk1/colla" ]'

echo "== Task 10: portability and help =="

check "sourceable under dash if present" \
  '{ command -v dash >/dev/null 2>&1 && dash -n "$HERE/claude-profile.sh"; } || true'
check "parses under bash"  'bash -n "$HERE/claude-profile.sh"'
check "parses under zsh"   '{ command -v zsh >/dev/null 2>&1 && zsh -n "$HERE/claude-profile.sh"; } || true'
# Excludes POSIX character classes like [[:space:]] ("[[" followed by ":"),
# which are legitimate sh and not the bash [[ ]] test bashism.
check "no bashisms: no [[" '! grep -qE "\[\[[^:]" "$HERE/claude-profile.sh"'
check "no bashisms: no arrays" '! grep -qE "^[[:space:]]*[A-Za-z_]+=\(" "$HERE/claude-profile.sh"'
check "no hardcoded home"  '! grep -q "/Users/" "$HERE/claude-profile.sh"'

check "help lists create" '_cp_main --help | grep -q -- "--create"'
check "help lists export" '_cp_main --help | grep -q -- "--export"'
check "status names the store path" '_cp_main | grep -q "^store: "'
check "README exists"     '[ -f "$HERE/README.md" ]'
check "README warns about profiles being ignored" 'grep -q "gitignore" "$HERE/README.md"'

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
