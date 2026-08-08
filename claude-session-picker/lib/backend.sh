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

# csp_tmux_configure_home — make the holding session friendly to switch in,
# WITHOUT touching the user's ~/.tmux.conf. Everything here is set on our own
# session only. The goal is that you never need to memorise tmux keys:
#   • a visible status bar lists every window (= every session), current one
#     highlighted, so you can SEE what's open;
#   • plain function keys (no prefix) jump straight to a window — F1 = the menu
#     (window 0), F2..F8 = sessions — and the status bar spells that out;
#   • Ctrl-b n/p still work for anyone who prefers them.
# All best-effort: if any set fails we carry on (switching still works, just
# with less polish). Uses the plain session name (tmux set-option rejects "=").
csp_tmux_configure_home() {
  local s="$CSP_TMUX_SESSION"
  tmux set-option -t "$s" status on 2>/dev/null
  tmux set-option -t "$s" status-interval 2 2>/dev/null
  tmux set-option -t "$s" status-justify left 2>/dev/null
  tmux set-option -t "$s" status-left "#[bold] Claude sessions #[default]" 2>/dev/null
  tmux set-option -t "$s" status-left-length 20 2>/dev/null
  # Each window is a session; number + name. The current one is highlighted so
  # you can always SEE where you are and what else is open.
  tmux set-option -t "$s" window-status-format " #I #W " 2>/dev/null
  tmux set-option -t "$s" window-status-current-format "#[reverse,bold] #I #W #[default]" 2>/dev/null
  # The always-visible hint on the right is the fix for "Ctrl-b gives no
  # feedback": it constantly reminds you which keys switch windows and return to
  # the menu (window 0), so nothing has to be memorised.
  tmux set-option -t "$s" status-right "#[bold]Ctrl-b#[default] then: n/p=switch  0=menu  w=list  d=detach " 2>/dev/null
  tmux set-option -t "$s" status-right-length 70 2>/dev/null

  # We deliberately do NOT bind prefix-free F-keys (or any -n key): a root-table
  # binding is server-global and would STEAL that key from Claude Code (and any
  # editor) running inside every window — verified. The standard Ctrl-b prefix,
  # made discoverable by the status bar above, is the safe choice.
  #
  # An earlier build DID bind F1..F8 with `-n`. Those persist server-wide, so
  # proactively remove them here — otherwise upgrading would leave a user's
  # F-keys hijacked for every tmux program. Unbinding a key that isn't bound is
  # a harmless no-op.
  local n=1
  while [ "$n" -le 8 ]; do
    tmux unbind-key -n "F$n" 2>/dev/null
    n=$(( n + 1 ))
  done

  # A safe, non-stealing nicety: keep an on-screen message visible a bit longer.
  tmux set-option -t "$s" display-time 1500 2>/dev/null
}

# csp_tmux_enter SELF_PATH — put the picker itself inside the holding tmux
# session as window 0, so it stays resident as your "home base".
#
# The model: tmux mode runs everything inside one tmux session (default
# "claude-sessions"). The picker lives in window 0; each session you open
# becomes window 1, 2, … You return to the picker with Ctrl-b 0 and switch
# between running sessions with Ctrl-b n/p/w — all of them stay alive in the
# background. A persistent status bar (see csp_tmux_configure_home) lists the
# windows and spells out those keys, so the Ctrl-b prefix is no longer invisible.
#
# This function is only relevant when we are NOT yet inside tmux. It creates the
# holding session running THIS picker (via SELF_PATH) in window 0 and attaches
# to it, then never returns (the exec/attach replaces us). Inside the new tmux
# the picker starts again — this time already inside tmux — and just runs its
# menu loop. If we're already inside tmux, it does nothing and returns 0.
csp_tmux_enter() {
  local self="$1"
  csp_inside_tmux && return 0

  if tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null; then
    # Holding session already exists (from a previous run) — refresh its config
    # and attach; its window 0 is already the picker.
    csp_tmux_configure_home
    exec tmux attach-session -t "=$CSP_TMUX_SESSION"
  fi
  # Build the command tmux will run in window 0: the picker, in tmux mode, with
  # our CSP_* environment carried across the re-launch. We must pass these
  # explicitly because the new process is started by tmux (a fresh environment),
  # not forked from us — otherwise an overridden CSP_CLAUDE_DIR / CSP_TMUX_SESSION
  # / CSP_PREF_FILE / CSP_STATE_DIR would be silently lost. Each value is quoted.
  local env_prefix="CSP_BACKEND=tmux CSP_IN_TMUX_HOME=1"
  local v val
  for v in CSP_CLAUDE_DIR CSP_TMUX_SESSION CSP_PREF_FILE CSP_STATE_DIR CSP_NO_COLOR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && env_prefix="$env_prefix $v=$(csp_shell_quote "$val")"
  done

  # Create the holding session (DETACHED first) with the picker in window 0,
  # named "picker"; configure it so switching is obvious; then attach. Creating
  # detached lets us set options before the client sees the session.
  tmux new-session -d -s "$CSP_TMUX_SESSION" -n picker \
    "$env_prefix $(csp_shell_quote "$self")" 2>/dev/null || return 1
  csp_tmux_configure_home
  exec tmux attach-session -t "=$CSP_TMUX_SESSION"
}

# csp_tmux_open ID PROJECT LABEL
#
# Open a session in its OWN tmux window and switch to it, WITHOUT killing the
# picker — the picker stays in window 0. Other windows keep running in the
# background; that is the concurrency the tmux backend exists to give.
#
#   ID       session id to resume, or "new" for a fresh session
#   PROJECT  working directory to start in (optional)
#   LABEL    short human name for the tmux window (sanitized here)
#
# Returns 0 on success, NON-ZERO if the window could not be created or focused
# (the caller falls back to hub for that one launch). ID/PROJECT come from our
# own session files and are single-quoted, so there is no room for shell
# injection. This assumes we are already inside the holding tmux session (the
# picker put itself there via csp_tmux_enter at startup).
csp_tmux_open() {
  local id="$1" project="$2" label="$3" cmd win

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

  # Open the session in a new window (in the current session = the holding one)
  # and select it. -P -F prints the new window id so we select exactly it. The
  # picker's own loop keeps running in window 0 the whole time.
  win=$(tmux new-window -P -F '#{window_id}' -n "$label" "$cmd" 2>/dev/null) \
    || return 1
  tmux select-window -t "$win" 2>/dev/null || return 1
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
