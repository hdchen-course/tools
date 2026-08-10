# shellcheck shell=bash
# =============================================================================
# sessions.sh — reads Claude Code's own session store. The ONLY file that
# touches the disk or inspects running processes.
#
# WHY THIS FILE EXISTS (for non-coders):
#   Claude Code already writes a file for every conversation you have, under
#   ~/.claude/projects/. Each file is a "session" you can resume. This file
#   knows how to (a) find those session files, (b) pull a short title and a
#   "last active" time out of each, and (c) notice which sessions have a live
#   `claude` program running right now. Everything it produces is plain,
#   tab-separated text that the pure helpers in core.sh then format.
#
# ZERO DEPENDENCIES BY DESIGN:
#   To read the small amount of JSON we need, we use `jq` if it's installed,
#   otherwise `python3`, otherwise a minimal built-in text extractor. So the
#   tool works out of the box on a bare machine (e.g. a remote Linux host)
#   with nothing to install.
# =============================================================================

# Where Claude Code keeps its data. Overridable for tests.
CSP_CLAUDE_DIR="${CSP_CLAUDE_DIR:-$HOME/.claude}"

# Where we keep per-session state ("working"/"waiting") written by the Claude
# Code hooks. One tiny file per session id, so sessions never interfere and a
# deleted session leaves no residue. Overridable for tests.
CSP_STATE_DIR="${CSP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-session-picker/state}"

# csp_now_epoch — current time in whole seconds. Wrapped in a function so tests
# can override "now" and get deterministic ages.
csp_now_epoch() {
  date +%s
}

# --- Per-session state (for the ●/✳ markers) ---------------------------------
# csp_state_file ID — the state file path for a session id. The id comes from a
# real filename (hex + dashes), but we sanitise defensively so a weird value can
# never write outside the state directory.
csp_state_file() {
  local id="$1" safe
  safe=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/%s' "$CSP_STATE_DIR" "$safe"
}

# csp_read_state ID — print the recorded state ("working"/"waiting") for a
# session, or nothing if none. Always returns 0 (absence is normal), and reads
# a bounded amount so a bogus file can't hurt us. Grouped redirect so an
# unreadable file can't leak an error to the terminal.
csp_read_state() {
  local f v=""
  f=$(csp_state_file "$1")
  if [ -f "$f" ]; then
    # Do NOT `|| v=""` here: `read -n` returns non-zero at end-of-file when the
    # value has no trailing newline, but it has still populated v — a state file
    # written without a newline (a crash mid-write, or hand-edited) would lose
    # its value if we cleared it on that non-zero. The `case` below validates.
    { IFS= read -r -n 16 v < "$f"; } 2>/dev/null
  fi
  v="${v%$'\r'}"
  case "$v" in working|waiting) printf '%s' "$v" ;; esac
  return 0
}

# csp_write_state ID VALUE — record a session's state (best-effort; if the dir
# can't be created or written we just skip it, so this never fails a caller).
#
# The write is ATOMIC: we print to a unique temp file, then `mv` it into place.
# A rename on the same filesystem is atomic, so a concurrent reader (the picker
# loading the list) never sees a half-written or truncated file — it sees either
# the old contents or the new, never a torn value. The temp name includes $$ so
# parallel hook processes don't clobber each other's temp file mid-write.
#
# ORDERING (a known, benign limitation): "last writer wins" is by rename order,
# not by event time. Claude Code fires a session's hooks in order (prompt →
# … → stop), so out-of-order only happens if an OLDER hook process is unusually
# slow and renames after a newer one — briefly showing the wrong marker. It is
# self-correcting (the next hook, or the picker's reconciler — which downgrades a
# "working" state with no live process to ✳ — fixes it) and only cosmetic, so we
# deliberately don't carry a per-event sequence/timestamp here: that complexity
# isn't worth it for a marker hint. If it ever matters, stamp the state with a
# monotonic counter and reject a write older than the stored one.
csp_write_state() {
  local id="$1" v="$2" f tmp
  f=$(csp_state_file "$id")
  mkdir -p "$CSP_STATE_DIR" 2>/dev/null || return 0
  tmp="$f.$$.tmp"
  { printf '%s\n' "$v" > "$tmp"; } 2>/dev/null || return 0
  mv -f -- "$tmp" "$f" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 0; }
}

# csp_clear_state ID — forget a session's state (e.g. once you've opened it, so
# its ✳ "needs attention" marker goes away). Best-effort.
csp_clear_state() {
  local f
  f=$(csp_state_file "$1")
  rm -f -- "$f" 2>/dev/null || true
}

# --- Ambient tmux residency (an ownership-INDEPENDENT delete-safety signal) ---
# When a hooked Claude session runs inside SOME tmux pane that the picker does
# NOT own — a legacy/markerless server that survived an in-place upgrade, or the
# user's own unrelated tmux — we cannot tag that server's window with @csp_sid
# (we must never touch a server we don't own). But the session is still LIVE, and
# deleting its transcript would be data loss that no mtime window catches once the
# session sits idle at a prompt. So the hook records, in OUR OWN state dir, that
# this session is resident in a given ambient pane; the delete guard later blocks
# while that pane is still alive (a read-only probe) and self-clears the record
# only when it can POSITIVELY prove the pane/server is gone.
#
# The record is THREE lines: (socket_path, server_pid, pane_id), all taken from
# the hook's own $TMUX / $TMUX_PANE — we never touch the ambient server to learn
# them. The server_pid is essential: a Unix socket path can be reused by a NEW
# tmux server after the old one dies (or even while it lives, if the socket file
# is replaced), so a socket-path-only probe could read a DIFFERENT instance's
# panes and wrongly clear a live record. Binding to the recorded server pid lets
# us tell "same instance, pane really gone" (safe to clear) from "different
# instance / can't reach it" (must stay live). Files live in a `resident/` subdir
# so they can't collide with a session's state file (named by the bare id).
csp_resident_file() {
  local id="$1" safe
  safe=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/resident/%s' "$CSP_STATE_DIR" "$safe"
}

# csp_record_residency ID SOCKET_PATH [SERVER_PID] [PANE_ID] — record the
# residency. The write is atomic and symlink-safe: an unpredictable temp is
# created with mktemp INSIDE the 0700 dir (O_EXCL, so it can't follow a
# pre-planted symlink) and renamed into place. SOCKET_PATH is required; SERVER_PID
# and PANE_ID are optional (empty lines if absent) so we still record something
# useful when the hook's env lacks them.
#
# Returns 0 only if the record actually landed on disk; NON-ZERO on any failure
# (no socket, unwritable dir, mktemp/write/rename error). The caller MUST react to
# a failure — this record can be a live session's ONLY delete protection, so a
# silent loss would be a data-loss hole. (Callers fall back to marking the session
# "working", which the delete guard also blocks on.)
csp_record_residency() {
  local id="$1" sock="$2" spid="${3:-}" pane="${4:-}" f d tmp
  [ -n "$sock" ] || return 1
  case "$spid" in *[!0-9]*) spid="" ;; esac      # pid must be all digits or empty
  f=$(csp_resident_file "$id"); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null || return 1
  chmod 700 "$d" 2>/dev/null || true
  tmp=$(mktemp "$d/.res.XXXXXX" 2>/dev/null) || return 1
  { printf '%s\n%s\n%s\n' "$sock" "$spid" "$pane" > "$tmp"; } 2>/dev/null \
    || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$f" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

# csp_clear_residency ID — drop a residency record (best-effort).
csp_clear_residency() {
  local f
  f=$(csp_resident_file "$1")
  rm -f -- "$f" 2>/dev/null || true
}

# csp_clear_residency_if_matches ID SOCKET [PANE] — clear the record for ID ONLY
# if it belongs to the given (socket[, pane]). Used by SessionEnd: an OLD
# instance's SessionEnd must not wipe a NEWER same-id instance's record (which a
# recent working/waiting hook may have just written for a different socket/pane).
# If the stored record's socket (and pane, when both are known) don't match, we
# leave it alone. Best-effort.
csp_clear_residency_if_matches() {
  local id="$1" sock="$2" pane="${3:-}" rec rsock rpane
  rec=$(csp_read_residency "$id")
  [ -n "$rec" ] || return 0                        # nothing to clear
  rsock=${rec%%$'\t'*}
  rpane=${rec##*$'\t'}
  [ "$rsock" = "$sock" ] || return 0               # different server → not ours
  # If both sides know a pane, require it to match too; if either is unknown, the
  # socket match is the best signal we have and we clear on it.
  if [ -n "$pane" ] && [ -n "$rpane" ] && [ "$pane" != "$rpane" ]; then
    return 0
  fi
  csp_clear_residency "$id"
}

# csp_read_residency ID — print "SOCKET_PATH<TAB>SERVER_PID<TAB>PANE_ID" for a
# recorded residency (PID/PANE may be empty), or nothing if there's no usable
# record. Refuses to follow a symlink at the path (a planted link could otherwise
# redirect the read). Bounded: only the first three lines.
csp_read_residency() {
  local f sock="" spid="" pane=""
  f=$(csp_resident_file "$1")
  [ -f "$f" ] || return 0
  [ -L "$f" ] && return 0            # never follow a symlink here
  { IFS= read -r sock; IFS= read -r spid; IFS= read -r pane; } < "$f" 2>/dev/null
  [ -n "$sock" ] || return 0         # socket is mandatory; pid/pane may be empty
  # Backward-compat with the earlier 2-line (socket, pane) record: if the 2nd line
  # isn't a numeric pid, treat it as the pane (moving it there only if we didn't
  # also read a 3rd line), so a legacy record still probes the right pane rather
  # than over-blocking. A well-formed 3-line record has an all-digits pid here.
  case "$spid" in
    *[!0-9]*) [ -z "$pane" ] && pane="$spid"; spid="" ;;   # non-numeric → not a pid
  esac
  printf '%s\t%s\t%s' "$sock" "$spid" "$pane"
}

# csp_residency_is_live ID — return 0 if this session's recorded residency is
# still live. FAIL CLOSED: we clear the record and return "dead" ONLY on POSITIVE
# proof the session is gone; every uncertain/transient case keeps the record and
# reports live, because deleting a live transcript is unrecoverable.
#
# READ-ONLY: we query the ambient server by its socket path with `tmux -S`,
# listing "<server_pid> <pane_id>" per pane — never setting an option, so the
# "we never touch your tmux" promise holds even for a server we don't own. We run
# ONE query, then require POSITIVE, VALIDATED evidence before ever clearing:
#   • query FAILS (nonzero): NOT proof of death (transient tmux error, EINTR,
#     busy). Clear only if we recorded a server pid AND that exact process is gone
#     (kill -0 fails). Otherwise stay live.
#   • query SUCCEEDS but the output is EMPTY or MALFORMED (no valid "<pid>
#     <pane_id>" lines, or no usable current pid): this is NOT positive proof the
#     pane is gone — a valid live server always lists at least its own pane with a
#     numeric pid. Treat as uncertain → stay live (fail closed). This is the
#     round-4 finding: an exit-0-with-garbage result must never green-light a
#     delete.
#   • query SUCCEEDS, valid output, current pid DIFFERS from recorded: socket
#     reused by a NEW instance. Stay live if our recorded pid is still alive
#     (session may run in the old instance we can't enumerate here), else clear.
#   • query SUCCEEDS, valid output, SAME instance: clear only when the recorded
#     pane is positively ABSENT from the (validated) listing. A legacy record with
#     no pid is UPGRADED here to a 3-line record using the current pid, so a later
#     death can be proven.
# No tmux binary → can't probe → fail closed (live).
csp_residency_is_live() {
  local id="$1" rec sock spid pane out st cur_pid panes
  rec=$(csp_read_residency "$id")
  [ -n "$rec" ] || return 1
  sock=${rec%%$'\t'*}
  rec=${rec#*$'\t'}
  spid=${rec%%$'\t'*}
  pane=${rec#*$'\t'}
  command -v tmux >/dev/null 2>&1 || return 0     # can't probe → fail closed (live)

  out=$(command tmux -S "$sock" list-panes -a -F '#{pid} #{pane_id}' 2>/dev/null)
  st=$?
  if [ "$st" -ne 0 ]; then
    if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
      csp_clear_residency "$id"                    # recorded server pid gone → dead
      return 1
    fi
    return 0                                       # transient/unknown → stay live
  fi

  # Query SUCCEEDED. VALIDATE the output before trusting it as evidence. Keep only
  # well-formed "<digits> <%pane>" lines; a valid live server yields at least one.
  panes=$(printf '%s\n' "$out" | grep -E '^[0-9]+ %[0-9]+$')
  if [ -z "$panes" ]; then
    return 0                                       # empty/malformed → NOT proof → live
  fi
  cur_pid=$(printf '%s\n' "$panes" | sed -n '1s/ .*//p')
  case "$cur_pid" in ''|*[!0-9]*) return 0 ;; esac # no usable pid → uncertain → live

  # Valid listing. Is it the SAME instance we recorded?
  if [ -n "$spid" ] && [ "$cur_pid" != "$spid" ]; then
    # A DIFFERENT server now holds this socket path. If our recorded instance is
    # still alive elsewhere, the session may still run in it → stay live.
    if kill -0 "$spid" 2>/dev/null; then
      return 0
    fi
    csp_clear_residency "$id"                      # old instance gone → allow
    return 1
  fi

  # Same instance (or a legacy record with no recorded pid). Upgrade a pidless
  # legacy record to 3-line now, using the pid we just observed, so a future death
  # is provable rather than blocking forever.
  if [ -z "$spid" ]; then
    csp_record_residency "$id" "$sock" "$cur_pid" "$pane"
  fi

  [ -n "$pane" ] || return 0                       # no pane recorded, server up → live
  if printf '%s\n' "$panes" | awk '{print $2}' | grep -qxF -- "$pane"; then
    return 0                                       # pane still open → live → block
  fi
  csp_clear_residency "$id"                        # same instance, pane gone → ended
  return 1
}

# --- JSON value extraction ---------------------------------------------------
# csp_json_first_value FILE KEY
#
# Print the value of the FIRST occurrence of a top-level "KEY":"value" string
# field found anywhere in FILE (the session .jsonl is one JSON object per
# line). Tries jq, then python3, then a careful grep/sed fallback. Returns ""
# if the key never appears — callers must tolerate an empty result.
csp_json_first_value() {
  local file="$1" key="$2" val=""

  if command -v jq >/dev/null 2>&1; then
    # -r raw output; scan every line, print the key if present, take the first.
    val=$(jq -r --arg k "$key" 'select(has($k)) | .[$k] // empty' "$file" 2>/dev/null | head -1)
  elif command -v python3 >/dev/null 2>&1; then
    val=$(CSP_PY_KEY="$key" python3 - "$file" <<'PYEOF' 2>/dev/null
import json, os, sys
key = os.environ["CSP_PY_KEY"]
with open(sys.argv[1], "r", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and key in obj and isinstance(obj[key], str):
            print(obj[key])
            break
PYEOF
)
  else
    # Last-resort fallback: no JSON parser available. Match "key":"...", taking
    # the first line that has it. This does not handle escaped quotes inside the
    # value, which is acceptable for a title/prompt preview (worst case: a
    # slightly clipped title, never a crash).
    val=$(grep -m1 -o "\"$key\":\"[^\"]*\"" "$file" 2>/dev/null | sed "s/^\"$key\":\"//; s/\"$//")
  fi

  printf '%s' "$val"
}

# -----------------------------------------------------------------------------
# csp_session_title FILE
#
# Best available one-line title for a session:
#   1) Claude's own generated title ("aiTitle"), if present.
#   2) Otherwise the last prompt you typed ("lastPrompt").
#   3) Otherwise "(untitled)".
# Newlines are flattened to spaces so a title can never span rows.
# -----------------------------------------------------------------------------
csp_session_title() {
  local file="$1" title
  title=$(csp_json_first_value "$file" aiTitle)
  [ -z "$title" ] && title=$(csp_json_first_value "$file" lastPrompt)
  [ -z "$title" ] && title="(untitled)"
  # Flatten any newlines/tabs to single spaces.
  printf '%s' "$title" | tr '\n\t' '  '
}

# -----------------------------------------------------------------------------
# csp_session_project FILE
#
# The working directory the session belongs to, read from the "cwd" field.
# Falls back to "?" if none is recorded.
# -----------------------------------------------------------------------------
csp_session_project() {
  local file="$1" cwd
  cwd=$(csp_json_first_value "$file" cwd)
  [ -z "$cwd" ] && cwd="?"
  printf '%s' "$cwd"
}

# -----------------------------------------------------------------------------
# csp_session_meta FILE
#
# Read a session's title AND project in a SINGLE pass over the file, printed as
#     title <TAB> cwd
#
# This exists purely for speed: the menu can hold dozens of sessions, and
# spawning a JSON parser three times per file (aiTitle, lastPrompt, cwd) made
# loading visibly slow. Reading everything in one `jq`/`python3` pass keeps the
# menu snappy. The granular helpers above are kept because they are trivially
# testable and used by the tests; this is the same logic, fused.
#
# Fallback order matches csp_json_first_value: jq, then python3, then a small
# built-in reader. Missing fields come back empty and callers tolerate that.
# -----------------------------------------------------------------------------
# How many characters of the title we ever keep. The extractor clips to this
# BEFORE handing the string to bash. This matters for more than tidiness:
#   • Speed — bash 3.2's ${var%%…}/${var#…} string operations are QUADRATIC in
#     the string length, so splitting a multi-megabyte title (a long pasted
#     prompt lands in lastPrompt) would freeze the picker for minutes. Clipping
#     inside jq/python/awk keeps every bash operation tiny and instant.
#   • Safety — clipping early also bounds how much we ever hold or scan.
# It is generously larger than CSP_MAX_TITLE_LEN (the display width) so the
# later display truncation still has room to add its ellipsis.
CSP_META_TITLE_CLIP=256

# How many lines from the TOP of a session file we scan for its title/cwd.
# Claude writes cwd, lastPrompt and aiTitle within the first handful of lines
# (empirically cwd@4, lastPrompt@9, aiTitle@12), and the title is set early and
# doesn't meaningfully change — so reading the whole file (these average several
# MB and thousands of lines) was ~6x slower for no benefit. We read a generous
# head window instead, which cut per-file parse time from ~70ms to ~12ms. 64 is
# far more than needed but leaves ample margin if the log format shifts.
#
# FILE-FORMAT ASSUMPTION (this tool reads Claude Code's UNDOCUMENTED store):
# we assume the fields `aiTitle`, `lastPrompt` and `cwd` all appear within the
# first CSP_META_HEAD_LINES lines of a `~/.claude/projects/**/*.jsonl` file. If a
# future Claude Code version writes those fields LATER in the file, the symptom
# is graceful — titles show as "(untitled)" and the project column as "?" — not
# a crash. The fix if that ever happens: raise this number (or drop the head cap
# and rely on the title-clip for speed). This is the single place coupled to
# Claude's layout; the extractor already tolerates missing fields everywhere.
#
# Overridable via the environment so an early adopter who hits a format change
# can widen the window without editing the source:
# CSP_META_HEAD_LINES=500 claude-session-picker.
#
# We normalise to a SANE POSITIVE integer:
#   • non-numeric / empty → the default (64);
#   • 0 (or a leading-zero form that evaluates to 0) → the default, because 0
#     would make `head -n 0` read nothing and every session show (untitled)/?;
#   • absurdly large values are capped at CSP_META_HEAD_MAX so a huge digit
#     string can't be interpreted differently by BSD head vs Python, nor make us
#     read an unbounded prefix.
CSP_META_HEAD_MAX=100000
CSP_META_HEAD_LINES="${CSP_META_HEAD_LINES:-64}"
case "$CSP_META_HEAD_LINES" in
  ''|*[!0-9]*) CSP_META_HEAD_LINES=64 ;;                       # non-numeric
  *)
    # Remove leading zeroes before checking length. Values longer than the
    # decimal representation of CSP_META_HEAD_MAX are capped BEFORE arithmetic,
    # so Bash integer overflow can never wrap a huge input back to a small value.
    csp_meta_head_zeroes="${CSP_META_HEAD_LINES%%[!0]*}"
    CSP_META_HEAD_LINES="${CSP_META_HEAD_LINES#"$csp_meta_head_zeroes"}"
    unset csp_meta_head_zeroes
    case "$CSP_META_HEAD_LINES" in
      '') CSP_META_HEAD_LINES=64 ;;                            # all zeroes
      ???????*) CSP_META_HEAD_LINES="$CSP_META_HEAD_MAX" ;;    # > 6 digits
      *) CSP_META_HEAD_LINES=$(( 10#$CSP_META_HEAD_LINES ))
         [ "$CSP_META_HEAD_LINES" -gt "$CSP_META_HEAD_MAX" ] && CSP_META_HEAD_LINES="$CSP_META_HEAD_MAX" ;;
    esac
    ;;
esac

csp_session_meta() {
  local file="$1" out title cwd tab
  tab=$'\t'

  # IMPORTANT: we join title and cwd with a TAB and split on it below, so the
  # title itself must contain no tabs or newlines — otherwise a title like
  # "fix\ttest" would be mistaken for two fields. Each branch therefore strips
  # tabs/newlines AND all other control characters from the title before
  # joining. Stripping control characters also stops a title that contains
  # terminal escape sequences (from arbitrary conversation content) from
  # clearing the screen or retitling the window when we later draw it.
  #
  # We feed only the file's HEAD (CSP_META_HEAD_LINES) to the parser rather than
  # the whole multi-MB file — that's the big startup-speed win (see the constant
  # above). `head` closing the pipe early can make the producer see EPIPE; that's
  # harmless here and suppressed.
  if command -v jq >/dev/null 2>&1; then
    # One jq program that emits "title<TAB>cwd".
    #   -R  reads each line as RAW text (not pre-parsed), and
    #   -n  with `inputs` lets us pull those lines in ourselves, so that
    #   `fromjson? // empty` can SKIP any malformed/truncated line instead of
    #   aborting the whole file. (A single corrupt line is common in a live
    #   session log and must not blank out an otherwise-good title.)
    # We keep only the three small fields per line (memory), pick the first
    # non-null aiTitle/lastPrompt/cwd, strip control chars, and CLIP the title
    # to CSP_META_TITLE_CLIP so bash never touches a huge string.
    out=$(head -n "$CSP_META_HEAD_LINES" "$file" 2>/dev/null \
      | jq -rRn --argjson clip "$CSP_META_TITLE_CLIP" '
      [inputs | fromjson? // empty
        | {t: .aiTitle, p: .lastPrompt, c: .cwd}] as $o
    # Keep only non-empty STRINGS (a present-but-empty "aiTitle":"" must NOT beat
    # a real lastPrompt: the jq // operator treats "" as present, so filter it
    # out here to match the python/awk branches, which accept only a non-empty
    # string). NOTE: no apostrophes in this jq program — it is single-quoted in
    # the shell, so an apostrophe would terminate the quote.
    | ($o | map(.t) | map(select(type == "string" and . != "")) | .[0]) as $t
    | ($o | map(.p) | map(select(type == "string" and . != "")) | .[0]) as $p
    | ($o | map(.c) | map(select(type == "string" and . != "")) | .[0]) as $c
    | ((($t // $p // "")[:$clip] | gsub("[[:cntrl:]]"; " ")) + "\t" + ($c // ""))
    ' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    out=$(CSP_CLIP="$CSP_META_TITLE_CLIP" CSP_HEAD="$CSP_META_HEAD_LINES" python3 - "$file" <<'PYEOF' 2>/dev/null
import json, os, sys
clip = int(os.environ.get("CSP_CLIP", "256"))
head = int(os.environ.get("CSP_HEAD", "64"))
title = prompt = cwd = ""
with open(sys.argv[1], "r", errors="replace") as fh:
    for n, line in enumerate(fh):
        if n >= head:            # only scan the head; the fields live up top
            break
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        if not title and isinstance(o.get("aiTitle"), str):
            title = o["aiTitle"]
        if not prompt and isinstance(o.get("lastPrompt"), str):
            prompt = o["lastPrompt"]
        if not cwd and isinstance(o.get("cwd"), str):
            cwd = o["cwd"]
# Clip first (bounds work), then replace every control character with a space so
# the TAB separator stays unambiguous and no escape sequence reaches the screen.
chosen = (title or prompt or "")[:clip]
chosen = "".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in chosen)
print(chosen + "\t" + cwd)
PYEOF
)
  else
    # No JSON parser available: stream at most CSP_META_HEAD_LINES through awk,
    # extracting and clipping before anything reaches a Bash variable. This
    # preserves the bounded-input guarantee even when one JSONL line contains a
    # multi-megabyte prompt. Escaped quotes inside values remain unsupported,
    # matching the documented limitation of the granular fallback reader.
    out=$(awk -v max_lines="$CSP_META_HEAD_LINES" -v clip="$CSP_META_TITLE_CLIP" '
      function json_string(key, marker, start, rest, stop) {
        marker = "\"" key "\":\""
        start = index($0, marker)
        if (!start) return ""
        rest = substr($0, start + length(marker))
        stop = index(rest, "\"")
        if (!stop) return ""
        return substr(rest, 1, stop - 1)
      }
      {
        if (title == "")  { value = json_string("aiTitle");    if (value != "") title = value }
        if (prompt == "") { value = json_string("lastPrompt"); if (value != "") prompt = value }
        if (cwd == "")    { value = json_string("cwd");        if (value != "") cwd = value }
        # Stop after processing the final allowed record. A leading
        # `NR > max_lines` rule would already have read record max_lines + 1.
        if (NR >= max_lines) exit
      }
      END {
        chosen = (title != "" ? title : prompt)
        chosen = substr(chosen, 1, clip)
        # Replace control chars with a space (NOT delete) so this path renders
        # an embedded newline/tab as "line1 line2", identical to the jq and
        # python extractors above. Deleting them would collapse to "line1line2"
        # and make the same session show a different title per available tool.
        gsub(/[[:cntrl:]]/, " ", chosen)
        printf "%s\t%s", chosen, cwd
      }
    ' "$file" 2>/dev/null)
  fi

  # Defence in depth: even if an extractor misbehaved, make sure bash never
  # splits a huge string here. `out` is already clipped title + short cwd path,
  # but cap its total length before the (quadratic) parameter expansions.
  out="${out:0:8192}"

  # Split on the FIRST tab (the separator) and apply the same empty-value
  # fallbacks the granular helpers use.
  title="${out%%"$tab"*}"
  cwd="${out#*"$tab"}"
  [ "$cwd" = "$out" ] && cwd=""          # no tab found → no cwd
  # Strip control characters from the cwd too. Each parser already neuters the
  # TITLE inside its own engine (jq/python/awk), because the title must first be
  # CLIPPED there to bound the work before it reaches bash. The cwd needs no such
  # clipping (it is a short path), so one strip here — after the split, covering
  # all three parsers at once — is the simpler place to do it. Without it, a
  # crafted/corrupted transcript with an ESC/BEL/newline in Claude's own `cwd`
  # field could emit an escape sequence to the screen or, via an embedded
  # tab/newline, break the drawn row or the `--list` four-column TSV contract.
  # Fold every control byte to a space (same `[[:cntrl:]]` set the parsers use).
  # LC_ALL=C makes the class the fixed ASCII control set (0x00–0x1f, 0x7f) rather
  # than a locale-dependent one, so the result is deterministic everywhere.
  cwd=$(printf '%s' "$cwd" | LC_ALL=C tr '[:cntrl:]' ' ')
  # A cwd that was ONLY control characters is now only spaces. Treat that (and a
  # genuinely empty cwd) as "no cwd" so it falls to the "?" placeholder rather
  # than a misleading blank — and so the awk path (which, unlike jq/python, will
  # extract from a control-char-bearing line) agrees with the other two.
  case "$cwd" in *[![:space:]]*) ;; *) cwd="" ;; esac
  [ -z "$title" ] && title="(untitled)"
  [ -z "$cwd" ] && cwd="?"
  printf '%s%s%s' "$title" "$tab" "$cwd"
}

# -----------------------------------------------------------------------------
# csp_file_mtime FILE
#
# Last-modified time of FILE in epoch seconds — our "last active" signal. Tries
# BSD `stat` (macOS) first, then GNU `stat` (Linux).
#
# CRUCIAL GUARD: the two `stat` dialects use the SAME flags for different things
# (`-f` is a format on BSD but "report on the filesystem" on GNU), so relying on
# exit status alone is unsafe — a wrong-platform call can "succeed" yet print
# something non-numeric. We therefore VALIDATE the result: anything that isn't
# all digits becomes 0. That makes the OS question moot and guarantees the value
# we return is always a safe integer for the caller's arithmetic. 0 is rendered
# by csp_humanize_age as "just now" rather than crashing.
# -----------------------------------------------------------------------------
csp_file_mtime() {
  local file="$1" m
  m=$(stat -f '%m' "$file" 2>/dev/null) || m=$(stat -c '%Y' "$file" 2>/dev/null) || m=0
  case "$m" in
    ''|*[!0-9]*) m=0 ;;   # empty or non-numeric (wrong stat dialect) → 0
  esac
  printf '%s' "$m"
}

# -----------------------------------------------------------------------------
# csp_running_session_ids
#
# Print the session ids that currently have a `claude` process, one per line,
# by scanning process arguments for "--resume <id>". Sessions started without
# --resume won't appear, which is fine: the marker is a helpful hint, not a
# guarantee, and its absence never causes wrong behaviour.
# -----------------------------------------------------------------------------
csp_running_session_ids() {
  # We want every process's FULL command line so a "--resume <id>" late in a
  # long line isn't cut off. `-ww` (double wide) disables width-based truncation
  # on GNU/Linux ps; macOS ps ignores `-ww` but doesn't truncate piped output
  # anyway, so `ps -eww -o args=` is safe on both. The empty `args=` header
  # keeps the output header-free. We then pull the id after each "--resume".
  # If the first form is rejected on some ps, fall back to the plainer one.
  { ps -eww -o args= 2>/dev/null || ps -eo args= 2>/dev/null; } \
    | grep -oE -- '--resume [0-9a-fA-F-]{8,}' \
    | awk '{print $2}' \
    | sort -u
}

# -----------------------------------------------------------------------------
# csp_list_session_files
#
# Print the path of every session .jsonl under the Claude projects directory,
# newest first (by modification time — the "last active" time shown in the
# menu), capped at CSP_MAX_SESSIONS so the menu can never grow without bound.
#
# HOW, and why it's built this way:
#   • `find … -print0` streams the paths NUL-separated, so we never build one
#     giant argument list (which could blow past the OS ARG_MAX limit with very
#     many sessions) and paths with spaces stay intact. `-mindepth/-maxdepth 2`
#     matches the projects/<dir>/<file>.jsonl layout exactly.
#   • `xargs -0 stat` prints "<mtime> <path>" for each file. We must sort by
#     mtime OURSELVES with a single global `sort -rn`, NOT rely on `ls -t`:
#     `ls -t` sorts only within each xargs batch, so once the file count exceeds
#     the xargs batch size the batches would each be sorted but the combined
#     stream would NOT be globally newest-first, and the cap below would then
#     drop the wrong files. Sorting centrally fixes that.
#   • Empty store: with no matching files, `find` emits nothing. BSD/macOS xargs
#     then skips the command entirely; GNU xargs runs `stat` once with no args,
#     which just errors to stderr (suppressed) and prints nothing to stdout — so
#     either way an empty store yields no rows. (We deliberately do NOT pass
#     `xargs -r`: it's a GNU-ism that older macOS xargs rejects outright, and
#     because we use `stat` rather than `ls` there's no current-directory leak
#     to guard against in the first place.)
#   • `stat` differs across platforms, so we try BSD (`-f '%m %N'`) then GNU
#     (`-c '%Y %n'`); the winner is chosen once per call.
#   • `cut -d' ' -f2-` strips only the leading "<mtime> " field, so a path that
#     itself contains spaces survives intact.
# -----------------------------------------------------------------------------
# csp_list_session_files_with_mtime — the same listing but WITHOUT dropping the
# mtime column, so each line is "<mtime> <path>". The loader uses this and reads
# the mtime straight from the line, which avoids a second `stat` fork per file
# just to get the age we already computed here for sorting (~7ms x N saved).
csp_list_session_files_with_mtime() {
  local dir="$CSP_CLAUDE_DIR/projects"
  [ -d "$dir" ] || return 0
  if stat -f '%m' "$dir" >/dev/null 2>&1; then      # BSD/macOS
    find "$dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print0 2>/dev/null \
      | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn -k1,1 | head -n "$CSP_MAX_SESSIONS"
  else                                              # GNU/Linux
    find "$dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print0 2>/dev/null \
      | xargs -0 stat -c '%Y %n' 2>/dev/null | sort -rn -k1,1 | head -n "$CSP_MAX_SESSIONS"
  fi
}

# csp_list_session_files — just the paths, newest first (mtime stripped). Kept
# as the stable public/tested interface; delegates to the *_with_mtime variant.
csp_list_session_files() {
  csp_list_session_files_with_mtime | cut -d' ' -f2-
}

# -----------------------------------------------------------------------------
# csp_session_id_from_path FILE
#
# The session id is just the file's name without the .jsonl extension.
# -----------------------------------------------------------------------------
csp_session_id_from_path() {
  local file="$1" base
  base="${file##*/}"        # strip directory
  printf '%s' "${base%.jsonl}"   # strip extension
}

# -----------------------------------------------------------------------------
# csp_delete_session_file FILE
#
# Permanently delete one session file (its .jsonl transcript). This throws away
# that conversation's history, so the interactive caller must confirm with the
# user FIRST — this function just does the deletion.
#
# SAFETY: we refuse to delete anything that isn't a regular .jsonl file living
# directly under the Claude projects directory. That guard means a corrupted or
# unexpected path can never make us remove something outside the session store
# (no directories, no files elsewhere, no symlink targets). Returns 0 on a
# successful delete, 1 if the path failed the safety check or the delete failed.
# -----------------------------------------------------------------------------
csp_delete_session_file() {
  local file="$1" projects="$CSP_CLAUDE_DIR/projects"

  # Must be a regular file (not a directory or symlink) ...
  [ -f "$file" ] || return 1
  # ... whose name ends in .jsonl ...
  case "$file" in *.jsonl) ;; *) return 1 ;; esac
  # ... and which actually lives under the projects directory.
  case "$file" in "$projects"/*) ;; *) return 1 ;; esac
  # Reject any path trickery with ".." segments, belt-and-suspenders.
  case "$file" in *..*) return 1 ;; esac

  rm -f -- "$file" 2>/dev/null || return 1
  return 0
}

# NOTE: launching a session now lives entirely in lib/backend.sh (hub and tmux
# backends). There is intentionally no single "resume and exec" helper here —
# whether we hand off with exec or return to the menu is a per-backend decision.
