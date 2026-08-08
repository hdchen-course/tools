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

# We run our tmux on a DEDICATED SOCKET (tmux -L "$CSP_TMUX_SOCKET"), completely
# separate from the user's normal tmux server. This is what lets us:
#   • set the status bar / base-index / renumber-windows GLOBALLY (so every
#     session window inherits them — window-status-format is a per-window option
#     that a session-scoped set can't reach), WITHOUT polluting the user's own
#     tmux config or other sessions;
#   • never touch the shared root key table.
# In short: everything we configure lives and dies with this socket, so the
# "we never touch your tmux" promise is literally true.
CSP_TMUX_SOCKET="${CSP_TMUX_SOCKET:-claude-sessions}"

# csp_tmux — run tmux on our dedicated socket. Every tmux call in this file goes
# through this wrapper so the socket is applied consistently in one place.
csp_tmux() {
  command tmux -L "$CSP_TMUX_SOCKET" "$@"
}

# csp_tmux_available — returns 0 if the tmux command exists, else 1.
csp_tmux_available() {
  command -v tmux >/dev/null 2>&1
}

# csp_inside_tmux — returns 0 if we are currently running inside OUR tmux (the
# dedicated socket). We check that TMUX points at our socket, not just that some
# tmux is present, so that launching the picker from inside the user's UNRELATED
# tmux still correctly re-execs into our own socket rather than piggy-backing on
# theirs. TMUX looks like "<socket-path>,<pid>,<session>".
csp_inside_tmux() {
  case "${TMUX:-}" in
    *"/$CSP_TMUX_SOCKET,"*|*"/$CSP_TMUX_SOCKET-"*) return 0 ;;
  esac
  return 1
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

# csp_tmux_sanitize_label LABEL — make a safe, non-empty tmux window name.
# tmux rejects names containing newlines and treats a leading '-' as a flag, so
# we replace disallowed BYTES with '_' but KEEP multi-byte (CJK) characters, so
# a 工作/專案 project name shows as itself rather than collapsing to "_/_". We
# then trim and cap it, falling back to "session" if nothing usable is left.
csp_tmux_sanitize_label() {
  local label="$1" clean
  # Flatten only control chars and the few characters tmux/globbing dislike;
  # leave everything else (including UTF-8 bytes) intact.
  clean=$(printf '%s' "$label" | tr '\000-\037\177' ' ' | tr -s ' ')
  clean="${clean#[-_ ]}"                # never start with '-', '_' or space
  clean="${clean%[ ]}"                  # no trailing space
  clean="${clean:0:32}"
  [ -z "$clean" ] && clean="session"
  printf '%s' "$clean"
}

# csp_tmux_configure_home — configure our dedicated-socket tmux server so the
# holding session is easy to navigate, WITHOUT touching the user's config.
# Because we run on our own socket (csp_tmux / -L), we can safely set options
# GLOBALLY (-g): they apply to every window we open — crucial because
# window-status-format is a per-window option a session-scoped set can't reach —
# yet they live only on this socket and vanish when it does. All best-effort.
csp_tmux_configure_home() {
  # Window numbering: force base 0 and keep it gapless, so "window 0 = menu" and
  # "Ctrl-b <n> = the nth session" are always true regardless of the user's own
  # base-index, and numbers don't go stale after a session is closed.
  csp_tmux set-option -g base-index 0 2>/dev/null
  csp_tmux set-option -g renumber-windows on 2>/dev/null

  csp_tmux set-option -g status on 2>/dev/null
  csp_tmux set-option -g status-interval 2 2>/dev/null
  csp_tmux set-option -g status-justify left 2>/dev/null
  # Keep status-left tiny so the window list (the map of what's open) has room
  # even at 80 columns.
  csp_tmux set-option -g status-left "" 2>/dev/null
  csp_tmux set-option -g status-left-length 0 2>/dev/null
  # Each window is a session: number + name, name truncated to 9 display cells
  # so several fit at 80 cols. Current window highlighted so you see where you are.
  csp_tmux set-option -g window-status-format " #I #{=9:window_name} " 2>/dev/null
  csp_tmux set-option -g window-status-current-format "#[reverse,bold] #I #{=9:window_name} #[default]" 2>/dev/null
  # Always-visible hint — this is the fix for "Ctrl-b gives no feedback": the
  # keys are on screen at all times. Kept short so it fits beside the window list.
  csp_tmux set-option -g status-right " Ctrl-b 0=menu n/p=switch w=list d=detach " 2>/dev/null
  csp_tmux set-option -g status-right-length 44 2>/dev/null
  csp_tmux set-option -g display-time 1500 2>/dev/null
}

# csp_tmux_enter SELF_PATH — put the picker itself inside the holding tmux
# session (on our dedicated socket) as window 0, so it stays resident as your
# "home base".
#
# The model: tmux mode runs everything inside one tmux session on our own socket.
# The picker lives in window 0 ("menu"); each session you open becomes window
# 1, 2, … You return to the picker with Ctrl-b 0 and switch between running
# sessions with Ctrl-b n/p/w — all of them stay alive in the background. A
# persistent status bar (see csp_tmux_configure_home) lists the windows and
# spells out those keys, so the Ctrl-b prefix is no longer invisible.
#
# Only relevant when we are NOT yet inside OUR tmux. It creates the holding
# session running THIS picker (via SELF_PATH) in window 0 and attaches, then
# never returns (exec replaces us). The re-launched picker comes back here
# already inside our tmux and just runs its menu loop. If a holding session
# already exists, we (re)configure and attach; but if its window 0 is no longer
# a picker (e.g. the user pressed q, killing the menu window), we recreate the
# menu window first so "attach" always lands you on a working menu.
csp_tmux_enter() {
  local self="$1" env_prefix v val
  csp_inside_tmux && return 0

  # Build the command tmux runs for the picker window, carrying our CSP_* env
  # across the re-launch (tmux starts it with a fresh environment). Quoted.
  env_prefix="CSP_BACKEND=tmux CSP_IN_TMUX_HOME=1"
  for v in CSP_CLAUDE_DIR CSP_TMUX_SESSION CSP_TMUX_SOCKET CSP_PREF_FILE CSP_STATE_DIR CSP_NO_COLOR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && env_prefix="$env_prefix $v=$(csp_shell_quote "$val")"
  done

  if csp_tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null; then
    csp_tmux_configure_home
    # Ensure there's a live menu to land on: if window 0 isn't named "menu",
    # (re)create it so quitting the menu earlier can't strand you.
    if [ "$(csp_tmux display-message -p -t "=$CSP_TMUX_SESSION:0" '#{window_name}' 2>/dev/null)" != "menu" ]; then
      csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "$env_prefix $(csp_shell_quote "$self")" 2>/dev/null
      csp_tmux move-window -s "=$CSP_TMUX_SESSION:\$" -t "=$CSP_TMUX_SESSION:0" 2>/dev/null
    fi
    exec csp_tmux attach-session -t "=$CSP_TMUX_SESSION"
  fi

  # Fresh: create the holding session with the picker in window 0 (named
  # "menu"), configure it, then attach. Detached-first so options apply before
  # the client draws.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu \
    "$env_prefix $(csp_shell_quote "$self")" 2>/dev/null || return 1
  csp_tmux_configure_home
  exec csp_tmux attach-session -t "=$CSP_TMUX_SESSION"
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

  # Open the session in a new window on our socket (target the holding session
  # explicitly so it lands there even if the caller's notion of "current" drifts)
  # and select it. -P -F prints the new window id so we select exactly it. The
  # picker's own loop keeps running in window 0 the whole time.
  win=$(csp_tmux new-window -t "=$CSP_TMUX_SESSION" -P -F '#{window_id}' -n "$label" "$cmd" 2>/dev/null) \
    || return 1
  csp_tmux select-window -t "$win" 2>/dev/null || return 1
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
