# shellcheck shell=bash
# =============================================================================
# core.sh — Pure logic for the Claude Session Picker.
#
# WHAT THIS FILE IS (for readers who don't write shell scripts):
#   Every function here takes text in and gives text out. Nothing here reads
#   files, talks to the network, or launches other programs. That makes each
#   function easy to test and impossible to break your terminal. All the work
#   that touches the outside world (reading Claude's session files, launching
#   `claude --resume`) lives in other files that call these helpers.
#
# THE BIG PICTURE:
#   Claude Code already saves every conversation on disk under
#   ~/.claude/projects/<encoded-folder>/<session-id>.jsonl. This tool reads
#   that store and shows you a menu of your past sessions so you can jump back
#   into any one with a single keypress — no extra software required. These
#   pure helpers do the formatting and the safety-critical bounds checking.
#
# DESIGN RULES enforced throughout:
#   1. Bash 3.2 compatible (this is what ships on macOS). No associative
#      arrays, no `mapfile`/`readarray`, no `${var^^}` upper-casing.
#   2. Every variable is declared `local` so functions never leak state.
#   3. Every input length is bounded, so a huge or hostile input can never make
#      the tool allocate unbounded memory. This is what keeps it stable even
#      when a session's title or prompt is enormous.
# =============================================================================

# A live session (a `claude` process is running for it right now) is marked so
# you can tell at a glance what is still active. No color is used on purpose, so
# it looks the same in every terminal theme.
CSP_MARKER_LIVE="●"    # A claude process is running this session right now.
CSP_MARKER_NONE=" "    # No live process; this is a resumable past session.

# Hard upper bounds. These exist so a broken or hostile input can never make the
# tool loop forever or build an unbounded string.
CSP_MAX_SESSIONS=1000  # Never load more sessions than this into the menu.
CSP_MAX_TITLE_LEN=60   # Longest session title we will display.
CSP_MAX_LINE_LEN=200   # Longest rendered line; anything longer is truncated.

# -----------------------------------------------------------------------------
# csp_choose_backend TMUX_AVAILABLE INSIDE_TMUX FORCED
#
# Decide how the picker should run sessions. Kept pure so the rule is obvious
# and unit-tested; the actual launching lives in lib/backend.sh.
#
#   TMUX_AVAILABLE  "1" if the tmux command exists on this machine
#   INSIDE_TMUX     "1" if we are already running inside a tmux session
#   FORCED          user override: "tmux", "hub", or "" for auto
#
# Prints one of:
#   "tmux"  → run each session in its own tmux window; non-active sessions keep
#             running live in the background. Chosen when tmux is usable.
#   "hub"   → run one session at a time in this terminal, returning to the menu
#             when it exits (state is saved to disk by Claude). The zero-
#             dependency default that works on a bare Linux host.
#
# The override always wins, EXCEPT we never promise "tmux" when tmux is absent,
# because that backend simply cannot work without the tmux command.
# -----------------------------------------------------------------------------
csp_choose_backend() {
  local tmux_available="$1" inside_tmux="$2" forced="$3"

  case "$forced" in
    hub)  printf 'hub';  return 0 ;;
    tmux)
      if [ "$tmux_available" = "1" ]; then printf 'tmux'; else printf 'hub'; fi
      return 0 ;;
  esac

  # Auto: prefer tmux only when it is actually available.
  if [ "$tmux_available" = "1" ]; then
    printf 'tmux'
  else
    printf 'hub'
  fi
}

# -----------------------------------------------------------------------------
# csp_marker_for_session IS_LIVE
#
# Decide which marker a session row should show.
#   IS_LIVE  "1" if a claude process is currently running this session, else "0"
#
# Kept trivial and pure so the rule is unit-tested and obvious to a reader.
# -----------------------------------------------------------------------------
csp_marker_for_session() {
  local is_live="$1"
  if [ "$is_live" = "1" ]; then
    printf '%s' "$CSP_MARKER_LIVE"
  else
    printf '%s' "$CSP_MARKER_NONE"
  fi
}

# -----------------------------------------------------------------------------
# csp_clamp_index INDEX COUNT
#
# Keep a selection cursor inside the list. Given the index the user is trying
# to move to and how many items exist, return a valid index.
#
# This is the single guard that makes j/k navigation memory-safe: no matter how
# many times you press a key, the index can never point outside the array,
# which is what would otherwise read an unset element (an error under `set -u`).
#
#   - If the list is empty, the only valid index is 0.
#   - Moving above the top wraps to the bottom; moving past the bottom wraps to
#     the top. Wrapping feels natural and removes dead key presses.
# -----------------------------------------------------------------------------
csp_clamp_index() {
  local index="$1" count="$2"

  if [ "$count" -le 0 ]; then
    printf '0'
    return 0
  fi

  if [ "$index" -lt 0 ]; then
    printf '%d' "$((count - 1))"   # went above the top → jump to the last item
  elif [ "$index" -ge "$count" ]; then
    printf '0'                     # went past the bottom → jump to the first item
  else
    printf '%d' "$index"
  fi
}

# -----------------------------------------------------------------------------
# csp_encode_project_dir ABSOLUTE_PATH
#
# Claude stores each project's sessions in a folder named after the project
# path, with every '/' turned into '-'. For example:
#     /Volumes/work/tools  →  -Volumes-work-tools
# This function reproduces that encoding so we can find the folder for a given
# working directory. We only need the encoding (path → folder name); decoding
# is never required because we read the real path back out of the session file.
# -----------------------------------------------------------------------------
csp_encode_project_dir() {
  local path="$1"
  printf '%s' "$path" | tr '/' '-'
}

# -----------------------------------------------------------------------------
# csp_short_path ABSOLUTE_PATH
#
# Turn a long working-directory path into something short for the menu, by
# replacing the home directory with '~' and keeping only the last two path
# components (e.g. /Users/me/work/EnglishTraining/tools → …/EnglishTraining/tools).
# Purely cosmetic, so the menu stays readable.
# -----------------------------------------------------------------------------
csp_short_path() {
  local path="$1" parent leaf
  leaf="${path##*/}"                 # last component
  parent="${path%/*}"                # everything before it
  parent="${parent##*/}"             # second-to-last component
  if [ -n "$parent" ] && [ "$parent" != "$path" ]; then
    printf '%s/%s' "$parent" "$leaf"
  else
    printf '%s' "$leaf"
  fi
}

# -----------------------------------------------------------------------------
# csp_truncate TEXT MAX
#
# Shorten TEXT to at most MAX characters, adding a trailing '…' when it had to
# cut. Used so a giant title/prompt can never blow past our line budget. We
# count characters, not bytes, so multi-byte titles (e.g. Chinese) are measured
# correctly rather than being chopped mid-character by a byte count.
# -----------------------------------------------------------------------------
csp_truncate() {
  local text="$1" max="$2"
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$((max - 1))}"
  fi
}

# -----------------------------------------------------------------------------
# csp_format_line MARKER TITLE PROJECT AGE SELECTED
#
# Build one printable row of the picker. Kept pure so tests can assert exactly
# what a row looks like without a terminal.
#
#   MARKER    one of the CSP_MARKER_* characters
#   TITLE     the session's title (already truncated upstream)
#   PROJECT   short project path (from csp_short_path)
#   AGE       human-friendly "last active" hint (e.g. "2h ago")
#   SELECTED  "1" if the cursor is on this row
#
# The row is truncated to CSP_MAX_LINE_LEN so a pathological value can never
# produce an oversized line.
# -----------------------------------------------------------------------------
csp_format_line() {
  local marker="$1" title="$2" project="$3" age="$4" selected="$5"
  local cursor="  " line

  [ "$selected" = "1" ] && cursor="> "

  line=$(printf '%s%s %-40s  %-22s %s' "$cursor" "$marker" "$title" "$project" "$age")

  if [ "${#line}" -gt "$CSP_MAX_LINE_LEN" ]; then
    line="${line:0:$CSP_MAX_LINE_LEN}"
  fi
  printf '%s' "$line"
}

# -----------------------------------------------------------------------------
# csp_field LINE INDEX
#
# Pull one tab-separated field out of a line. We assemble session records as
# tab-delimited text (title <TAB> id <TAB> project …); this reads field N
# (1-based) without spawning `cut` or `awk` per row, which keeps the menu fast.
# -----------------------------------------------------------------------------
csp_field() {
  local line="$1" want="$2"
  local i=1 field rest="$line"
  local tab=$'\t'

  while [ "$i" -lt "$want" ]; do
    case "$rest" in
      *"$tab"*) rest="${rest#*"$tab"}" ;;
      *)        printf ''; return 0 ;;   # asked for a field past the end
    esac
    i=$((i + 1))
  done
  field="${rest%%"$tab"*}"
  printf '%s' "$field"
}

# -----------------------------------------------------------------------------
# csp_humanize_age SECONDS
#
# Turn "how many seconds ago" into a short human string for the menu:
#   < 60s        → "just now"
#   < 60m        → "Nm ago"
#   < 24h        → "Nh ago"
#   otherwise    → "Nd ago"
# Negative or empty input is treated as 0, so a clock skew can't print garbage.
# -----------------------------------------------------------------------------
csp_humanize_age() {
  local secs="$1"
  case "$secs" in
    ''|*[!0-9]*) secs=0 ;;   # empty or non-numeric → treat as "just now"
  esac

  if [ "$secs" -lt 60 ]; then
    printf 'just now'
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm ago' "$((secs / 60))"
  elif [ "$secs" -lt 86400 ]; then
    printf '%dh ago' "$((secs / 3600))"
  else
    printf '%dd ago' "$((secs / 86400))"
  fi
}

# -----------------------------------------------------------------------------
# csp_window_start SELECTED COUNT VISIBLE
#
# Work out which row the visible window should start at, so the selected row is
# always on screen even when there are more sessions than fit in the terminal.
#
#   SELECTED  the currently highlighted row (0-based)
#   COUNT     total number of rows
#   VISIBLE   how many rows fit on screen at once
#
# Returns the index of the first row to draw. This is the piece that makes long
# lists usable on a short terminal or a small remote terminal: it keeps the
# selection in view and never scrolls past the end of the list.
# -----------------------------------------------------------------------------
csp_window_start() {
  local selected="$1" count="$2" visible="$3" start

  # Everything fits, or a nonsensical size → start at the top.
  if [ "$visible" -le 0 ] || [ "$count" -le "$visible" ]; then
    printf '0'
    return 0
  fi

  # Try to centre the selection in the window for comfortable scrolling.
  start=$((selected - visible / 2))

  # Don't scroll above the first row...
  [ "$start" -lt 0 ] && start=0
  # ...and don't scroll so far down that we'd show blank space past the end.
  if [ "$start" -gt "$((count - visible))" ]; then
    start=$((count - visible))
  fi
  printf '%d' "$start"
}

# -----------------------------------------------------------------------------
# csp_is_live SESSION_ID RUNNING_IDS
#
# Return 0 (true) if SESSION_ID appears in RUNNING_IDS — a newline-separated
# list of session ids that currently have a `claude` process. We match whole
# lines only, so one id can never be mistaken for another that contains it.
# An empty SESSION_ID never matches, so a malformed record can't be "live".
# -----------------------------------------------------------------------------
csp_is_live() {
  local id="$1" running="$2" line
  [ -z "$id" ] && return 1
  while IFS= read -r line; do
    [ "$line" = "$id" ] && return 0
  done <<EOF
$running
EOF
  return 1
}
