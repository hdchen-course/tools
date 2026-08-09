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

# --- Static analysis (optional) ----------------------------------------------
# Run shellcheck if it's installed; skip cleanly if not (same self-skip spirit as
# the tmux tests). 2267 lines of subtle bash — locale toggles, BSD/GNU
# divergence, bash-3.2-only syntax — get zero protection from the runtime tests
# alone, so a static pass catches a bash-4-ism (mapfile, ${x,,}) that would parse
# fine here yet break on the macOS system bash we target.
#
# Excludes (each a deliberate project decision, not a blanket mute):
#   SC2004 style-only "$/${} unnecessary in arithmetic" — we keep ${} for
#          readability in array indexing.
#   SC2034 "appears unused" — false for us: the tool is ONE program split across
#          sourced files, so globals set in one file and read in another (e.g.
#          the CSP_C_* colours, the box-drawing chars, __csp_fit/__csp_bl) look
#          unused to a per-file check. The entrypoint pass uses -x to follow
#          sources, but the standalone lib passes still can't see the reader.
#   SC1091 "not following source" — the -x pass resolves them; harmless.
#   SC2093 the intentional `exec …; return 1` tmux fallback (we WANT to continue
#          if exec somehow fails).
#   SC2016 a literal `claude` in single quotes inside a user-facing message.
PROJ="$(cd "$HERE/.." && pwd)"
SHELLCHECK="$(command -v shellcheck 2>/dev/null || true)"
if [ -n "$SHELLCHECK" ]; then
  printf '== static analysis (shellcheck %s) ==\n' "$("$SHELLCHECK" --version | awk '/version:/{print $2}')"
  SC_EXCLUDE="SC2004,SC2093,SC2016,SC2034,SC1091"
  # Entrypoint: run from bin/ so its `# shellcheck source=../lib/*` directives
  # resolve, and follow them with -x for whole-program checking.
  ( cd "$PROJ/bin" && "$SHELLCHECK" -x -s bash --exclude="$SC_EXCLUDE" claude-session-picker )
  # Libraries, hook and installers: each is valid standalone bash.
  "$SHELLCHECK" -s bash --exclude="$SC_EXCLUDE" \
    "$PROJ/lib/core.sh" "$PROJ/lib/sessions.sh" "$PROJ/lib/backend.sh" \
    "$PROJ/hooks/csp-hook.sh" "$PROJ/install.sh" "$PROJ/uninstall.sh"
  printf 'shellcheck: clean\n'
else
  printf '== static analysis: SKIPPED (shellcheck not installed) ==\n'
fi

printf '\n== unit tests (pure logic) ==\n'
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

printf '\n== hook tests (●/✳ state recording) ==\n'
"$BATS" "$HERE/hook.bats"

printf '\n== tmux backend tests (real tmux on a throwaway socket) ==\n'
"$BATS" "$HERE/tmux.bats"

printf '\n== CLI flag tests (--version / --help / --doctor / --list) ==\n'
"$BATS" "$HERE/cli.bats"

printf '\n== render tests (legend fit, filter status bar, no-match hint) ==\n'
"$BATS" "$HERE/render.bats"
