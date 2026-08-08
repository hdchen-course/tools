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
    { IFS= read -r -n 16 v < "$f"; } 2>/dev/null || v=""
  fi
  v="${v%$'\r'}"
  case "$v" in working|waiting) printf '%s' "$v" ;; esac
  return 0
}

# csp_write_state ID VALUE — record a session's state (best-effort; if the dir
# can't be created or written we just skip it, so this never fails a caller).
csp_write_state() {
  local id="$1" v="$2" f
  f=$(csp_state_file "$id")
  mkdir -p "$CSP_STATE_DIR" 2>/dev/null || return 0
  { printf '%s\n' "$v" > "$f"; } 2>/dev/null || true
}

# csp_clear_state ID — forget a session's state (e.g. once you've opened it, so
# its ✳ "needs attention" marker goes away). Best-effort.
csp_clear_state() {
  local f
  f=$(csp_state_file "$1")
  rm -f -- "$f" 2>/dev/null || true
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
    out=$(jq -rRn --argjson clip "$CSP_META_TITLE_CLIP" '
      [inputs | fromjson? // empty
        | {t: .aiTitle, p: .lastPrompt, c: .cwd}] as $o
    | ($o | map(.t) | map(select(. != null)) | .[0]) as $t
    | ($o | map(.p) | map(select(. != null)) | .[0]) as $p
    | ($o | map(.c) | map(select(. != null)) | .[0]) as $c
    | ((($t // $p // "")[:$clip] | gsub("[[:cntrl:]]"; " ")) + "\t" + ($c // ""))
    ' "$file" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    out=$(CSP_CLIP="$CSP_META_TITLE_CLIP" python3 - "$file" <<'PYEOF' 2>/dev/null
import json, os, sys
clip = int(os.environ.get("CSP_CLIP", "256"))
title = prompt = cwd = ""
with open(sys.argv[1], "r", errors="replace") as fh:
    for line in fh:
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
    # No JSON parser available: use the granular grep-based readers, then clip
    # and sanitise here so this path has the same guarantees as the others.
    title=$(csp_session_title "$file")
    cwd=$(csp_session_project "$file")
    # Clip with a bash substring (short strings only reach here in practice, and
    # the clip itself bounds the cost), then strip control chars via tr.
    title=$(printf '%s' "${title:0:$CSP_META_TITLE_CLIP}" | tr -d '\000-\037\177')
    out="$title$tab$cwd"
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
csp_list_session_files() {
  local dir="$CSP_CLAUDE_DIR/projects" statfmt
  [ -d "$dir" ] || return 0

  # Pick the stat dialect once (BSD prints mtime for a probe; else assume GNU).
  if stat -f '%m' "$dir" >/dev/null 2>&1; then
    statfmt="bsd"
  else
    statfmt="gnu"
  fi

  if [ "$statfmt" = "bsd" ]; then
    find "$dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print0 2>/dev/null \
      | xargs -0 stat -f '%m %N' 2>/dev/null \
      | sort -rn -k1,1 \
      | cut -d' ' -f2- \
      | head -n "$CSP_MAX_SESSIONS"
  else
    find "$dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print0 2>/dev/null \
      | xargs -0 stat -c '%Y %n' 2>/dev/null \
      | sort -rn -k1,1 \
      | cut -d' ' -f2- \
      | head -n "$CSP_MAX_SESSIONS"
  fi
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
