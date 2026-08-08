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
    --prefix)
      # Guard against a missing argument: `--prefix` with nothing after it would
      # otherwise trip `set -u` with an unbound $2 and abort with a cryptic error.
      [ "$#" -ge 2 ] || { printf '%s\n' '--prefix needs a directory argument' >&2; exit 1; }
      PREFIX="$2"; shift 2 ;;
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
if [ -L "$DST" ]; then
  # It's a symlink. Safe to replace on --force (uninstall would remove it too).
  if [ "$FORCE" -eq 1 ]; then
    rm -f "$DST"
  else
    warn "Already exists (use --force to overwrite): $DST"
    exit 1
  fi
elif [ -e "$DST" ]; then
  # It's a REAL file or directory we did not create. We never delete that, even
  # with --force — it could be something the user cares about. Make them move it.
  warn "Refusing to overwrite an existing non-symlink at: $DST"
  warn "Move or remove it yourself, then re-run install."
  exit 1
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
  if command -v brew >/dev/null 2>&1 && [ -t 0 ]; then
    # Only prompt when stdin is an interactive terminal ([ -t 0 ]). When the
    # installer is run non-interactively (e.g. piped from curl, or in CI), a
    # `read` would get EOF and — under `set -e` — abort the whole script AFTER
    # the symlink was already made, falsely reporting failure. In that case we
    # just print guidance and continue.
    printf 'Install tmux now with Homebrew? [y/N] '
    read -r reply || reply=n
    case "$reply" in
      y|Y) brew install tmux && say "✓ tmux installed — concurrent mode unlocked." ;;
      *)   say "Skipped. You can install it later with: brew install tmux" ;;
    esac
  elif command -v brew >/dev/null 2>&1; then
    say "Non-interactive run — skipping the tmux prompt. Install later with: brew install tmux"
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

# --- Optional: live ●/✳ markers via Claude Code hooks ------------------------
# We do NOT edit your Claude settings.json (so we can't corrupt it) — we just
# print the snippet to paste. With the hooks in place, the picker shows ● while
# Claude is working and ✳ when it has stopped and wants you; without them it
# falls back to a simple ● for any running session.
say ""
say "Optional — live status markers (● working / ✳ needs you):"
say "Add these hooks to your Claude Code settings.json (usually ~/.claude/settings.json):"
say ""
say '  "hooks": {'
say '    "UserPromptSubmit": [ { "hooks": [ { "type": "command",'
say "        \"command\": \"$ROOT/hooks/csp-hook.sh working\" } ] } ],"
say '    "Stop": [ { "hooks": [ { "type": "command",'
say "        \"command\": \"$ROOT/hooks/csp-hook.sh waiting\" } ] } ],"
say '    "Notification": [ { "hooks": [ { "type": "command",'
say "        \"command\": \"$ROOT/hooks/csp-hook.sh waiting\" } ] } ]"
say '  }'
say ""
say "These only write a tiny local state file; nothing is sent anywhere."
