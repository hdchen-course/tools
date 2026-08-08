#!/usr/bin/env bash
# =============================================================================
# run-all.sh — run the whole test suite with one command.
#
# Finds a real `bats` (the Bash testing framework), then runs the pure-logic
# unit tests and the tmux integration tests. The integration tests skip
# themselves automatically if tmux isn't installed, so this is safe anywhere.
# =============================================================================

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

# Prefer Homebrew's bats-core if present; fall back to whatever is on PATH.
BATS=""
for candidate in /opt/homebrew/bin/bats /usr/local/bin/bats; do
  [ -x "$candidate" ] && { BATS="$candidate"; break; }
done
[ -z "$BATS" ] && BATS="$(command -v bats 2>/dev/null || true)"

if [ -z "$BATS" ]; then
  printf 'bats not found. Install it with:  brew install bats-core\n' >&2
  exit 1
fi

printf '== unit tests (pure logic) ==\n'
"$BATS" "$HERE/core.bats"

printf '\n== session-store tests (fake ~/.claude) ==\n'
"$BATS" "$HERE/sessions.bats"

printf '\n== backend tests (quoting + hub returns control) ==\n'
"$BATS" "$HERE/backend.bats"

printf '\n== key-decoding tests (arrows, no-op, quit) ==\n'
"$BATS" "$HERE/keys.bats"

printf '\n== install/uninstall tests (arg guard, safe symlink handling) ==\n'
"$BATS" "$HERE/install.bats"

printf '\n== backend-preference tests (the t toggle persistence) ==\n'
"$BATS" "$HERE/pref.bats"
