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
      { "hooks": [ { "type": "command", "command": "$FAKEHOME/.claude/hooks/demo.sh" } ] }
    ]
  },
  "env": { "TOOL": "$FAKEHOME/.local/bin/tool" }
}
JSON
printf 'printf hud\n' > "$FAKEHOME/.claude/statusline.sh"

HOME="$FAKEHOME"
export HOME
CLAUDE_PROFILES_DIR="$TMP/store"
export CLAUDE_PROFILES_DIR
mkdir -p "$CLAUDE_PROFILES_DIR"

. "$HERE/claude-profile.sh"

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
check "status names source"   '_cp_main | grep -q "active"'

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

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
