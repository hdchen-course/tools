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
#   "hub"   → run one session at a time in this terminal, returning to the menu
#             when it exits (state is saved to disk by Claude). This is the
#             DEFAULT: it needs nothing installed and gives the simple
#             "quit a session → back to the menu → pick the next one" flow that
#             most people want.
#   "tmux"  → run each session in its own tmux window; non-active sessions keep
#             running live in the background. This is a power-user OPT-IN for
#             true concurrency, chosen only when the user explicitly asks for it
#             with CSP_BACKEND=tmux (and tmux is installed).
#
# Why hub is the default even when tmux exists: auto-selecting tmux just because
# the binary happens to be installed surprises people — pressing Enter drops
# them into a full-screen tmux client, and quitting the single window drops them
# back to the shell instead of the menu. Defaulting to hub makes the experience
# the same everywhere; concurrency is one env var away for those who want it.
#
# The override is matched case-sensitively; an unrecognised value (e.g. "Hub",
# "screen") is treated as auto (→ hub) — callers should first validate with
# csp_backend_is_valid so they can warn the user rather than silently ignoring
# a typo. We never promise "tmux" when tmux is absent.
# -----------------------------------------------------------------------------
csp_choose_backend() {
  local tmux_available="$1" inside_tmux="$2" forced="$3"

  case "$forced" in
    hub)  printf 'hub';  return 0 ;;
    tmux)
      if [ "$tmux_available" = "1" ]; then printf 'tmux'; else printf 'hub'; fi
      return 0 ;;
  esac

  # Auto (no explicit choice): always hub. tmux is opt-in only, so having tmux
  # installed for other reasons never changes the picker's default behaviour.
  printf 'hub'
}

# -----------------------------------------------------------------------------
# csp_backend_is_valid VALUE
#
# Return 0 if VALUE is a value csp_choose_backend actually honours as an
# override — i.e. empty (auto), "hub", or "tmux". Anything else returns 1 so a
# caller can warn "CSP_BACKEND=Hub is not recognised; using auto" instead of a
# user silently getting the wrong mode from a typo.
# -----------------------------------------------------------------------------
csp_backend_is_valid() {
  case "$1" in
    ''|hub|tmux) return 0 ;;
    *)           return 1 ;;
  esac
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
# csp_display_width TEXT
#
# Print the number of TERMINAL COLUMNS that TEXT occupies. This is NOT the same
# as the character count: a CJK character (Chinese/Japanese/Korean) and most
# emoji take TWO columns, while ASCII takes one. Getting this right is what lets
# us line the menu up into neat columns even when titles mix English and 中文.
#
# How it works without any external tool: in a UTF-8 locale ${#TEXT} counts
# CHARACTERS, and the same measurement in the C locale counts BYTES. A wide
# (CJK/emoji) glyph is a multi-byte character, so (chars + bytes) / 2 yields the
# column width: an ASCII char is 1 char + 1 byte -> 1; a 3-byte CJK char is
# 1 char + 3 bytes -> 2. This holds for the scripts we display and needs no fork.
# -----------------------------------------------------------------------------
csp_display_width() {
  local text="$1" chars bytes
  chars=${#text}
  # Re-measure the SAME string as bytes by switching to the C locale locally.
  local LC_ALL=C
  bytes=${#text}
  printf '%d' "$(( (chars + bytes) / 2 ))"
}

# -----------------------------------------------------------------------------
# csp_pad_display TEXT WIDTH
#
# Print TEXT padded with trailing spaces so it occupies exactly WIDTH terminal
# columns (using csp_display_width, so CJK is measured correctly). If TEXT is
# already wider than WIDTH it is returned unchanged — truncation is the caller's
# job (csp_truncate_display). This is the column-alignment primitive that fixes
# the "中文 rows don't line up" problem printf '%-40s' can't solve.
# -----------------------------------------------------------------------------
csp_pad_display() {
  local text="$1" width="$2" w pad=""
  w=$(csp_display_width "$text")
  if [ "$w" -lt "$width" ]; then
    # Build the padding. A simple loop is fine for the small widths we use.
    local n=$(( width - w ))
    while [ "$n" -gt 0 ]; do pad="$pad "; n=$(( n - 1 )); done
  fi
  printf '%s%s' "$text" "$pad"
}

# -----------------------------------------------------------------------------
# csp_truncate_display TEXT MAX
#
# Like csp_truncate, but measured in terminal COLUMNS, not characters, so a
# title of Chinese text is cut to fit its column width and never overflows into
# the next one. Adds a trailing '…' when it had to cut.
# -----------------------------------------------------------------------------
csp_truncate_display() {
  local text="$1" max="$2"
  if [ "$(csp_display_width "$text")" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  # Grow a prefix one character at a time until adding the next char would
  # exceed max-1 (leaving one column for the ellipsis). Character-by-character
  # keeps us from ever splitting a multi-byte glyph.
  local out="" i=0 ch w
  while [ "$i" -lt "${#text}" ]; do
    ch="${text:$i:1}"
    w=$(csp_display_width "$out$ch")
    [ "$w" -gt "$(( max - 1 ))" ] && break
    out="$out$ch"
    i=$(( i + 1 ))
  done
  printf '%s…' "$out"
}

# -----------------------------------------------------------------------------
# csp_format_line MARKER TITLE PROJECT AGE SELECTED
#
# Build one printable row of the picker as neatly aligned columns. Kept pure so
# tests can assert exactly what a row looks like without a terminal. Colour and
# selection highlighting are added by the drawing layer, not here — this returns
# plain text so the tests stay simple and the widths are predictable.
#
#   MARKER    one of the CSP_MARKER_* characters
#   TITLE     the session's title (already truncated upstream)
#   PROJECT   short project path (from csp_short_path)
#   AGE       human-friendly "last active" hint (e.g. "2h ago")
#   SELECTED  "1" if the cursor is on this row (adds the "›" pointer)
#
# Columns are padded by DISPLAY WIDTH so mixed English/中文 rows line up.
# -----------------------------------------------------------------------------
CSP_COL_TITLE=40    # columns reserved for the title
CSP_COL_PROJECT=26  # columns reserved for the project path

csp_format_line() {
  local marker="$1" title="$2" project="$3" age="$4" selected="$5"
  local pointer="  " line title_col project_col

  [ "$selected" = "1" ] && pointer="› "

  # Fit each variable-width field to its column, then pad to align the next one.
  title_col=$(csp_pad_display "$(csp_truncate_display "$title" "$CSP_COL_TITLE")" "$CSP_COL_TITLE")
  project_col=$(csp_pad_display "$(csp_truncate_display "$project" "$CSP_COL_PROJECT")" "$CSP_COL_PROJECT")

  line="${pointer}${marker} ${title_col}  ${project_col}  ${age}"

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
