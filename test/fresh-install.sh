#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-profiles-fresh.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

if [ "$#" -gt 0 ]; then
    PACKAGE=$1
else
    env npm_config_cache="$TMP_ROOT/npm-cache" \
        npm pack "$ROOT" --pack-destination "$TMP_ROOT" >/dev/null
    set -- "$TMP_ROOT"/agent-profiles-*.tgz
    [ -f "$1" ] || { printf 'fresh-install: npm pack produced no tarball\n' >&2; exit 1; }
    PACKAGE=$1
fi

case "$PACKAGE" in
    /*) ;;
    *) PACKAGE="$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")" ;;
esac

FAKE_HOME="$TMP_ROOT/home"
STORE="$FAKE_HOME/.agent-profiles"
INSTALL="$FAKE_HOME/.agent-profile"
PREFIX="$TMP_ROOT/npm-prefix"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$PREFIX"
printf '{"model":"default-marker"}\n' > "$FAKE_HOME/.claude/settings.json"
printf 'model = "default-marker"\n' > "$FAKE_HOME/.codex/config.toml"

run_env() {
    env HOME="$FAKE_HOME" CLAUDE_PROFILES_DIR="$STORE" \
        CLAUDE_PROFILE_INSTALL_DIR="$INSTALL" CP_RC="$FAKE_HOME/.zshrc" \
        CP_ZSHENV="$FAKE_HOME/.zshenv" CP_LINK_DIR="$FAKE_HOME/.local/bin" \
        npm_config_cache="$TMP_ROOT/npm-cache" \
        SHELL=/bin/zsh PATH="$FAKE_HOME/.local/bin:$PREFIX/bin:$PATH" "$@"
}

run_env npm install --global --prefix "$PREFIX" "$PACKAGE"
run_env agent-profile --create fresh
run_env agent-profile fresh
[ "$(cat "$STORE/active")" = fresh ]
[ "$(readlink "$FAKE_HOME/.codex/config.toml")" = "$STORE/profiles/fresh/codex.config.toml" ]
run_env agent-profile default
[ ! -e "$STORE/active" ]
grep -q 'default-marker' "$FAKE_HOME/.codex/config.toml"
run_env agent-profile-install --uninstall
[ ! -e "$INSTALL" ]
[ -d "$STORE/profiles/fresh" ]
printf 'fresh POSIX package install passed\n'
