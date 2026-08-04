#!/bin/sh
# Test harness for claude-profile.sh
# Runs against a temporary store and a temporary fake home.

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
no()   { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
skip() { printf '  skip %s (%s not installed)\n' "$1" "$2"; }

# check_with LABEL TOOL EXPR — a check that is skipped when TOOL is absent.
# The old idiom here was `{ command -v tool && tool ...; } || true`, which also
# swallowed a real failure: a genuine parse error reported "ok". Only a missing
# tool may skip; anything else has to fail.
check_with() {
    if command -v "$2" >/dev/null 2>&1; then check "$1" "$3"; else skip "$1" "$2"; fi
}

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
# The suite asserts on the unset case (statusline "[default]"), so an inherited
# CLAUDE_CONFIG_DIR — which is exactly what you have when you run the tests from
# inside a profile — must not leak in.
unset CLAUDE_CONFIG_DIR CLAUDE_PROFILE
CLAUDE_PROFILES_DIR="$TMP/store"
export CLAUDE_PROFILES_DIR
mkdir -p "$CLAUDE_PROFILES_DIR"

. "$HERE/claude-profile.sh"
_cp_test_runner() { printf 'CFG=%s ARGS=%s\n' "$CLAUDE_CONFIG_DIR" "$*"; }

echo "== Task 1: resolution =="

eq "store honours CLAUDE_PROFILES_DIR" "$(_cp_store)" "$TMP/store"

got=$(unset CLAUDE_PROFILES_DIR; _cp_store)
eq "store defaults under HOME" "$got" "$FAKEHOME/.claude-profiles"

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

# --reset wipes the profile's own config but keeps it existing, active, and
# linked to base. It is no longer an alias for "default".
_cp_main --copy dev wipeme >/dev/null
_cp_main wipeme >/dev/null
printf 'x\n' > "$TMP/store/profiles/wipeme/CLAUDE.md"
_CP_YES=1 _cp_main --reset >/dev/null
check "--reset keeps the profile"      '[ -d "$TMP/store/profiles/wipeme" ]'
check "--reset does not clear active"  '[ "$(cat "$TMP/store/active")" = wipeme ]'
check "--reset drops owned config"     '[ ! -e "$TMP/store/profiles/wipeme/CLAUDE.md" ]'
check "--reset drops settings.json"    '[ ! -e "$TMP/store/profiles/wipeme/settings.json" ]'
eq    "--reset relinks shared"         "$(readlink "$TMP/store/profiles/wipeme/plugins")" "$FAKEHOME/.claude/plugins"
check "--reset backed up old copy"     'ls "$TMP/store/.backups" | grep -q "^wipeme-"'
_CP_YES=1 _cp_main --reset nope >/dev/null 2>&1
eq "--reset refuses unknown profile" "$?" "1"

_cp_main default >/dev/null
_CP_YES=1 _cp_main --reset >/dev/null 2>&1
eq "--reset refuses with no profile selected" "$?" "1"
check "--reset left base config alone" '[ -f "$FAKEHOME/.claude/settings.json" ]'
_CP_YES=1 _cp_main --delete wipeme >/dev/null

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

_cp_main --create "my profile" >/dev/null 2>&1
eq "create rejects name with space" "$?" "1"
check "space name made no dir" '[ ! -e "$TMP/store/profiles/my profile" ]'
eq "space name made no other dir either" "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$before"

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

# No path argument: the archive lands in the store's exports/ directory.
_cp_main --export dev >/dev/null 2>&1
check "export defaults to exports/" '[ -s "$TMP/store/exports/dev.tar.gz" ]'

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
check "statusline shows default when unset" 'printf "%s" "$out" | grep -q "\[default\]"'

# Launching through the shell function on the base config sets CLAUDE_CONFIG_DIR
# to ~/.claude explicitly; that is still "default", not a profile named .claude.
out=$(CLAUDE_CONFIG_DIR="$FAKEHOME/.claude" sh "$FAKEHOME/.claude/statusline.sh")
check "statusline shows default for base dir" 'printf "%s" "$out" | grep -q "\[default\]"'

_cp_main --uninstall-statusline >/dev/null
check "block removed"      '! grep -q "CLAUDE_PROFILE_BLOCK" "$FAKEHOME/.claude/statusline.sh"'
check "original still there" 'grep -q "printf hud" "$FAKEHOME/.claude/statusline.sh"'

# A second install must never clobber the first backup — it holds the true
# pre-block original, which is the most valuable thing to preserve.
printf 'hand edited after uninstall\n' >> "$FAKEHOME/.claude/statusline.sh"
_cp_main --install-statusline >/dev/null
eq "first backup still holds the true original" \
   "$(cat "$FAKEHOME/.claude/statusline.sh.bak")" "$_slorig"
# Count via the glob rather than `ls | wc -l`: no subshell, no whitespace to
# trim, and an unmatched glob is detectable instead of counting as one file.
set -- "$FAKEHOME"/.claude/statusline.sh.bak.*
[ -e "$1" ] || set --
_bakcount=$#
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

check_with "parses under dash" dash 'dash -n "$HERE/claude-profile.sh"'
check "parses under bash"  'bash -n "$HERE/claude-profile.sh"'
check_with "parses under zsh" zsh 'zsh -n "$HERE/claude-profile.sh"'
# Suppressions and shell= live in .shellcheckrc, so this stays a bare invocation.
check_with "passes shellcheck" shellcheck \
  'shellcheck "$HERE/claude-profile.sh" "$HERE/install.sh" "$HERE"/lib/*.sh "$HERE/test.sh" "$HERE/bin/claude"'
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

echo "== Task 11b: symlinked content =="

mkdir -p "$TMP/external/extskill"
printf 'name: ext\n' > "$TMP/external/extskill/SKILL.md"
mkdir -p "$FAKEHOME/.claude/skills"
( cd "$FAKEHOME/.claude/skills" && ln -s ../../../external/extskill relskill )
_cp_main --create symp >/dev/null
S="$TMP/store/profiles/symp/skills/relskill"
check "symlinked skill resolves in profile" '[ -e "$S" ]'
check "symlinked skill real content" '[ -f "$S/SKILL.md" ]'
check "symlinked skill is not link" '[ ! -L "$S" ]'
check "shared list still symlinked" '[ -L "$TMP/store/profiles/symp/plugins" ]'
check "show lists symlinked skill" '_cp_main --show symp | grep -q relskill'
_CP_YES=1 _cp_main --delete symp >/dev/null
rm -rf "$FAKEHOME/.claude/skills/relskill" "$TMP/external"

echo "== Task 12: C1 empty-name guard on _cp_exists =="

# _cp_exists "" used to be true (_cp_dir "" is "<store>/profiles/", always a
# directory), so an omitted argument passed every gate it guards. Confirm all
# five gated commands now refuse it, and touch nothing on the way out.
_before_profiles=$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)
_before_backups=$(find "$TMP/store/.backups" -maxdepth 1 -type d 2>/dev/null | wc -l)

_cp_main --delete >/dev/null 2>&1
eq "delete with no name is rejected" "$?" "1"
eq "delete with no name moved no profile" \
   "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$_before_profiles"
eq "delete with no name created no backup" \
   "$(find "$TMP/store/.backups" -maxdepth 1 -type d 2>/dev/null | wc -l)" "$_before_backups"

_cp_main --update >/dev/null 2>&1
eq "update with no name is rejected" "$?" "1"
eq "update with no name changed no profile" \
   "$(find "$TMP/store/profiles" -maxdepth 1 -type d | wc -l)" "$_before_profiles"
eq "update with no name created no backup" \
   "$(find "$TMP/store/.backups" -maxdepth 1 -type d 2>/dev/null | wc -l)" "$_before_backups"

# Explicit target path: the real leak the reviewer reproduced was --export
# with no name silently tarring up every profile, including a real
# .credentials.json. An explicit path keeps this assertion off the cwd.
_cp_main --export "" "$TMP/leak-attempt.tar.gz" >/dev/null 2>&1
eq "export with no name is rejected" "$?" "1"
check "export with no name wrote no archive" '[ ! -e "$TMP/leak-attempt.tar.gz" ]'

_cp_main --show >/dev/null 2>&1
eq "show with no name is rejected" "$?" "1"

_cp_main --diff >/dev/null 2>&1
eq "diff with no name is rejected" "$?" "1"
_cp_main --diff dev >/dev/null 2>&1
eq "diff with only one name is rejected" "$?" "1"

echo "== Task 13: M4 shared-entry repair =="

# A shared entry absent from the immediate source (never linked there, e.g. a
# profile forked before first login) must still be linked from base — not
# only from whatever the build's source happened to already have.
mkdir -p "$TMP/store/profiles/stripped"
cp -R "$TMP/store/profiles/dev/." "$TMP/store/profiles/stripped/"
rm -f "$TMP/store/profiles/stripped/.credentials.json"
check "stripped source has no credentials entry" \
   '[ ! -e "$TMP/store/profiles/stripped/.credentials.json" ]'
_cp_build "$TMP/store/profiles/stripped" "$TMP/store/profiles/repaired"
check "M4: entry missing from source is still linked from base" \
   '[ -L "$TMP/store/profiles/repaired/.credentials.json" ]'
eq "M4: repaired link targets base, not source" \
   "$(readlink "$TMP/store/profiles/repaired/.credentials.json")" "$FAKEHOME/.claude/.credentials.json"
rm -rf "$TMP/store/profiles/stripped" "$TMP/store/profiles/repaired"

echo "== Task 14: H2 zsh NOMATCH glob guard =="

# A source directory with zero dot-entries must not abort _cp_build under
# zsh's default NOMATCH (an unmatched glob aborts the whole command) — the
# realistic "day one, fresh ~/.claude, nothing hidden yet" case.
FRESH="$TMP/freshbase"
mkdir -p "$FRESH"
printf '{}\n' > "$FRESH/settings.json"
_cp_build "$FRESH" "$TMP/h2build" >/dev/null 2>&1
eq "build from base with no dot-entries succeeds" "$?" "0"
check "build from base with no dot-entries produced settings.json" \
   '[ -f "$TMP/h2build/settings.json" ]'
rm -rf "$FRESH" "$TMP/h2build"

# A store with zero profiles must not abort `claude profile` status either.
mkdir -p "$TMP/h2store/profiles"
out=$(CLAUDE_PROFILES_DIR="$TMP/h2store" _cp_main 2>&1)
eq "status with zero profiles succeeds" "$?" "0"
check "status with zero profiles still prints the header" \
   'printf "%s" "$out" | grep -q "^profiles:$"'
rm -rf "$TMP/h2store"

# _cp_owned on a directory with zero dot-entries, the third affected glob.
mkdir -p "$TMP/h2owned"
printf '{}\n' > "$TMP/h2owned/settings.json"
out=$(_cp_owned "$TMP/h2owned" 2>&1)
eq "_cp_owned on dir with no dot-entries succeeds" "$?" "0"
check "_cp_owned still lists the real entry" 'printf "%s" "$out" | grep -q settings.json'
rm -rf "$TMP/h2owned"

echo "== Task 15: login identity seeded into fresh profiles =="
# $HOME/.claude.json sits beside ~/.claude, not inside it, so _cp_build's copy
# loop never sees it. Without the seed a profile built from base — or wiped by
# --reset — starts with no oauthAccount and drops you on the login screen even
# though the keychain token is still there.
HOME="$FAKEHOME" # _cp_seed_auth reads $HOME/.claude.json
printf '{"oauthAccount":{"emailAddress":"base@example.com"},"userID":"uid-1",
         "hasCompletedOnboarding":true,"lastOnboardingVersion":"9.9.9",
         "projects":{"/somewhere":{"x":1}}}\n' > "$FAKEHOME/.claude.json"

# Fresh (empty) profile: identity seeded, nothing else dragged along.
mkdir -p "$TMP/seed/fresh"
_cp_seed_auth "$TMP/seed/fresh"
check "seed creates .claude.json for a fresh profile" '[ -f "$TMP/seed/fresh/.claude.json" ]'
check "seed copies oauthAccount" \
   'grep -q "base@example.com" "$TMP/seed/fresh/.claude.json"'
check "seed copies hasCompletedOnboarding so onboarding does not re-run" \
   'grep -q "hasCompletedOnboarding" "$TMP/seed/fresh/.claude.json"'
check "seed does not drag base projects into the profile" \
   '! grep -q "somewhere" "$TMP/seed/fresh/.claude.json"'

# A profile that already has an identity must never be rewritten.
mkdir -p "$TMP/seed/owned"
printf '{"oauthAccount":{"emailAddress":"mine@example.com"},"mcpServers":{"a":1}}\n' \
   > "$TMP/seed/owned/.claude.json"
_cp_seed_auth "$TMP/seed/owned"
check "seed leaves an existing account alone" \
   'grep -q "mine@example.com" "$TMP/seed/owned/.claude.json"'
check "seed does not clobber existing base@ into an owned profile" \
   '! grep -q "base@example.com" "$TMP/seed/owned/.claude.json"'

# Profile with data but no identity: merge in, keep everything else.
mkdir -p "$TMP/seed/partial"
printf '{"mcpServers":{"b":2},"numStartups":9}\n' > "$TMP/seed/partial/.claude.json"
_cp_seed_auth "$TMP/seed/partial"
check "seed merges identity into a profile that has none" \
   'grep -q "base@example.com" "$TMP/seed/partial/.claude.json"'
check "seed preserves per-profile mcpServers" \
   'grep -q "mcpServers" "$TMP/seed/partial/.claude.json"'
check "seed preserves other per-profile keys" \
   'grep -q "numStartups" "$TMP/seed/partial/.claude.json"'

# No base identity to seed from: must be a silent no-op, not a crash.
printf '{"numStartups":1}\n' > "$FAKEHOME/.claude.json"
mkdir -p "$TMP/seed/nobase"
_cp_seed_auth "$TMP/seed/nobase"
eq "seed succeeds when base has no account" "$?" "0"
check "seed writes nothing when base has no account" \
   '[ ! -f "$TMP/seed/nobase/.claude.json" ]'
rm -rf "$TMP/seed"

echo "== shared prompt state =="

rm -f "$CLAUDE_PROFILES_DIR/prompt-state.json"
cat > "$FAKEHOME/.claude.json" <<'JSON'
{ "projects": { "/repo/base": { "hasTrustDialogAccepted": true } } }
JSON

# Profile A trusts /repo/a on its own; base already trusts /repo/base.
mkdir -p "$TMP/ps/a" "$TMP/ps/b"
cat > "$TMP/ps/a/.claude.json" <<'JSON'
{ "mcpServers": { "figma": {} },
  "projects": { "/repo/a": { "hasTrustDialogAccepted": true, "history": ["secret"] } } }
JSON
printf '{"projects":{}}\n' > "$TMP/ps/b/.claude.json"

_cp_sync_prompts "$TMP/ps/a"
_cp_sync_prompts "$TMP/ps/b"

check "registry is created in the store" \
   '[ -f "$CLAUDE_PROFILES_DIR/prompt-state.json" ]'
check "profile A picks up base's trusted folder" \
   'grep -q "/repo/base" "$TMP/ps/a/.claude.json"'
check "profile B picks up profile A's trusted folder" \
   'grep -q "/repo/a" "$TMP/ps/b/.claude.json"'
check "profile B picks up base's trusted folder" \
   'grep -q "/repo/base" "$TMP/ps/b/.claude.json"'
check "sync keeps per-profile mcpServers" \
   'grep -q "figma" "$TMP/ps/a/.claude.json"'
check "sync never leaks prompt history between profiles" \
   '! grep -q "secret" "$TMP/ps/b/.claude.json"'
check "base ~/.claude.json is never written" \
   '! grep -q "/repo/a" "$FAKEHOME/.claude.json"'

# Base config dir is not a profile: must be left alone entirely.
_cp_sync_prompts "$FAKEHOME/.claude"
check "sync skips the base config dir" \
   '! grep -q "/repo/a" "$FAKEHOME/.claude.json"'

# Missing .claude.json: silent no-op, not a crash.
mkdir -p "$TMP/ps/empty"
_cp_sync_prompts "$TMP/ps/empty"
eq "sync succeeds with no .claude.json" "$?" "0"
check "sync creates no .claude.json out of nothing" \
   '[ ! -f "$TMP/ps/empty/.claude.json" ]'
rm -rf "$TMP/ps"

echo "== Task 16: running without sourcing, and install.sh =="

# The entry script has to work executed as well as sourced, so that a fresh
# clone does something useful before anything touches a shell rc. These run it
# as a subprocess, which is the only honest way to test the executed path.
CPX="$HERE/claude-profile.sh"
XENV="HOME=$FAKEHOME CLAUDE_PROFILES_DIR=$TMP/xstore"
mkdir -p "$TMP/xstore"

check "entry script is executable" '[ -x "$CPX" ]'
check "entry script has a shebang" 'head -1 "$CPX" | grep -q "^#!"'

check "executed --help prints usage" \
   'env $XENV "$CPX" --help | grep -q -- "--create"'
check "executed bare prints status" \
   'env $XENV "$CPX" | grep -q "^store: "'
check "executed --create builds a profile" \
   'env $XENV "$CPX" --create xprof >/dev/null && [ -d "$TMP/xstore/profiles/xprof" ]'
check "executed --create is visible to a later run" \
   'env $XENV "$CPX" | grep -q "xprof"'
env $XENV "$CPX" --nope >/dev/null 2>&1
eq "executed unknown option exits 1" "$?" "1"

# The tail dispatch keys off _CP_EXEC. If that leaks into the sourced case, a
# login shell would run _cp_main on whatever happened to be in $@ — so assert
# the negative, not just that sourcing works.
check "sourcing defines the claude wrapper" \
   'bash -c ". \"$CPX\"; case \$(command -v claude) in claude) exit 0 ;; *) exit 1 ;; esac"'
check "sourcing with args does not dispatch" \
   'bash -c "cd \"$TMP\" && set -- --create LEAK && . \"$CPX\"" >/dev/null 2>&1 &&
    [ ! -d "$TMP/xstore/profiles/LEAK" ]'
check_with "sourcing under dash does not dispatch" dash \
   'dash -c "cd \"$HERE\" && . ./claude-profile.sh" >/dev/null 2>&1;
    [ ! -d "$TMP/xstore/profiles/dash" ]'

# CRLF is the specific way this breaks: a "#!/bin/sh\r" shebang is a fatal
# "bad interpreter" on Linux, and dash will not read "then\r" as `then`.
# .gitattributes pins it, and this catches a checkout that ignored it.
check "entry script has no CR bytes" '! grep -q "$(printf "\r")" "$CPX"'
check "install.sh has no CR bytes"   '! grep -q "$(printf "\r")" "$HERE/install.sh"'
check ".gitattributes pins sh to lf" \
   'grep -q "\*\.sh text eol=lf" "$HERE/.gitattributes"'

check "install.sh is executable" '[ -x "$HERE/install.sh" ]'
check_with "install.sh parses under dash" dash 'dash -n "$HERE/install.sh"'

# CP_RC, CP_LINK_DIR and CP_ZSHENV are the seams that keep copy_code, link_bin
# and add_zshenv_path off the real ~/.claude-profile, ~/.local/bin and ~/.zshenv.
IRC="$TMP/fakerc"
: > "$IRC"
IRC_ENV="CP_RC=$IRC CLAUDE_PROFILE_INSTALL_DIR=$TMP/irc-install CP_LINK_DIR=$TMP/irc-install/.local/bin CP_ZSHENV=$TMP/irc-install/.zshenv"
check "install writes the source line" \
   'env $IRC_ENV "$HERE/install.sh" --no-migrate >/dev/null 2>&1 && grep -qF "claude-profile.sh" "$IRC"'
# shellcheck disable=SC2086 # IRC_ENV is a list of VAR=val words, splitting is the point
env $IRC_ENV "$HERE/install.sh" --no-migrate >/dev/null 2>&1
# shellcheck disable=SC2086 # IRC_ENV is a list of VAR=val words, splitting is the point
env $IRC_ENV "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install is idempotent" "$(grep -c 'claude-profile\.sh' "$IRC")" "1"

# Both PATH surfaces are asserted against a throwaway HOME here, not trusted
# to the docs. --no-migrate is required: SELF_DIR is $HERE, this real checkout.
IH="$TMP/ihome-stable"
mkdir -p "$IH"
env HOME="$IH" SHELL=/bin/zsh CP_RC="$IH/.zshrc" CP_ZSHENV="$IH/.zshenv" \
    CP_LINK_DIR="$IH/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH/.claude-profile" \
    sh "$HERE/install.sh" --from-npm --no-migrate >"$TMP/stableout" 2>&1
eq "install --from-npm succeeds" "$?" "0"
check "code landed in the install dir" '[ -f "$IH/.claude-profile/claude-profile.sh" ] &&
                                        [ -d "$IH/.claude-profile/lib" ]'
check "surface A is on PATH"      '[ -L "$IH/.local/bin/claude-profile" ]'
check "surface A actually runs"   'env HOME="$IH" "$IH/.local/bin/claude-profile" --help |
                                   grep -q -- "--create"'
check "shim installed"            '[ -x "$IH/.claude-profile/bin/claude" ]'
check "zshenv prepends the bin dir" \
   'grep -qF "$IH/.claude-profile/bin" "$IH/.zshenv"'
check "zshenv guards against a double prepend" 'grep -q "case \":\$PATH:\"" "$IH/.zshenv"'
check "rc points at the install dir" \
   'grep -qF "$IH/.claude-profile/claude-profile.sh" "$IH/.zshrc"'
check "--from-npm prints the migrate hint" 'grep -q -- "--migrate-store" "$TMP/stableout"'

env HOME="$IH" SHELL=/bin/zsh CP_RC="$IH/.zshrc" CP_ZSHENV="$IH/.zshenv" \
    CP_LINK_DIR="$IH/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH/.claude-profile" \
    sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
eq "install is idempotent in the rc"     "$(grep -c 'claude-profile\.sh' "$IH/.zshrc")" "1"
eq "install is idempotent in the zshenv" "$(grep -c 'claude-profile/bin' "$IH/.zshenv")" "1"

# CLAUDE_PROFILE_INSTALL_DIR must never resolve to $HOME, an ancestor of it, or
# /, or copy_code's rm -rf would wipe real directories like ~/bin or ~/lib.
IH5="$TMP/ihome-dangerous"
mkdir -p "$IH5/bin"
: > "$IH5/bin/marker"
env HOME="$IH5" CLAUDE_PROFILE_INSTALL_DIR="$IH5" \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is \$HOME" "$?" "1"
check "nothing was deleted when INSTALL_DIR is \$HOME" '[ -f "$IH5/bin/marker" ]'

env HOME="$IH5/nested" CLAUDE_PROFILE_INSTALL_DIR="$IH5" \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is an ancestor of \$HOME" "$?" "1"

env HOME="$IH5" CLAUDE_PROFILE_INSTALL_DIR=/ \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is /" "$?" "1"

# Canonicalisation catches spellings a string check misses: ///, $HOME/., //
# duplicates, relative paths and symlinks, all of which rm -rf would follow.
IH6="$TMP/ihome-bypass"
mkdir -p "$IH6/bin"
: > "$IH6/bin/marker"

env HOME="$IH6" CLAUDE_PROFILE_INSTALL_DIR="///" \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is ///" "$?" "1"

env HOME="$IH6" CLAUDE_PROFILE_INSTALL_DIR="$IH6//" \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is \$HOME//" "$?" "1"

env HOME="$IH6" CLAUDE_PROFILE_INSTALL_DIR="$IH6/." \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is \$HOME/." "$?" "1"

(cd "$IH6" && env HOME="$IH6" CLAUDE_PROFILE_INSTALL_DIR="." \
    sh "$HERE/install.sh" --no-migrate) >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is a relative ." "$?" "1"

IH6LINK="$TMP/ihome-bypass-link"
ln -s "$IH6" "$IH6LINK"
env HOME="$IH6" CLAUDE_PROFILE_INSTALL_DIR="$IH6LINK" \
    sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses when INSTALL_DIR is a symlink to \$HOME" "$?" "1"

check "nothing was deleted across the bypass rows" '[ -f "$IH6/bin/marker" ]'

# A clone-pointing line is the state every existing user is in. Rewrite it;
# refusing would leave them broken with no path forward.
IH2="$TMP/ihome-oldline"
mkdir -p "$IH2"
printf 'source %s/claude-profile.sh\n' "$HERE" > "$IH2/.zshrc"
env HOME="$IH2" SHELL=/bin/zsh CP_RC="$IH2/.zshrc" CP_ZSHENV="$IH2/.zshenv" \
    CP_LINK_DIR="$IH2/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH2/.claude-profile" \
    sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
eq "install rewrites a clone-pointing rc line" "$?" "0"
eq "only one source line remains" "$(grep -c 'claude-profile\.sh' "$IH2/.zshrc")" "1"
check "the remaining line points at the install dir" \
   'grep -qF "$IH2/.claude-profile/claude-profile.sh" "$IH2/.zshrc"'

IH3="$TMP/ihome-noshim"
mkdir -p "$IH3"
env HOME="$IH3" SHELL=/bin/zsh CP_RC="$IH3/.zshrc" CP_ZSHENV="$IH3/.zshenv" \
    CP_LINK_DIR="$IH3/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH3/.claude-profile" \
    sh "$HERE/install.sh" --from-npm --no-shim --no-migrate >/dev/null 2>&1
check "--no-shim leaves no shim"   '[ ! -e "$IH3/.claude-profile/bin/claude" ]'
check "--no-shim keeps surface A"  '[ -L "$IH3/.local/bin/claude-profile" ]'
check "--no-shim skips the zshenv" '[ ! -f "$IH3/.zshenv" ] ||
                                    ! grep -q "claude-profile/bin" "$IH3/.zshenv"'

# A clone carrying a store gets it migrated, not silently orphaned. The one
# run in this suite without --no-migrate: $CLONE is throwaway, never $HERE.
IH4="$TMP/ihome-migrate"
CLONE="$TMP/oldclone"
mkdir -p "$IH4" "$CLONE/profiles/legacyprof"
cp "$HERE/claude-profile.sh" "$HERE/install.sh" "$CLONE/"
cp -R "$HERE/lib" "$HERE/bin" "$CLONE/"
printf '{ "x": "%s/profiles/legacyprof/statusline.sh" }\n' "$CLONE" \
    > "$CLONE/profiles/legacyprof/settings.json"
# CLAUDE_PROFILES_DIR is exported suite-wide (line ~61); override it here or
# it silently redirects the migrated store to $TMP/store instead of $IH4.
env HOME="$IH4" SHELL=/bin/zsh CP_RC="$IH4/.zshrc" CP_ZSHENV="$IH4/.zshenv" \
    CP_LINK_DIR="$IH4/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH4/.claude-profile" \
    CLAUDE_PROFILES_DIR="$IH4/.claude-profiles" \
    sh "$CLONE/install.sh" --from-npm >/dev/null 2>&1 || true
check "a clone store was migrated" '[ -d "$IH4/.claude-profiles/profiles/legacyprof" ]'
check "migrated settings were rewritten" \
   'grep -q "$IH4/.claude-profiles/profiles/legacyprof/statusline.sh" \
      "$IH4/.claude-profiles/profiles/legacyprof/settings.json"'

# Every existing user has a line pointing at their old clone. Repoint it
# rather than refuse -- leaving them with no path forward is worse.
CONFLICT_ENV="CP_RC=$TMP/conflictrc CLAUDE_PROFILE_INSTALL_DIR=$TMP/conflict-install CP_LINK_DIR=$TMP/conflict-install/.local/bin CP_ZSHENV=$TMP/conflict-install/.zshenv"
printf 'source ~/elsewhere/claude-profile.sh\n' > "$TMP/conflictrc"
# shellcheck disable=SC2086 # CONFLICT_ENV is a list of VAR=val words, splitting is the point
env $CONFLICT_ENV "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install rewrites a line pointing at another clone" "$?" "0"
check "the rewritten line points at the install dir" \
   'grep -qxF ". \"$TMP/conflict-install/claude-profile.sh\"" "$TMP/conflictrc"'
eq "the rewrite left exactly one source line" \
   "$(grep -c 'claude-profile\.sh' "$TMP/conflictrc")" "1"

# A commented-out mention is not a source line this script can repoint --
# stop and say so by hand, rather than duplicate or guess.
printf '# source ~/elsewhere/claude-profile.sh\n' > "$TMP/commentedrc"
CP_RC="$TMP/commentedrc" "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install refuses a commented-out mention" "$?" "1"
eq "install left the commented-out rc alone" \
   "$(cat "$TMP/commentedrc")" "# source ~/elsewhere/claude-profile.sh"

# $SHELL is the login shell from the password database, not the shell you are
# typing into. Keying off it alone made this exit 1 on every container, WSL
# image and `su` session, where it is commonly /bin/sh — the regression that
# these four pin down.
IH="$TMP/ihome"; mkdir -p "$IH"; : > "$IH/.bashrc"
check "install works when \$SHELL is /bin/sh" \
   'env HOME="$IH" SHELL=/bin/sh bash "$HERE/install.sh" --no-migrate >/dev/null 2>&1 &&
    grep -qF "claude-profile.sh" "$IH/.bashrc"'

IH2="$TMP/ihome2"; mkdir -p "$IH2"; : > "$IH2/.zshrc"
check "install picks .zshrc for a zsh login shell" \
   'env HOME="$IH2" SHELL=/bin/zsh sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1 &&
    grep -qF "claude-profile.sh" "$IH2/.zshrc"'

# A named shell with no rc yet is a fresh account, not an ambiguity.
IH3="$TMP/ihome3"; mkdir -p "$IH3"
check "install creates a missing rc for a known shell" \
   'env HOME="$IH3" SHELL=/bin/zsh sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1 &&
    [ -f "$IH3/.zshrc" ]'

# Two candidates and nothing to choose between them is where it must stop.
IH4="$TMP/ihome4"; mkdir -p "$IH4"; : > "$IH4/.zshrc"; : > "$IH4/.bashrc"
env HOME="$IH4" sh -c "SHELL=/bin/sh exec \"$HERE/install.sh\" --no-migrate" >/dev/null 2>&1
eq "install stops when both rc files exist and \$SHELL is unhelpful" "$?" "1"
check "install left both candidate rc files alone" \
   '[ ! -s "$IH4/.zshrc" ] && [ ! -s "$IH4/.bashrc" ]'

# Bash reads .bashrc for interactive non-login shells and nothing else. A bare
# account or container image has no login file at all, so the source line goes
# in and `bash -l`, `su -` and most container entrypoints never see it — an
# install that reports success and does nothing. zsh has no equivalent gap.
IH7="$TMP/ihome7"; mkdir -p "$IH7"
env HOME="$IH7" SHELL=/bin/bash sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install succeeds on a bare HOME" "$?" "0"
check "install adds a login hook on a bare HOME" \
   '[ -f "$IH7/.bash_profile" ] && grep -q "\.bashrc" "$IH7/.bash_profile"'
# No `exit` in a check expression: check() evals it in this shell, so an exit
# here ends the run rather than the case.
check_with "a login shell reaches the wrapper" bash \
   '[ "$(env HOME="$IH7" bash -l -i -c "command -v claude" 2>/dev/null)" = claude ]'

# Writing .bash_profile is only safe when the whole login chain is empty. Debian
# ships a ~/.profile that already sources .bashrc, and bash reads just the first
# of .bash_profile/.bash_login/.profile — so adding one would shadow it.
IH8="$TMP/ihome8"; mkdir -p "$IH8"; : > "$IH8/.bashrc"
printf 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' > "$IH8/.profile"
env HOME="$IH8" SHELL=/bin/bash sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install accepts a .profile that sources .bashrc" "$?" "0"
check "install does not shadow .profile with .bash_profile" \
   '[ ! -f "$IH8/.bash_profile" ]'

# A login file that exists but does not source .bashrc is someone else's, the
# same as a source line this script did not write: say what to add, change
# nothing, and do not exit 0 on a half-reachable install.
IH9="$TMP/ihome9"; mkdir -p "$IH9"; : > "$IH9/.bashrc"
printf 'export FOO=1\n' > "$IH9/.bash_profile"
env HOME="$IH9" SHELL=/bin/bash sh "$HERE/install.sh" --no-migrate >/dev/null 2>&1
eq "install reports a login shell it cannot reach" "$?" "1"
eq "install left the login file alone" "$(cat "$IH9/.bash_profile")" "export FOO=1"

# Alias expansion happens before function lookup, so an alias wins over the
# wrapper however correct the install is. Aliases exist only in interactive
# shells, which is the other reason the check has to start one.
IH10="$TMP/ihome10"; mkdir -p "$IH10"
printf 'alias claude=echo\n' > "$IH10/.bashrc"
printf 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' > "$IH10/.profile"
env HOME="$IH10" SHELL=/bin/bash sh "$HERE/install.sh" --no-migrate >"$TMP/aliasout" 2>&1
eq "install fails when an alias shadows the wrapper" "$?" "1"
check "install names the alias it found" 'grep -q "alias" "$TMP/aliasout"'

# Checking a zsh install by running bash would read .bashrc rather than the
# .zshrc just written and pass no matter what. Saying so is the honest answer.
if command -v zsh >/dev/null 2>&1; then
    skip "install skips the load check without the target shell" zsh-absent
else
    IH11="$TMP/ihome11"; mkdir -p "$IH11"; : > "$IH11/.zshrc"
    env HOME="$IH11" SHELL=/bin/zsh sh "$HERE/install.sh" --no-migrate >"$TMP/zshout" 2>&1
    eq "install without the target shell still succeeds" "$?" "0"
    check "install skips the load check without the target shell" \
       'grep -q "skipping the load check" "$TMP/zshout"'
fi

# An --rc can name a file no shell reads, so the claim has to shrink to what
# was actually established: sourcing it works, reachability is unknown.
check "an explicit --rc does not claim reachability" \
   'CP_RC="$TMP/explicitrc" "$HERE/install.sh" --no-migrate 2>&1 | grep -q "was not checked"'

check "install honours --shell" \
   'env HOME="$TMP/ihome5" sh -c "mkdir -p \"$TMP/ihome5\"" &&
    env HOME="$TMP/ihome5" SHELL=/bin/sh sh "$HERE/install.sh" --shell bash --no-migrate >/dev/null 2>&1 &&
    grep -qF "claude-profile.sh" "$TMP/ihome5/.bashrc"'
check "install honours --rc" \
   'env HOME="$TMP/ihome6" sh -c "mkdir -p \"$TMP/ihome6\"" &&
    env HOME="$TMP/ihome6" sh "$HERE/install.sh" --rc "$TMP/ihome6rc" --no-migrate >/dev/null 2>&1 &&
    grep -qF "claude-profile.sh" "$TMP/ihome6rc"'

"$HERE/install.sh" --no-migrate --help >/dev/null 2>&1
eq "install --help exits 0" "$?" "0"
"$HERE/install.sh" --no-migrate --bogus >/dev/null 2>&1
eq "install rejects an unknown flag" "$?" "1"
"$HERE/install.sh" --no-migrate --shell fish >/dev/null 2>&1
eq "install rejects an unsupported shell" "$?" "1"
"$HERE/install.sh" --no-migrate --rc >/dev/null 2>&1
eq "install rejects --rc with no value" "$?" "1"

# --uninstall reverses an install and must leave the profile store alone.
IH12="$TMP/ihome-uninstall"
mkdir -p "$IH12"
UENV="HOME=$IH12 SHELL=/bin/zsh CP_RC=$IH12/.zshrc CP_ZSHENV=$IH12/.zshenv"
UENV="$UENV CP_LINK_DIR=$IH12/.local/bin CLAUDE_PROFILE_INSTALL_DIR=$IH12/.claude-profile"
# The suite exports CLAUDE_PROFILES_DIR="$TMP/store" above; override it here so
# the printed store path reflects this fixture's own home, not the shared one.
UENV="$UENV CLAUDE_PROFILES_DIR=$IH12/.claude-profiles"
# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
mkdir -p "$IH12/.claude-profiles/profiles/keepme"
: > "$IH12/.claude-profiles/profiles/keepme/marker"

# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --uninstall --no-migrate >"$TMP/uninstout" 2>&1
eq "uninstall succeeds" "$?" "0"
check "install dir removed"       '[ ! -e "$IH12/.claude-profile" ]'
check "symlink removed"           '[ ! -e "$IH12/.local/bin/claude-profile" ]'
check "rc line removed"           '! grep -q "claude-profile\.sh" "$IH12/.zshrc"'
check "zshenv line removed"       '! grep -q "claude-profile/bin" "$IH12/.zshenv"'
check "store left alone"          '[ -f "$IH12/.claude-profiles/profiles/keepme/marker" ]'
check "uninstall names the store" 'grep -qF "$IH12/.claude-profiles" "$TMP/uninstout"'

# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --uninstall --no-migrate >/dev/null 2>&1
eq "uninstall is idempotent" "$?" "0"

# --uninstall must not remove a foreign file at the symlink path: only a
# symlink resolving into this tool's own bin dir is ours to delete.
IH13="$TMP/ihome-uninstall-foreign"
mkdir -p "$IH13"
UENV="HOME=$IH13 SHELL=/bin/zsh CP_RC=$IH13/.zshrc CP_ZSHENV=$IH13/.zshenv"
UENV="$UENV CP_LINK_DIR=$IH13/.local/bin CLAUDE_PROFILE_INSTALL_DIR=$IH13/.claude-profile"
UENV="$UENV CLAUDE_PROFILES_DIR=$IH13/.claude-profiles"
# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
rm -f "$IH13/.local/bin/claude-profile"
echo "not ours" > "$IH13/.local/bin/claude-profile"

# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --uninstall --no-migrate >"$TMP/uninstout13" 2>&1
eq "uninstall (foreign file) succeeds" "$?" "0"
check "foreign file at symlink path survives" '[ -f "$IH13/.local/bin/claude-profile" ]'
check "foreign file content untouched"        'grep -qF "not ours" "$IH13/.local/bin/claude-profile"'
check "install dir still removed"             '[ ! -e "$IH13/.claude-profile" ]'
check "uninstall warns it left the file alone" 'grep -qF "left $IH13/.local/bin/claude-profile alone" "$TMP/uninstout13"'

# --uninstall must only remove its own source line, never a user comment
# that merely mentions claude-profile.sh.
IH14="$TMP/ihome-uninstall-comment"
mkdir -p "$IH14"
UENV="HOME=$IH14 SHELL=/bin/zsh CP_RC=$IH14/.zshrc CP_ZSHENV=$IH14/.zshenv"
UENV="$UENV CP_LINK_DIR=$IH14/.local/bin CLAUDE_PROFILE_INSTALL_DIR=$IH14/.claude-profile"
UENV="$UENV CLAUDE_PROFILES_DIR=$IH14/.claude-profiles"
# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
echo "# reminder: claude-profile.sh lives in ~/.claude-profile" >> "$IH14/.zshrc"

# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --uninstall --no-migrate >/dev/null 2>&1
eq "uninstall (user comment) succeeds" "$?" "0"
check "user comment survives" 'grep -qF "reminder: claude-profile.sh" "$IH14/.zshrc"'
check "real source line gone" '! grep -qE "^[[:space:]]*(\.|source)[[:space:]].*claude-profile\.sh" "$IH14/.zshrc"'

# --uninstall must fully reverse .zshenv even when CLAUDE_PROFILE_INSTALL_DIR's
# name has no "claude-profile" substring for a plain grep to latch onto.
IH15="$TMP/ihome-uninstall-customdir"
mkdir -p "$IH15"
UENV="HOME=$IH15 SHELL=/bin/zsh CP_RC=$IH15/.zshrc CP_ZSHENV=$IH15/.zshenv"
UENV="$UENV CP_LINK_DIR=$IH15/.local/bin CLAUDE_PROFILE_INSTALL_DIR=$IH15/.mytool"
UENV="$UENV CLAUDE_PROFILES_DIR=$IH15/.claude-profiles"
# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --from-npm --no-migrate >/dev/null 2>&1
check "zshenv got the PATH block" 'grep -qF "$IH15/.mytool/bin" "$IH15/.zshenv"'

# shellcheck disable=SC2086 # $UENV holds space-separated KEY=VALUE pairs for env to split
env $UENV sh "$HERE/install.sh" --uninstall --no-migrate >/dev/null 2>&1
eq "uninstall (custom install dir) succeeds" "$?" "0"
check "zshenv has no leftover PATH block" '[ ! -s "$IH15/.zshenv" ]'

# Canary: every install.sh invocation above ran with SELF_DIR pointed at this
# repo. If migrate_clone_store ever fires without --no-migrate honoring it,
# this repo's own profiles/ directory disappears here, loud and immediate.
check "the repo's own profiles/ survived the install tests" '[ -d "$HERE/profiles" ]'

rm -rf "$TMP/xstore"

echo "== Task 17: real claude discovery =="

# Task 5 puts a script named claude on PATH; guards against the resolver looping back into it.
mkdir -p "$TMP/fakeinstall/bin" "$TMP/realbin" "$TMP/earlybin"
printf '#!/bin/sh\nprintf shim\n' > "$TMP/fakeinstall/bin/claude"
printf '#!/bin/sh\nprintf real\n' > "$TMP/realbin/claude"
chmod +x "$TMP/fakeinstall/bin/claude" "$TMP/realbin/claude"
ln -s "$TMP/fakeinstall/bin/claude" "$TMP/earlybin/claude"

got=$(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    PATH="$TMP/fakeinstall/bin:$TMP/realbin"
    _cp_real_claude
)
eq "resolver skips our own shim" "$got" "$TMP/realbin/claude"

got=$(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    # /usr/bin:/bin stay on PATH so _cp_deref can shell out to readlink/dirname;
    # checked neither holds a claude, and realbin/claude wins on PATH order regardless.
    PATH="$TMP/earlybin:$TMP/realbin:/usr/bin:/bin"
    _cp_real_claude
)
eq "resolver skips a symlink into the install dir" "$got" "$TMP/realbin/claude"

(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    PATH="$TMP/fakeinstall/bin"
    _cp_real_claude >/dev/null 2>&1
)
eq "resolver fails when only our shim is on PATH" "$?" "1"

eq "install dir honours its env seam" \
   "$(CLAUDE_PROFILE_INSTALL_DIR=/x/y; _cp_install_dir)" "/x/y"
got=$(unset CLAUDE_PROFILE_INSTALL_DIR; _cp_install_dir)
eq "install dir defaults under HOME" "$got" "$FAKEHOME/.claude-profile"

eq "deref follows a symlink chain" "$(_cp_deref "$TMP/earlybin/claude")" \
   "$TMP/fakeinstall/bin/claude"
eq "deref leaves a real file alone" "$(_cp_deref "$TMP/realbin/claude")" \
   "$TMP/realbin/claude"

echo "== Task 18: store migration =="

LEG="$TMP/legacy"
NEW="$TMP/newstore"
mkdir -p "$LEG/profiles/dev/hooks" "$LEG/exports"
printf '{ "statusLine": { "command": "%s/profiles/dev/statusline.sh" } }\n' "$LEG" \
    > "$LEG/profiles/dev/settings.json"
printf '#!/bin/sh\n%s/profiles/dev/hooks/inner.sh\n' "$LEG" > "$LEG/profiles/dev/hooks/h.sh"
chmod +x "$LEG/profiles/dev/hooks/h.sh"
printf 'printf hud\n' > "$LEG/profiles/dev/statusline.sh"
printf '{ "projects": { "%s": { "n": 1 } } }\n' "$LEG" > "$LEG/profiles/dev/.claude.json"
printf 'dev\n' > "$LEG/active"

out=$(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$LEG" 2>&1)
eq "migration succeeds" "$?" "0"
check "migration moved profiles"     '[ -d "$NEW/profiles/dev" ] && [ ! -e "$LEG/profiles" ]'
check "migration moved active"       '[ -f "$NEW/active" ]'
check "migration moved exports"      '[ -d "$NEW/exports" ]'
check "settings.json points at the new store" \
   'grep -q "$NEW/profiles/dev/statusline.sh" "$NEW/profiles/dev/settings.json"'
check "hook script points at the new store" \
   'grep -q "$NEW/profiles/dev/hooks/inner.sh" "$NEW/profiles/dev/hooks/h.sh"'
check ".claude.json still points at the old clone" \
   'grep -q "$LEG" "$NEW/profiles/dev/.claude.json"'
check "the original was backed up" \
   'grep -rq "$LEG/profiles/dev/statusline.sh" "$NEW/.backups"'
check "migration reports what it rewrote" 'echo "$out" | grep -q "settings.json"'
check "rewritten hook keeps its executable bit" '[ -x "$NEW/profiles/dev/hooks/h.sh" ]'
check "rewritten settings.json stays non-executable" '[ ! -x "$NEW/profiles/dev/settings.json" ]'

# Retrying against the now-drained legacy dir must not say "nothing to
# migrate" -- the destination already holds data, so this is either an
# interrupted move or a mistaken repeat, and either way the source must not
# look safe to delete.
out2=$(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$LEG" 2>&1)
eq "retry on a drained source exits 1" "$?" "1"
check "retry on a drained source warns rather than clears it for deletion" \
   'echo "$out2" | grep -q "interrupted migration"'

# A second, still-populated legacy dir must be refused as a merge -- distinct
# from the drained-source case above, and its own dedicated guard branch.
FRESH="$TMP/freshlegacy"
mkdir -p "$FRESH/profiles/other"
printf 'marker\n' > "$FRESH/profiles/other/marker"
out3=$(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$FRESH" 2>&1)
eq "migration refuses a non-empty destination" "$?" "1"
check "merge refusal names the reason" 'echo "$out3" | grep -q "refusing to merge"'
check "merge refusal leaves the fresh source untouched" \
   '[ -f "$FRESH/profiles/other/marker" ]'

(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$TMP/nope" >/dev/null 2>&1)
eq "migration refuses a missing source" "$?" "1"

MT="$TMP/emptylegacy"; mkdir -p "$MT"
(CLAUDE_PROFILES_DIR="$TMP/store3"; _cp_migrate_store "$MT" >/dev/null 2>&1)
eq "migration refuses a source with no profiles" "$?" "1"

# A failure partway through the entry moves must not leave the retry message
# implying the drained parts are gone for good -- exports/ here is blocked by
# a same-named plain file already sitting in the destination.
LEG2="$TMP/legacy2"
TO2="$TMP/store5"
mkdir -p "$LEG2/profiles/x" "$LEG2/exports" "$TO2"
printf 'p\n' > "$LEG2/profiles/x/marker"
printf 'dev\n' > "$LEG2/active"
printf 'blocker\n' > "$TO2/exports"
out4=$(CLAUDE_PROFILES_DIR="$TO2"; _cp_migrate_store "$LEG2" 2>&1)
eq "partial move failure exits 1" "$?" "1"
check "partial move failure names what already moved" 'echo "$out4" | grep -q "already moved"'
check "partial move failure names the entry that failed" 'echo "$out4" | grep -q "exports"'
check "partial move failure warns against deleting the source" \
   'echo "$out4" | grep -q "do not delete"'
check "the already-moved entries really did move" '[ -d "$TO2/profiles/x" ]'
check "the not-yet-moved entry is still in the source" '[ -e "$LEG2/exports" ]'

# A legacy path containing BRE metacharacters must still be recognised and
# rewritten -- grep/sed would otherwise read *, [, ], ^, $, . as regex syntax
# instead of literal path characters and silently skip the file.
LEGX="$TMP"'/leg.a*b[c]d^e$f'
NEWX="$TMP/storex"
mkdir -p "$LEGX/profiles/dev"
printf '{ "statusLine": { "command": "%s/profiles/dev/statusline.sh" } }\n' "$LEGX" \
    > "$LEGX/profiles/dev/settings.json"
printf 'printf hud\n' > "$LEGX/profiles/dev/statusline.sh"
outx=$(CLAUDE_PROFILES_DIR="$NEWX"; _cp_migrate_store "$LEGX" 2>&1)
eq "migration with a metacharacter-laden path succeeds" "$?" "0"
check "metacharacter path settings.json still gets rewritten" \
   'grep -q "$NEWX/profiles/dev/statusline.sh" "$NEWX/profiles/dev/settings.json"'
check "metacharacter path leaves no leftover old reference" \
   '! grep -Fq "$LEGX" "$NEWX/profiles/dev/settings.json"'

check "executed --migrate-store is wired up" \
   'env HOME="$FAKEHOME" CLAUDE_PROFILES_DIR="$TMP/store4" "$CPX" --migrate-store 2>&1 |
    grep -q "needs a directory"'
check "help mentions --migrate-store" \
   'env $XENV "$CPX" --help | grep -q -- "--migrate-store"'

echo "== Task 19: bin shims =="

# _CP_RUNNER is read from the environment, so a real script stands in for the
# claude binary across a subprocess boundary where a shell function cannot.
printf '#!/bin/sh\nprintf "CFG=%%s ARGS=%%s\\n" "$CLAUDE_CONFIG_DIR" "$*"\n' > "$TMP/fakerunner"
chmod +x "$TMP/fakerunner"

# shellcheck disable=SC2086 # $XENV holds space-separated KEY=VALUE pairs for env to split
env $XENV "$CPX" --create shimprof >/dev/null
printf 'shimprof\n' > "$TMP/xstore/active"

check "bin/claude-profile is a symlink" '[ -L "$HERE/bin/claude-profile" ]'
# Assert the link text, not a dereferenced path: _cp_deref resolves a relative
# link against its own directory, so it returns "<repo>/bin/../claude-profile.sh"
# -- correct, and never string-equal to "<repo>/claude-profile.sh".
eq "bin/claude-profile points at the entry script" \
   "$(readlink "$HERE/bin/claude-profile")" "../claude-profile.sh"
check "symlinked entry still finds lib" \
   'env $XENV "$HERE/bin/claude-profile" | grep -q "^store: "'

# shellcheck disable=SC2086 # $XENV holds space-separated KEY=VALUE pairs for env to split
out=$(env $XENV _CP_RUNNER="$TMP/fakerunner" "$HERE/bin/claude" --version 2>&1)
check "shim launches the active profile" \
   'echo "$out" | grep -q "CFG=$TMP/xstore/profiles/shimprof ARGS=--version"'

# shellcheck disable=SC2086 # $XENV holds space-separated KEY=VALUE pairs for env to split
out=$(env $XENV "$HERE/bin/claude" profile 2>&1)
check "shim passes 'profile' through to the wrapper" 'echo "$out" | grep -q "^store: "'

# shellcheck disable=SC2086 # $XENV holds space-separated KEY=VALUE pairs for env to split
out=$(env $XENV _CP_RUNNER="$TMP/fakerunner" "$CPX" --run-active -p hi 2>&1)
check "--run-active passes args through" \
   'echo "$out" | grep -q "CFG=$TMP/xstore/profiles/shimprof ARGS=-p hi"'

check "shim is executable"      '[ -x "$HERE/bin/claude" ]'
check "shim has no CR bytes"    '! grep -q "$(printf "\r")" "$HERE/bin/claude"'
check_with "shim parses under dash" dash 'dash -n "$HERE/bin/claude"'

echo "== Task 20: npm packaging =="

check_with "package.json is valid JSON" node \
   'node -e "JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\"))"'
check_with "package ships the code, not the store" node \
   'node -e "
      const f = JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\")).files;
      const need = [\"claude-profile.sh\",\"lib\",\"bin\",\"claude-profile.psm1\",\"install.sh\",\"install.ps1\"];
      for (const n of need) if (!f.includes(n)) { console.error(\"missing \"+n); process.exit(1); }
      for (const n of [\"profiles\",\"exports\",\".backups\"]) if (f.includes(n)) { console.error(\"ships \"+n); process.exit(1); }
   "'
check_with "postinstall is wired to the dispatcher" node \
   'node -e "
      const p = JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\"));
      if (!/postinstall\.mjs/.test(p.scripts.postinstall)) process.exit(1);
   "'

# npmhome stands in for a real $HOME so the dispatcher's install.sh has
# somewhere to `cd`. Every var the installer reads is pinned here rather than
# inherited: CLAUDE_PROFILES_DIR is exported suite-wide above and has already
# broken three tests this way, and --no-migrate stops migrate_clone_store from
# ever touching $HERE/profiles, the live store of the session running this.
mkdir -p "$TMP/npmhome"
check_with "dispatcher runs the POSIX installer" node \
   'env HOME="$TMP/npmhome" CLAUDE_PROFILES_DIR="$TMP/npmhome/.claude-profiles" \
        CP_RC="$TMP/npmhome/.zshrc" CP_ZSHENV="$TMP/npmhome/.zshenv" \
        CP_LINK_DIR="$TMP/npmhome/.local/bin" \
        CLAUDE_PROFILE_INSTALL_DIR="$TMP/npmhome/.claude-profile" SHELL=/bin/zsh \
        node "$HERE/scripts/postinstall.mjs" --no-migrate >/dev/null 2>&1 &&
    [ -f "$TMP/npmhome/.claude-profile/claude-profile.sh" ]'

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
