#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — cleanly remove everything install.sh created.
#
# WHAT IT DOES (plain language):
#   Removes the `claude-session-picker` command symlink from your bin directory
#   — but ONLY if it actually points back into this repo, so it can never
#   delete an unrelated file that happens to share the name.
#
#   It does NOT touch your Claude Code data (~/.claude): this tool only ever
#   READ those files, so there is nothing of ours to clean up there.
#
# Usage:
#   ./uninstall.sh                 remove from ~/.local/bin
#   ./uninstall.sh --prefix DIR    remove from DIR instead
# =============================================================================

set -eu

PREFIX="$HOME/.local/bin"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      # Guard against a missing argument: `--prefix` with nothing after it would
      # otherwise trip `set -u` with an unbound $2 and abort with a cryptic error.
      [ "$#" -ge 2 ] || { printf '%s\n' '--prefix needs a directory argument' >&2; exit 1; }
      PREFIX="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
say() { printf '%s\n' "$*"; }

DST="$PREFIX/claude-session-picker"
if [ -L "$DST" ]; then
  target="$(readlink "$DST")"
  case "$target" in
    "$ROOT"/*) rm -f "$DST"; say "Removed $DST" ;;
    *) say "Left in place (does not point into this repo): $DST" ;;
  esac
elif [ -e "$DST" ]; then
  say "Left in place (not a symlink): $DST"
else
  say "Nothing to remove at $DST"
fi

say ""
say "Your Claude sessions under ~/.claude were never modified and remain intact."
say ""
say "This tool also kept two small config/state areas of its own. Remove them if"
say "you like (they hold only your mode choice and the ●/✳ markers, no session"
say "data):"
say "  rm -rf \"\${XDG_CONFIG_HOME:-\$HOME/.config}/claude-session-picker\""
say "  rm -rf \"\${XDG_STATE_HOME:-\$HOME/.local/state}/claude-session-picker\""
say ""
say "If you added the picker hooks to ~/.claude/settings.json, remove them by hand"
say "(this tool never edited that file)."
say "Uninstalled."
