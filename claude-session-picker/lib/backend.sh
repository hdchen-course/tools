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

# csp_tmux_sanitize_label LABEL — make a safe, non-empty tmux window name.
# tmux rejects names containing newlines and treats a leading '-' as a flag, so
# we keep only tame characters and fall back to "session" if nothing is left.
# Returned via stdout.
csp_tmux_sanitize_label() {
  local label="$1" clean
  clean=$(printf '%s' "$label" | tr -c 'A-Za-z0-9._/-' '_' | tr -s '_')
  clean="${clean#[-_]}"                 # never start with '-' or '_'
  clean="${clean:0:40}"
  [ -z "$clean" ] && clean="session"
  printf '%s' "$clean"
}

# csp_tmux_open ID PROJECT LABEL
#
# Open a session in its own tmux window and focus it. Other windows keep running
# in the background — this is the concurrency the tmux backend exists to give.
#
#   ID       session id to resume, or "new" for a fresh session
#   PROJECT  working directory to start in (optional)
#   LABEL    short human name for the tmux window (sanitized here)
#
# Returns 0 on success, NON-ZERO if the window could not be created or focused.
# The caller MUST check this: a silent failure would make the picker vanish with
# nothing opened. We build the command as a string for tmux to run; ID/PROJECT
# come from our own session files and are single-quoted, so there is no room for
# shell injection.
#
# When we are already inside tmux we create the window in the CURRENT session
# (so we never yank the user out of their own long-lived tmux work into our
# holding session), and select it. Otherwise we create it in the dedicated
# holding session and attach to that.
csp_tmux_open() {
  local id="$1" project="$2" label="$3" cmd target win

  label=$(csp_tmux_sanitize_label "$label")

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

  if csp_inside_tmux; then
    # Already in tmux: open in the user's current session and switch to it.
    # -P -F prints the new window id so we can select exactly that window.
    win=$(tmux new-window -P -F '#{window_id}' -n "$label" "$cmd" 2>/dev/null) \
      || return 1
    tmux select-window -t "$win" 2>/dev/null || return 1
  else
    # Not in tmux: use (creating if needed) the dedicated holding session.
    csp_tmux_ensure_session || return 1
    target="$CSP_TMUX_SESSION"
    tmux new-window -t "=$target" -n "$label" "$cmd" 2>/dev/null || return 1
    tmux attach-session -t "=$target" 2>/dev/null || return 1
  fi
  return 0
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
