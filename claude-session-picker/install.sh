#!/usr/bin/env bash
# =============================================================================
# install.sh — set up the Claude Session Picker with one command.
#
# WHAT IT DOES (plain language):
#   Creates a symlink to the `claude-session-picker` command in a directory on
#   your PATH, so you can run it from anywhere. It uses a symlink — not a copy —
#   so a future `git pull` updates the installed tool automatically.
#
#   That's it. The tool has NO other dependencies: it reads Claude Code's own
#   session files and uses the `claude` command you already have. Nothing is
#   downloaded or compiled, so this works the same on a Mac or a bare remote
#   Linux host.
#
# It is safe to run more than once, and everything it does is undone by
# uninstall.sh.
#
# Usage:
#   ./install.sh                 install to ~/.local/bin
#   ./install.sh --prefix DIR    install the symlink into DIR instead
#   ./install.sh --force         overwrite an existing symlink/file at the target
# =============================================================================

set -eu

PREFIX="$HOME/.local/bin"
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- Sanity check: is the `claude` command present? -------------------------
# Not fatal — you might install the picker before Claude Code — but worth
# telling the user, since the picker can't resume anything without it.
if command -v claude >/dev/null 2>&1; then
  say "✓ claude found: $(command -v claude)"
else
  warn "! 'claude' is not on your PATH yet. Install Claude Code before using"
  warn "  the picker: https://claude.com/claude-code"
fi

# --- Symlink the command -----------------------------------------------------
mkdir -p "$PREFIX"
chmod +x "$ROOT/bin/claude-session-picker"

DST="$PREFIX/claude-session-picker"
if [ -e "$DST" ] || [ -L "$DST" ]; then
  if [ "$FORCE" -eq 1 ]; then
    rm -f "$DST"
  else
    warn "Already exists (use --force to overwrite): $DST"
    exit 1
  fi
fi
ln -s "$ROOT/bin/claude-session-picker" "$DST"
say "Linked $DST -> $ROOT/bin/claude-session-picker"

# --- Optional enhancement: tmux for concurrent sessions ----------------------
# The tool works with ZERO dependencies in "hub" mode (one session at a time).
# If tmux is present it automatically upgrades to "tmux" mode, where several
# sessions run at once in the background. We only OFFER to install it — the tool
# is fully functional without it, so we never require it.
if command -v tmux >/dev/null 2>&1; then
  say "✓ tmux found — concurrent multi-session (tmux mode) is available."
else
  say ""
  say "Optional: install tmux to run multiple sessions at the SAME time"
  say "(without it, the picker runs one session at a time — still fully usable)."
  if command -v brew >/dev/null 2>&1; then
    printf 'Install tmux now with Homebrew? [y/N] '
    read -r reply
    case "$reply" in
      y|Y) brew install tmux && say "✓ tmux installed — concurrent mode unlocked." ;;
      *)   say "Skipped. You can install it later with: brew install tmux" ;;
    esac
  else
    say "To enable it later: install tmux via your package manager"
    say "(macOS: brew install tmux   |   Debian/Ubuntu: sudo apt install tmux)."
  fi
fi

# --- PATH reminder -----------------------------------------------------------
case ":$PATH:" in
  *":$PREFIX:"*) : ;;
  *)
    say ""
    say "NOTE: $PREFIX is not on your PATH. Add this to your shell rc"
    say "      (~/.zshrc or ~/.bashrc):"
    say ""
    say "        export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

say ""
say "Done. Run:  claude-session-picker"
say ""
say "Tip: bind it to a shell key for instant access. For zsh, add to ~/.zshrc:"
say "        bindkey -s '^S' 'claude-session-picker\\n'   # Ctrl-S opens the picker"
