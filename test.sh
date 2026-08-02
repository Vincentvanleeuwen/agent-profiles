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
( cd "$TMP/repo/nested/deep" && eq "pin beats active" "$(_cp_selected)" "fin" )
( cd "$TMP/repo/nested/deep" && CLAUDE_PROFILE=other _cp_selected >/dev/null
  eq "env beats pin" "$(cd "$TMP/repo" && CLAUDE_PROFILE=other _cp_selected)" "other" )

printf 'ghost\n' > "$TMP/store/active"
eq "unknown profile falls back to base" "$(_cp_resolve 2>/dev/null)" "$FAKEHOME/.claude"
check "unknown profile warns on stderr" '[ -n "$(_cp_resolve 2>&1 >/dev/null)" ]'

rm -f "$TMP/store/active"
eq "no active resolves to base" "$(_cp_resolve)" "$FAKEHOME/.claude"
_cp_selected >/dev/null
eq "no active has source none" "$_CP_SRC" "none"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
