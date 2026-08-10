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

# --- tmux server ownership identity ------------------------------------------
# A tmux server is treated as OURS only when its server-global @csp_owner option
# equals a PER-INSTANCE token we generated and persisted for this socket. This
# replaces the old "socket name + a menu window" heuristic, which could neither
# avoid a false positive (a user's tmux that happens to be named the same with a
# window called "menu") nor a false negative (our own server whose menu window
# had crashed). A token is:
#   • unguessable by an unrelated tmux — it's random, so a foreign server never
#     matches and is never configured, claimed, or mutated; and
#   • persistent — stored in an owner file keyed to the socket, so the resident
#     picker, a re-launched picker, and the hook (separate processes) all agree.
# When our token and a live server's @csp_owner don't match (foreign server, or
# a legacy/older-build server that predates per-instance tokens), we treat the
# server as NOT ours and fall back to hub rather than claim it. Data safety does
# NOT depend on this recognition: the delete guard's transcript-mtime backstop
# protects a live session regardless of whether its server is recognised.

# csp_tmux_owner_file — the path holding this socket's ownership token, kept
# under the state dir (next to the ●/✳ state) so it persists across picker
# invocations and is readable by the hook.
#
# Keyed on the RESOLVED SOCKET PATH, not just the socket name. Two live servers
# can share a name under different TMUX_TMPDIRs (distinct socket files); keying on
# the name alone would make them share — and clobber — ONE owner file, so
# whichever launched last would orphan the other's recognition (its resident
# picker + hook would re-read a token that no longer matches its own @csp_owner
# and stop treating their own live server as ours). Keying on the full path gives
# each distinct server its own file. When no server is live yet (or tmux can't
# answer), fall back to the name — the only caller in that state is a reader that
# then finds no token, which is the correct "not ours" answer.
#
# $1 (optional) is a PRE-RESOLVED socket path: a caller that already ran
# `display-message -p '#{socket_path}'` (e.g. csp_inside_tmux) passes it so we
# don't fork tmux again just to rebuild the same key — this matters on the hook's
# per-prompt path. Empty/absent → we resolve it ourselves.
#
# The key is an INJECTIVE hex encoding of the full path, NOT a lossy character
# substitution: `tr -c 'A-Za-z0-9._-' '_'` maps distinct paths to the same key
# (e.g. /tmp/a/b and /tmp/a_b both → _tmp_a_b), which would let two real servers
# share — and clobber — one owner file. Byte-wise hex is one-to-one, so every
# distinct socket path gets its own file.
csp_tmux_owner_file() {
  local key lpath="${1:-}"
  [ -n "$lpath" ] || lpath=$(command tmux -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}' 2>/dev/null)
  [ -n "$lpath" ] || lpath="$CSP_TMUX_SOCKET"
  key=$(printf '%s' "$lpath" | od -An -tx1 2>/dev/null | tr -d ' \n')
  # Fallback if od is somehow unavailable: lossy but still deterministic (only
  # reached on a machine without od, where a path collision is a non-issue).
  [ -n "$key" ] || key=$(printf '%s' "$lpath" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/tmux-owner.%s' "$CSP_STATE_DIR" "$key"
}

# csp_tmux_owner_token — print the persisted ownership token for this socket, or
# nothing if none has been established yet. Always returns 0.
# $1 (optional) is a pre-resolved socket path, forwarded to csp_tmux_owner_file.
# We refuse to follow a symlink at the path (a planted link could otherwise
# redirect the read) and read a BOUNDED amount — the token is a fixed-shape
# "csp-<hex>" value, so a fixed cap can never be a hot-path latency hazard even if
# the file were somehow replaced by a huge one.
csp_tmux_owner_token() {
  local f v=""
  f=$(csp_tmux_owner_file "${1:-}")
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    { IFS= read -r -n 96 v < "$f"; } 2>/dev/null
  fi
  v="${v%$'\r'}"
  # Accept only the exact shape we write: "csp-" then one or more [A-Za-z0-9-].
  # Anything else (tampered, truncated, garbage) reads as no token — i.e. "not
  # ours", the safe answer.
  case "$v" in
    csp-*[!A-Za-z0-9-]*) v="" ;;   # has a disallowed char after the prefix
    csp-?*) ;;                     # csp- + at least one valid char → keep
    *) v="" ;;                     # missing prefix / empty
  esac
  printf '%s' "$v"
}

# csp_tmux_new_owner_token — generate a fresh random token and persist it as this
# socket's owner token (called when we create a brand-new server). Prints the
# token. Random bytes from /dev/urandom; a pid/RANDOM fallback keeps it working
# on a machine without it (uniqueness, not cryptographic secrecy, is what we
# need in the single-user local model).
#
# The write is HARDENED: dir 0700, file 0600, and atomic (temp file + rename, so a
# concurrent reader never sees a truncated token, and the rename REPLACES any
# pre-planted symlink at the path rather than following it). Best-effort — a
# failed persist just means the next reader finds no token ("not ours" → hub).
csp_tmux_new_owner_token() {
  local tok f d tmp
  tok=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$tok" ] || tok="$$${RANDOM:-0}${RANDOM:-0}$(date +%s 2>/dev/null || echo 0)"
  # Keep the persisted token to [A-Za-z0-9-] so the read-back shape check accepts
  # it (the fallback form above could contain other chars on an odd machine).
  tok=$(printf '%s' "$tok" | tr -cd 'A-Za-z0-9')
  tok="csp-$tok"
  f=$(csp_tmux_owner_file); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null
  chmod 700 "$d" 2>/dev/null || true
  tmp="$f.$$.tmp"
  { printf '%s\n' "$tok" > "$tmp"; } 2>/dev/null || { printf '%s' "$tok"; return 0; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$f" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  printf '%s' "$tok"
}

# csp_inside_tmux — returns 0 if we are currently running inside OUR OWN picker
# tmux (the dedicated server, in our holding session), not just any tmux. All of:
#   1. the $TMUX socket path's BASENAME equals our socket name (cheap; compared
#      EXACTLY so "claude-sessions" != "claude-sessions-extra"); AND
#   2. the CURRENT session is our holding session ($CSP_TMUX_SESSION) — so an
#      environment pointing at a different session/instance on a same-named
#      socket isn't accepted while our csp_tmux ops would target another; AND
#   3. the ambient server's @csp_owner equals OUR persisted per-instance token,
#      proving we created this exact server. An empty token (none established) or
#      a mismatch (a foreign or legacy/markerless server) → not ours. Data safety
#      does NOT rely on this: even when a live bare session sits in a server we no
#      longer recognise, the delete guard's transcript-mtime backstop still
#      protects it (see csp_delete_would_hit_live).
# The socket-path/session queries use the ambient $TMUX (no -L), so they ask the
# very server we're inside; the token comparison binds that server to the exact
# instance we minted. Any tmux error → treated as not-ours (fail closed).
csp_inside_tmux() {
  local t="${TMUX:-}" path lpath tok owner cur
  [ -n "$t" ] || return 1
  path="${t%%,*}"          # the ambient server's socket path (before 1st comma)
  # BIND ambient to -L: the socket the ambient $TMUX names must be the SAME file
  # that our `tmux -L "$CSP_TMUX_SOCKET"` resolves to. Otherwise csp_inside_tmux
  # could say "yes" for one instance while every csp_tmux op (and the delete
  # guard's window lookup) targets another — a same-name socket under a different
  # TMUX_TMPDIR. Comparing the full resolved socket paths keeps identity and
  # routing on the same server.
  lpath=$(command tmux -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}' 2>/dev/null) || return 1
  [ -n "$lpath" ] && [ "$path" = "$lpath" ] || return 1
  # Must be inside our holding session (per-instance identity, not just socket).
  cur=$(command tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
  [ "$cur" = "$CSP_TMUX_SESSION" ] || return 1
  # Ours iff the ambient server's @csp_owner equals OUR persisted token. A
  # non-empty token that matches proves we created this exact server; an empty
  # token (none established) or a mismatch (foreign / legacy) → not ours.
  tok=$(csp_tmux_owner_token "$lpath")   # reuse the path we already resolved
  [ -n "$tok" ] || return 1
  owner=$(command tmux show-options -gv @csp_owner 2>/dev/null) || return 1
  [ "$owner" = "$tok" ]
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

# csp_tmux_server_is_ours — return 0 if the tmux server on OUR -L socket is one
# the picker owns, and is therefore safe to (re)configure and attach to. This is
# decided ONLY by the ownership token, never the socket name or window shape: a
# user could run their own tmux on the exact same -L socket name (even with a
# session named "claude-sessions" and a window named "menu"), and configuring or
# claiming it would break the "we never touch your tmux" promise. We require the
# server's @csp_owner to equal OUR persisted per-instance token — an unguessable
# value only a server WE created carries. A foreign server (no token, or a
# different one) and a legacy/older-build server (no per-instance token) are both
# correctly judged NOT ours; we fall back to hub rather than claim them. (Data
# safety doesn't hinge on this — the delete guard's mtime backstop is
# ownership-independent.)
csp_tmux_server_is_ours() {
  csp_tmux_available || return 1
  local tok owner
  tok=$(csp_tmux_owner_token)
  [ -n "$tok" ] || return 1                      # no token established → not ours
  owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null) || return 1
  [ "$owner" = "$tok" ]
}

# csp_tmux_configure_home — configure our dedicated-socket tmux server so the
# holding session is easy to navigate, WITHOUT touching the user's config.
# Because we run on our own socket (csp_tmux / -L), we can safely set options
# GLOBALLY (-g): they apply to every window we open — crucial because
# window-status-format is a per-window option a session-scoped set can't reach —
# yet they live only on this socket and vanish when it does. All best-effort.
csp_tmux_configure_home() {
  # Stamp our per-instance ownership token as the server-global @csp_owner option
  # so csp_inside_tmux / csp_tmux_server_is_ours can later prove this exact server
  # is ours (see the ownership-identity section). The token comes from our owner
  # file; the fresh path generates it just before the first configure. Set on our
  # dedicated socket only, so it never leaks to a user's server.
  csp_tmux set-option -g @csp_owner "$(csp_tmux_owner_token)" 2>/dev/null

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
    # Before touching ANY global option on this server, make sure it's really
    # ours — a user could have an unrelated tmux on the exact same -L socket
    # name. If it isn't ours we must NOT claim or mutate it (that would break the
    # "we never touch your tmux" promise); return non-zero so the caller falls
    # back to hub. (csp_tmux_server_is_ours requires our per-instance token as
    # @csp_owner — a legacy or foreign server that merely shares the socket name
    # and window shape is correctly refused, and we fall back to hub.)
    csp_tmux_server_is_ours || return 1
    csp_tmux_configure_home
    # Guarantee window 0 IS a menu before we attach — otherwise the client lands
    # on an arbitrary Claude window with no resident picker while the status bar
    # still claims window 0 is the menu. We must handle THREE states, not just
    # "no menu at all": (a) no menu window anywhere → create one; (b) a menu
    # window exists but at a NON-ZERO index (e.g. left orphaned by an earlier
    # partial recovery) → swap it to 0; (c) already 0:menu → nothing to do. Every
    # step is checked; if we can't end at 0:menu we return non-zero so the caller
    # falls back to hub rather than attaching into a menu-less, misleading state.
    # We SWAP into index 0 (never move-window -k, which would KILL whatever
    # occupies 0 — destroying a running Claude); swap is non-destructive.
    if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null \
         | grep -qx '0:menu'; then
      # Create a menu window only if none exists at all; otherwise reuse the one
      # that's already there (at whatever index) and just swap it to 0.
      if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_name}' 2>/dev/null \
           | grep -qx menu; then
        csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "$cmd" 2>/dev/null || return 1
      fi
      # Swap the (now-guaranteed-to-exist) menu window into index 0. `:menu`
      # targets it by name regardless of its current index.
      csp_tmux swap-window -s "=$CSP_TMUX_SESSION:menu" -t "=$CSP_TMUX_SESSION:0" 2>/dev/null || return 1
      # Confirm we really ended at 0:menu before committing to attach.
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

  # We reach here because our holding session does NOT exist on this socket. That
  # has two very different causes, and we must tell them apart before creating
  # anything: (1) there is NO tmux server on this -L socket at all → safe to
  # create ours; (2) a server IS already alive here but it's the user's own
  # (a session not named ours) → we must NOT create a session on it, because the
  # very next step (csp_tmux_configure_home) would set GLOBAL options and stamp
  # our marker on THEIR server. `csp_tmux_server_is_ours` can't distinguish these
  # (a truly-empty socket also isn't "ours"), so we check liveness first: if a
  # server responds AND it isn't ours, refuse and fall back to hub.
  if csp_tmux list-sessions >/dev/null 2>&1 && ! csp_tmux_server_is_ours; then
    return 1
  fi

  # Fresh: create the holding session with the picker in window 0 (named "menu"),
  # configure it, then attach. Detached-first so options apply before the client
  # draws.
  #
  # ORDERING MATTERS: we must NOT start the picker child before @csp_owner is set,
  # or that child can run csp_inside_tmux before the marker exists, decide it is
  # "not inside our tmux", and re-enter csp_tmux_enter (a confusing tmux-inside-
  # tmux attempt that then falls back to hub). So we create window 0 running a
  # tiny BOOTSTRAP placeholder (a shell that just waits), mint the token, configure
  # the server (which stamps the token as the marker), and only THEN respawn window
  # 0 with the real picker command. By the time the picker runs, the marker is
  # already set, so its csp_inside_tmux returns true immediately. The placeholder
  # shell is POSIX (`sh -c` + a plain `sleep`) so it works under any default shell;
  # the 2147483647 is INT_MAX seconds (~68y) — a portable "sleep effectively
  # forever" that avoids the non-POSIX `sleep infinity` (unsupported by macOS/BSD).
  #
  # Create the server FIRST, then mint the token. The owner file is keyed on the
  # resolved socket PATH (see csp_tmux_owner_file), which only exists once a server
  # is live — so the order is: start the bootstrap server, mint+persist the token
  # (now the path resolves and the file lands under this exact server's key), then
  # configure_home stamps that token as @csp_owner. Keying per-path means a
  # concurrent instance on a same-named socket at a DIFFERENT path writes a
  # DIFFERENT owner file and can't clobber this server's token.
  local tok others
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu \
    'sh -c "while :; do sleep 2147483647; done"' 2>/dev/null || return 1
  # CLOSE the check→create TOCTOU: new-session creates the SERVER when none exists,
  # but if a foreign server won this socket between the list-sessions check above
  # and this new-session, new-session would instead add OUR session to THEIR
  # server. A freshly-created server has EXACTLY our session and nothing else; a
  # foreign server we accidentally joined still carries its own session(s). So
  # before minting the token or running configure_home — the steps that would
  # stamp GLOBAL options / @csp_owner on a server — verify ours is the ONLY
  # session. If not, remove just our newly-added session (leaving theirs
  # untouched; we have NOT mutated any global option yet) and fall back to hub.
  others=$(csp_tmux list-sessions -F '#{session_name}' 2>/dev/null \
             | grep -vxF -- "$CSP_TMUX_SESSION" | grep -c . )
  if [ "${others:-0}" -ne 0 ]; then
    csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null
    return 1
  fi
  tok=$(csp_tmux_new_owner_token)
  [ -n "$tok" ] || { csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null; return 1; }
  csp_tmux_configure_home
  # Confirm the token actually landed as @csp_owner before launching the picker;
  # if it didn't (a wedged server where set-option silently failed), tear down and
  # fall back to hub rather than racing.
  [ "$(csp_tmux show-options -gv @csp_owner 2>/dev/null)" = "$tok" ] || {
    csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null
    return 1
  }
  # Now replace the placeholder with the real picker in the same window 0.
  csp_tmux respawn-window -k -t "=$CSP_TMUX_SESSION:menu" "$cmd" 2>/dev/null || {
    csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null
    return 1
  }
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

# csp_tmux_window_for_sid ID — print the tmux window id (on OUR holding session)
# whose @csp_sid tag exactly equals ID, or nothing. Each list line is
# "<window_id> <sid>"; awk compares the WHOLE second field ($2 == want) so an id
# can never match a window whose tag merely contains it (e.g. "id-a" won't match
# "id-abc"), and the empty tag on the menu window can't match a real id. awk
# (not a `while read` subshell) keeps the id out of any glob and reads cleanly
# under errexit. Used BOTH to dedup an open (switch instead of a second copy) and
# by the delete guard (a session with a live window must not be deleted, whatever
# its hook state — a bare `n` session that's merely "waiting" is still in use).
csp_tmux_window_for_sid() {
  local id="$1"
  [ -n "$id" ] && [ "$id" != "new" ] || return 0
  csp_tmux_available || return 0
  csp_tmux list-windows -t "=$CSP_TMUX_SESSION" \
    -F '#{window_id} #{@csp_sid}' 2>/dev/null \
    | awk -v want="$id" '$2 == want {print $1; exit}'
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
    existing=$(csp_tmux_window_for_sid "$id")
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
