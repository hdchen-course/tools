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
#
# We STRIP ':' and '.' from it: tmux target syntax is "session:window.pane", so a
# session name containing those makes every `-t "=name:win"` target mis-parse
# (has-session then always fails → we'd endlessly try to re-create it and hit
# "duplicate session"). Stripping keeps targeting unambiguous; empty falls back.
CSP_TMUX_SESSION="${CSP_TMUX_SESSION:-claude-sessions}"
CSP_TMUX_SESSION="$(printf '%s' "$CSP_TMUX_SESSION" | tr -d ':.')"
[ -z "$CSP_TMUX_SESSION" ] && CSP_TMUX_SESSION="claude-sessions"

# We run our tmux on a DEDICATED SOCKET (tmux -L "$CSP_TMUX_SOCKET"), completely
# separate from the user's normal tmux server. This is what lets us:
#   • set the status bar / base-index / renumber-windows GLOBALLY (so every
#     session window inherits them — window-status-format is a per-window option
#     that a session-scoped set can't reach), WITHOUT polluting the user's own
#     tmux config or other sessions;
#   • never touch the shared root key table.
# In short: everything we configure lives and dies with this socket, so the
# "we never touch your tmux" promise is literally true.
#
# We STRIP '/', ',', '.' and control chars from the socket NAME. Reasons:
#   • '/' or '..' would make `tmux -L` create the socket at an arbitrary path,
#     breaking the "lives and dies with our socket" guarantee;
#   • the TMUX env var is "<socket-path>,<pid>,<session>", and csp_inside_tmux
#     recovers our name as the path's basename by cutting at the first ','. A
#     name containing ',' or '/' would make that recovery wrong, so the picker
#     would think it is OUTSIDE tmux and re-exec into a broken nested attach.
# Empty after stripping falls back to the default.
CSP_TMUX_SOCKET="${CSP_TMUX_SOCKET:-claude-sessions}"
CSP_TMUX_SOCKET="$(printf '%s' "$CSP_TMUX_SOCKET" | tr -d '/,.[:cntrl:]')"
[ -z "$CSP_TMUX_SOCKET" ] && CSP_TMUX_SOCKET="claude-sessions"

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
# dedicated socket). We check that TMUX points at our socket specifically, not
# just that some tmux is present, so launching the picker from inside the user's
# UNRELATED tmux still re-execs into our own socket rather than piggy-backing on
# theirs. TMUX is "<socket-path>,<pid>,<session>"; the socket file's BASENAME is
# our socket name. We compare that basename EXACTLY (not a substring) so
# "claude-sessions" doesn't spuriously match "claude-sessions-extra" or a
# directory that merely ends in the name.
csp_inside_tmux() {
  local t="${TMUX:-}" path base
  [ -n "$t" ] || return 1
  path="${t%%,*}"          # the socket path (before the first comma)
  base="${path##*/}"       # its basename
  [ "$base" = "$CSP_TMUX_SOCKET" ]
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
# tmux rejects names containing newlines, treats a leading '-' as a flag, and
# SPLITS ITS COMMAND LINE on ';' — a name ending in ';' makes tmux parse the
# window's shell command as a second tmux command, so new-window fails. We drop
# ';' entirely, flatten control chars, but KEEP multi-byte (CJK) characters so a
# 工作/專案 project shows as itself rather than collapsing to "_/_". Then trim
# and cap, falling back to "session" if nothing usable is left.
csp_tmux_sanitize_label() {
  local label="$1" clean
  # Remove semicolons (tmux command separator), flatten control chars to spaces,
  # and squeeze repeats; leave other bytes (incl. UTF-8) intact.
  clean=$(printf '%s' "$label" | tr -d ';' | tr '\000-\037\177' ' ' | tr -s ' ')
  clean="${clean#[-_ ]}"                # never start with '-', '_' or space
  clean="${clean%[ ]}"                  # no trailing space
  clean="${clean:0:32}"
  clean="${clean%[ ]}"                  # cap may re-expose a trailing space
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

  # Mouse on: without it tmux (default `mouse off`) translates the scroll wheel
  # into arrow keys sent to the program — so scrolling a resumed Claude/shell
  # just walks its input history instead of scrolling the pane, and native
  # terminal scrollback (Shift-scroll) shows content from OUTSIDE the pane. With
  # mouse on, the wheel scrolls the pane / enters copy-mode as expected, and
  # clicking a window in the status bar selects it. Scoped to our dedicated
  # socket, so the user's own tmux config is untouched.
  csp_tmux set-option -g mouse on 2>/dev/null

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
  local self="$1" cmd v val
  csp_inside_tmux && return 0

  # Build the command tmux runs for the picker window, carrying our environment
  # across the re-launch (tmux starts the window with a fresh environment). We
  # prefix with `env VAR=val …` rather than the shell's own `VAR=val cmd` form,
  # because tmux runs the command through the user's DEFAULT-SHELL — which may be
  # csh/tcsh, where `VAR=val cmd` is a syntax error and the window would silently
  # die. `env` is a real program and works under any shell. We forward our CSP_*
  # settings and TMUX_TMPDIR (so `tmux -L` resolves to the SAME socket directory
  # the parent used; otherwise csp_tmux_open could target a different, empty
  # server and every Enter would fall back to hub).
  cmd="env CSP_BACKEND=tmux"
  for v in CSP_CLAUDE_DIR CSP_TMUX_SESSION CSP_TMUX_SOCKET CSP_PREF_FILE CSP_STATE_DIR CSP_NO_COLOR TMUX_TMPDIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && cmd="$cmd $v=$(csp_shell_quote "$val")"
  done
  cmd="$cmd $(csp_shell_quote "$self")"

  if csp_tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null; then
    csp_tmux_configure_home
    # Ensure there's a live menu to land on: if no window is named "menu" (e.g.
    # a previous quit closed it), recreate one and make it window 0. We SWAP it
    # into index 0 rather than move-window -k (which would KILL whatever session
    # occupies index 0 — destroying a running Claude); swap is non-destructive.
    #
    # Every recovery step is CHECKED. Previously the results were ignored and we
    # attached regardless — so if new-window/swap-window failed, the client would
    # land on an arbitrary Claude window with no resident menu while the status
    # bar still claimed window 0 was the menu. If recovery can't complete we
    # return non-zero so the caller falls back to hub instead of attaching into a
    # menu-less, misleading state.
    if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_name}' 2>/dev/null \
         | grep -qx menu; then
      csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "$cmd" 2>/dev/null || return 1
      csp_tmux swap-window -s "=$CSP_TMUX_SESSION:\$" -t "=$CSP_TMUX_SESSION:0" 2>/dev/null || return 1
      # Confirm the recovery actually produced a menu window at index 0 before we
      # commit to attaching (belt-and-suspenders against a partial swap).
      csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null \
        | grep -qx '0:menu' || return 1
    fi
    csp_tmux_record_launch_pwd    # so `n` follows where this client re-attached
    # exec the REAL tmux (a bare `exec csp_tmux` fails — exec can't run a shell
    # function). If exec somehow can't replace us, return non-zero so the caller
    # restores the terminal instead of falling through in a broken state.
    exec command tmux -L "$CSP_TMUX_SOCKET" attach-session -t "=$CSP_TMUX_SESSION"
    return 1
  fi

  # Fresh: create the holding session with the picker in window 0 (named
  # "menu"), configure it, then attach. Detached-first so options apply before
  # the client draws. If the attach can't happen (exec fails), don't leave the
  # freshly-created detached session orphaned — tear it down and return so the
  # caller falls back to hub cleanly.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "$cmd" 2>/dev/null || return 1
  csp_tmux_configure_home
  csp_tmux_record_launch_pwd    # seed the launch dir for `n` (see helper)
  exec command tmux -L "$CSP_TMUX_SOCKET" attach-session -t "=$CSP_TMUX_SESSION"
  csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null   # only if exec failed
  return 1
}

# csp_tmux_record_launch_pwd — remember the directory the CURRENT client is
# attaching from, so a new session (`n`) opens there rather than in whatever
# directory the resident picker (window 0) was first launched from. Stored as a
# tmux session env var the running picker reads live at press time (see
# csp_tmux_launch_pwd). Called on every attach — fresh or re-attach — so the
# value always reflects the latest client. Best-effort.
csp_tmux_record_launch_pwd() {
  csp_tmux set-environment -t "=$CSP_TMUX_SESSION" CSP_LAUNCH_PWD "$PWD" 2>/dev/null
}

# csp_tmux_launch_pwd — the directory a NEW session (`n`) should start in when
# the picker is running as the resident tmux menu. tmux window 0 keeps the cwd it
# was first launched from, but a later re-attach from another directory records
# that directory in the CSP_LAUNCH_PWD session env var (see csp_tmux_enter). We
# read it live here so `n` follows where you actually re-attached from. Falls
# back to the picker's own $PWD when unset/unreadable or the dir no longer exists.
csp_tmux_launch_pwd() {
  local d
  # When set, tmux prints "CSP_LAUNCH_PWD=/the/path" on stdout; when unset it
  # prints "unknown variable: …" to stderr and exits non-zero. We send stderr to
  # /dev/null, so an unset var yields an empty $d. Stripping only the "NAME="
  # prefix preserves a path that itself contains '='. Any empty/invalid result,
  # or a directory that no longer exists, falls back to the picker's own $PWD.
  d=$(csp_tmux show-environment -t "=$CSP_TMUX_SESSION" CSP_LAUNCH_PWD 2>/dev/null)
  d="${d#CSP_LAUNCH_PWD=}"
  [ -n "$d" ] && [ -d "$d" ] || d="$PWD"
  printf '%s' "$d"
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
  local id="$1" project="$2" label="$3" cmd win existing

  label=$(csp_tmux_sanitize_label "$label")

  # Don't open a SECOND window for a session already running in this holding
  # session: resuming the same transcript twice means two Claude processes
  # writing the same conversation. Each session window is tagged with a
  # `@csp_sid` window option (set below); if one already carries this id, just
  # switch to it. Only meaningful for a real resume — a brand-new session ("new")
  # has no id yet, so it always opens fresh.
  if [ "$id" != "new" ]; then
    # Find a window already tagged with this session id. Each line is
    # "<window_id> <sid>"; awk compares the WHOLE second field for exact equality
    # ($2 == want), so an id can never match a window whose tag merely contains it
    # (e.g. "id-a" won't match a window tagged "id-abc"), and the empty tag on the
    # menu window can't match a real id. awk (not a `while read` subshell) also
    # keeps the id out of any pattern/glob and reads cleanly under errexit.
    existing=$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" \
      -F '#{window_id} #{@csp_sid}' 2>/dev/null \
      | awk -v want="$id" '$2 == want {print $1; exit}')
    if [ -n "$existing" ]; then
      csp_tmux select-window -t "$existing" 2>/dev/null && return 0
      # If selecting the existing window somehow failed, fall through and open a
      # fresh one rather than leaving the user stuck.
    fi
  fi

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
  # Tag the window with the session id so a later Enter on the same session finds
  # and reuses it (see the dedup check above). Best-effort: a failed tag only
  # means we might later open a duplicate, never a crash.
  [ "$id" != "new" ] && csp_tmux set-option -w -t "$win" '@csp_sid' "$id" 2>/dev/null
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
