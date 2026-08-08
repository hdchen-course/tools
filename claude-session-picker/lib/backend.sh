# shellcheck shell=bash
# =============================================================================
# backend.sh — HOW sessions are actually run. Two interchangeable backends.
#
# WHY THIS FILE EXISTS (for non-coders):
#   There are two ways to "run" a Claude session from the menu, and which one we
#   use depends on whether the `tmux` tool is available:
#
#     • HUB backend (needs nothing installed): runs one session at a time in
#       this terminal. When that session exits you come straight back to the
#       menu to pick another. Nothing is lost between switches because Claude
#       saves everything to disk as you go. Works on any Mac or Linux box,
#       including a bare Linux host.
#
#     • TMUX backend (needs the `tmux` tool): puts each session in its own tmux
#       "window". Switching to another session leaves the others RUNNING in the
#       background, so several agents can make progress at the same time.
#
#   The pure function csp_choose_backend (in core.sh) decides which to use; this
#   file contains the two implementations. Keeping them side by side behind the
#   same small set of function names means the menu code never has to care which
#   one is active.
# =============================================================================

# The name of the single tmux session that holds all our Claude windows. Using
# one well-known name means re-running the picker re-attaches to the same place
# instead of spawning duplicates.
CSP_TMUX_SESSION="${CSP_TMUX_SESSION:-claude-sessions}"

# csp_tmux_available — returns 0 if the tmux command exists, else 1.
csp_tmux_available() {
  command -v tmux >/dev/null 2>&1
}

# csp_inside_tmux — returns 0 if we are currently running inside tmux.
# tmux sets the TMUX environment variable for every program it runs.
csp_inside_tmux() {
  [ -n "${TMUX:-}" ]
}

# =============================================================================
# HUB backend — one session at a time, no dependencies.
# =============================================================================

# csp_hub_open ID PROJECT
#
# Run a session in the foreground and WAIT for it to finish, then return so the
# caller can redraw the menu. If ID is the literal string "new", we start a
# fresh Claude instead of resuming.
#
# We run claude in a subshell (parentheses) rather than `exec`, precisely so
# control comes BACK to us when the user exits the session — that "return to the
# menu" behaviour is the whole point of hub mode. cd'ing into the project first
# gives the session its original working directory; a failed cd is non-fatal.
csp_hub_open() {
  local id="$1" project="$2"
  (
    if [ -n "$project" ] && [ -d "$project" ]; then
      cd "$project" 2>/dev/null || true
    fi
    if [ "$id" = "new" ]; then
      claude
    else
      claude --resume "$id"
    fi
  )
}

# =============================================================================
# TMUX backend — many sessions running concurrently in tmux windows.
# =============================================================================

# csp_tmux_ensure_session
#
# Make sure our holding tmux session exists (detached). `new-session -d` creates
# it only if absent; if it already exists tmux reports an error which we ignore.
csp_tmux_ensure_session() {
  tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null && return 0
  tmux new-session -d -s "$CSP_TMUX_SESSION" 2>/dev/null
}

# csp_tmux_open ID PROJECT LABEL
#
# Open a session in its own tmux window and focus it. Other windows keep running
# in the background — this is the concurrency the tmux backend exists to give.
#
#   ID       session id to resume, or "new" for a fresh session
#   PROJECT  working directory to start in (optional)
#   LABEL    short human name for the tmux window
#
# We build the command as a string for tmux to run. ID/PROJECT come from our own
# session files (ids are hex+dashes, projects are real paths), and we quote them
# for the shell tmux spawns, so there is no room for injection.
csp_tmux_open() {
  local id="$1" project="$2" label="$3" cmd

  csp_tmux_ensure_session

  # Compose the shell command the new window will run.
  if [ -n "$project" ] && [ -d "$project" ]; then
    cmd="cd $(csp_shell_quote "$project") && "
  else
    cmd=""
  fi
  if [ "$id" = "new" ]; then
    cmd="${cmd}claude"
  else
    cmd="${cmd}claude --resume $(csp_shell_quote "$id")"
  fi

  # Create the window (running our command) inside the holding session.
  tmux new-window -t "=$CSP_TMUX_SESSION" -n "$label" "$cmd" 2>/dev/null

  # Bring the user to it: switch if we're already in tmux, else attach.
  if csp_inside_tmux; then
    tmux switch-client -t "=$CSP_TMUX_SESSION" 2>/dev/null
  else
    tmux attach-session -t "=$CSP_TMUX_SESSION" 2>/dev/null
  fi
}

# csp_shell_quote STRING — wrap STRING in single quotes for safe use inside a
# command line we hand to tmux, escaping any embedded single quotes. This is
# what guarantees a path or id can never break out of its argument.
csp_shell_quote() {
  local s="$1"
  # Replace every ' with the standard '\'' sequence, then wrap the whole thing.
  s=$(printf '%s' "$s" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$s"
}
