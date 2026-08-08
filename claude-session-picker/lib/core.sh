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

# Markers shown next to each session so you can tell its state at a glance.
# (Colour is added by the drawing layer, not baked in here.)
CSP_MARKER_WORKING="●"    # Claude is actively working in this session.
CSP_MARKER_ATTENTION="✳"  # Claude finished / wants your input — you haven't looked.
CSP_MARKER_NONE=" "       # Idle-and-seen, or no live Claude here.
# Back-compat alias: some code/tests still refer to the old "live" name.
CSP_MARKER_LIVE="$CSP_MARKER_WORKING"

# The single-character ellipsis appended when text is truncated. It is stored in
# a variable, set ONCE here in the (UTF-8) startup locale, and never written as
# a literal inside a function. Reason: bash 3.2 mis-parses a multibyte literal
# that appears in a function which has (via a helper) switched LC_ALL to C — the
# literal's bytes corrupt the following token, breaking the string or tripping
# `set -u`. Referencing a pre-set variable sidesteps that entirely.
CSP_ELLIPSIS='…'

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
# csp_marker_for_session IS_LIVE [STATE]
#
# Decide which marker a session row should show. Pure, so the rule is
# unit-tested and obvious to a reader.
#
#   IS_LIVE  "1" if a claude process is currently running this session, else "0"
#   STATE    optional per-session state from the Claude Code hooks:
#              "working"  → Claude is generating / running a tool
#              "waiting"  → Claude stopped and wants your input (unseen)
#              ""/other   → unknown (no hooks installed, or nothing recorded)
#
# IMPORTANT — STATE is authoritative, IS_LIVE is only a hint. Liveness is
# detected by finding a `claude --resume <id>` process (see csp_running_session_ids),
# which is a LOWER BOUND: a session started as a bare `claude` (including a new
# one you start here with `n`) has no `--resume <id>`, so it reads as not-live
# even while it's very much alive. If we trusted IS_LIVE over STATE, such a
# session would show the WRONG marker — worst of all, a bare session that is
# waiting for you would go blank. So the hook's STATE decides the marker, and
# IS_LIVE is used only to disambiguate the one genuinely ambiguous case.
#
# The rule:
#   • STATE "waiting"           → ✳  (Claude explicitly stopped and wants you —
#                                     true regardless of whether we saw a process)
#   • STATE "working" + live    → ●  (definitely busy)
#   • STATE "working" + not live→ ✳  (the reconciler: the hook said "working"
#                                     but we can't see the process. If it really
#                                     crashed mid-turn this is exactly right; if
#                                     it's a bare session still working, "come
#                                     look" is a harmless over-nudge, never an
#                                     invisible one.)
#   • no/again-unknown STATE    → fall back to IS_LIVE alone: live → ●, else
#                                 blank. This is the behaviour when the hooks
#                                 aren't installed, unchanged from before.
# -----------------------------------------------------------------------------
csp_marker_for_session() {
  local is_live="$1" state="${2:-}"
  case "$state" in
    waiting)
      printf '%s' "$CSP_MARKER_ATTENTION"; return 0 ;;
    working)
      if [ "$is_live" = "1" ]; then
        printf '%s' "$CSP_MARKER_WORKING"
      else
        printf '%s' "$CSP_MARKER_ATTENTION"   # reconciler
      fi
      return 0 ;;
  esac
  # No hook state recorded → original live/blank behaviour.
  if [ "$is_live" = "1" ]; then
    printf '%s' "$CSP_MARKER_WORKING"
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
    printf '%s%s' "${text:0:$((max - 1))}" "$CSP_ELLIPSIS"
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
# How it works without any external tool: a character is "wide" (2 columns) when
# its UTF-8 encoding is 3+ bytes — that captures CJK and most emoji. Everything
# else (ASCII, and also 2-byte characters like accented Latin, Greek, Cyrillic)
# is 1 column. So the width is: (number of characters) + (number of wide chars).
#
# We must NOT use the tempting shortcut (chars + bytes) / 2: it assumes every
# non-ASCII character is 3 bytes, which over-counts 2-byte characters — e.g. two
# Cyrillic letters are 2 chars / 4 bytes, giving 3 instead of the correct 2, and
# any accented/Greek/Cyrillic title would then misalign. Counting only the 3+
# byte characters as wide fixes that.
#
# In a UTF-8 locale ${#char} is 1 per character; re-measuring the same character
# in the C locale gives its byte length. We loop per character, but callers clip
# titles well before this (CSP_META_TITLE_CLIP), so the input is always short.
# -----------------------------------------------------------------------------
csp_display_width() {
  local text="$1" chars
  chars=${#text}                      # character count (UTF-8 locale)

  # Measure the whole string's byte length fork-free (csp_byte_len_var sets the
  # global __csp_bl). If bytes == chars the string is pure single-byte (ASCII) →
  # width == chars, with no per-character work at all (the common case).
  csp_byte_len_var "$text"
  if [ "$__csp_bl" -eq "$chars" ]; then
    printf '%d' "$chars"
    return 0
  fi

  # There is at least one multi-byte character. Width = chars + (number of WIDE
  # chars), where a wide char (2 columns) is one encoded in 3+ UTF-8 bytes (CJK,
  # emoji); 2-byte chars (accented Latin, Greek, Cyrillic) stay 1 column.
  #
  # We loop per character, measuring each character's byte length with
  # csp_byte_len_var — a plain function call (NOT a $(...) command substitution)
  # that returns its answer in the global __csp_bl. That keeps the loop
  # fork-free, which matters because this runs for every row on every redraw.
  # (We can't use `printf %d "'X"` for the code point: bash 3.2 returns the
  # first BYTE there, not the code point, so it's unreliable on macOS.) Callers
  # clip titles (CSP_META_TITLE_CLIP), so the loop is always over a short string.
  local i=0 ch wide=0
  while [ "$i" -lt "$chars" ]; do
    ch="${text:$i:1}"                 # one CHARACTER (current UTF-8 locale)
    # The ellipsis U+2026 is 3 bytes but renders in ONE column, so it's an
    # exception to the "3+ bytes = wide" rule — skip it (leave it counted as 1).
    [ "$ch" = "$CSP_ELLIPSIS" ] && { i=$(( i + 1 )); continue; }
    csp_byte_len_var "$ch"            # sets __csp_bl to the byte length
    [ "$__csp_bl" -ge 3 ] && wide=$(( wide + 1 ))
    i=$(( i + 1 ))
  done
  printf '%d' "$(( chars + wide ))"
}

# csp_byte_len STRING — print the number of BYTES in STRING, by switching to the
# C locale (where ${#..} counts bytes, not characters). Convenient for callers
# that want the value via $(...) (e.g. tests).
csp_byte_len() {
  local LC_ALL=C
  printf '%d' "${#1}"
}

# csp_byte_len_var STRING — same measurement, but returned in the global
# __csp_bl instead of printed. This exists so hot loops (csp_display_width) can
# get a byte length WITHOUT the fork a $(csp_byte_len …) command substitution
# would cost — important because it runs per character, per row, per redraw.
csp_byte_len_var() {
  local LC_ALL=C
  __csp_bl=${#1}
}
__csp_bl=0

# -----------------------------------------------------------------------------
# csp_fit_field TEXT WIDTH  → result in the global __csp_fit
#
# Fit TEXT to EXACTLY WIDTH terminal columns: truncate (with a trailing '…') if
# it's too wide, pad with spaces if it's too narrow. This is the workhorse for
# every column in every row, so it is written to be FAST:
#   • ONE pass over the characters (not the old O(n²) "re-measure the whole
#     prefix for each character"),
#   • NO forks — it measures each character's byte length via csp_byte_len_var
#     (a function call that sets a global), and returns its result in the global
#     __csp_fit instead of via a $(...) command substitution.
# Wide (CJK/emoji, 3+ byte) characters count as 2 columns; everything else as 1.
# When truncating we never split a multi-byte glyph, and we reserve 1 column for
# the ellipsis. A wide char that would land on the last single column is dropped
# and the gap is space-padded, so the field is always exactly WIDTH wide.
# -----------------------------------------------------------------------------
csp_fit_field() {
  local text="$1" width="$2"
  local i=0 n="${#text}" w=0 out="" ch cw truncated=0

  # First, does the whole text fit? Walk it once accumulating column width.
  # If at any point adding the next character would exceed `width`, we know we
  # must truncate — and we rebuild a shorter prefix that leaves 1 column for the
  # ellipsis. Building FORWARD (never trimming from the end) avoids the fragile
  # `${out: -1}` slice on multibyte data and keeps everything single-pass.
  while [ "$i" -lt "$n" ]; do
    ch="${text:$i:1}"
    cw=1
    if [ "$ch" != "$CSP_ELLIPSIS" ]; then     # … is 3 bytes but 1 column
      csp_byte_len_var "$ch"
      [ "$__csp_bl" -ge 3 ] && cw=2
    fi
    if [ "$(( w + cw ))" -gt "$width" ]; then truncated=1; break; fi
    out="$out$ch"
    w=$(( w + cw ))
    i=$(( i + 1 ))
  done

  if [ "$truncated" = "1" ]; then
    # Rebuild a prefix that fits in width-1 columns, then append the ellipsis.
    local limit=$(( width - 1 ))
    i=0; w=0; out=""
    while [ "$i" -lt "$n" ]; do
      ch="${text:$i:1}"
      cw=1
      if [ "$ch" != "$CSP_ELLIPSIS" ]; then
        csp_byte_len_var "$ch"
        [ "$__csp_bl" -ge 3 ] && cw=2
      fi
      if [ "$(( w + cw ))" -gt "$limit" ]; then break; fi
      out="$out$ch"
      w=$(( w + cw ))
      i=$(( i + 1 ))
    done
    out="$out$CSP_ELLIPSIS"       # variable, NOT a literal — see CSP_ELLIPSIS
    w=$(( w + 1 ))
  fi

  # Pad to the exact width.
  while [ "$w" -lt "$width" ]; do out="$out "; w=$(( w + 1 )); done
  __csp_fit="$out"
}
__csp_fit=""

# csp_pad_display / csp_truncate_display — thin wrappers kept for the tests and
# any external caller. They print their result (a fork at the call site), so the
# hot draw path uses csp_fit_field directly instead. pad only grows; truncate
# only shrinks — csp_fit_field does both, so we clamp accordingly.
csp_pad_display() {
  local text="$1" width="$2" w
  w=$(csp_display_width "$text")
  if [ "$w" -ge "$width" ]; then printf '%s' "$text"; return 0; fi
  csp_fit_field "$text" "$width"
  printf '%s' "$__csp_fit"
}

# -----------------------------------------------------------------------------
# csp_truncate_display TEXT MAX
#
# Like csp_truncate, but measured in terminal COLUMNS, not characters, so a
# title of Chinese text is cut to fit its column width and never overflows into
# the next one. Adds a trailing '…' when it had to cut.
# -----------------------------------------------------------------------------
csp_truncate_display() {
  local text="$1" max="$2" w
  w=$(csp_display_width "$text")
  if [ "$w" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  # csp_fit_field truncates AND pads to exactly max; this helper only truncates,
  # so strip the trailing pad spaces it added after the ellipsis.
  csp_fit_field "$text" "$max"
  local r="$__csp_fit"
  while [ "${r% }" != "$r" ]; do r="${r% }"; done   # drop trailing spaces
  printf '%s' "$r"
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

  # Fit each variable-width field to its exact column in ONE fork-free pass each
  # (csp_fit_field both truncates and pads, returning via __csp_fit).
  csp_fit_field "$title" "$CSP_COL_TITLE";     title_col="$__csp_fit"
  csp_fit_field "$project" "$CSP_COL_PROJECT"; project_col="$__csp_fit"

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
