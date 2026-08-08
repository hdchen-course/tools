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

# csp_now_epoch — current time in whole seconds. Wrapped in a function so tests
# can override "now" and get deterministic ages.
csp_now_epoch() {
  date +%s
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
csp_session_meta() {
  local file="$1" out title cwd tab
  tab=$'\t'

  # IMPORTANT: we join title and cwd with a TAB and split on it below, so the
  # title itself must contain no tabs or newlines — otherwise a title like
  # "fix\ttest" would be mistaken for two fields. Each branch therefore replaces
  # any tab/newline INSIDE the title with a space before joining. (Paths in cwd
  # never contain tabs, so the separator stays unambiguous.)
  if command -v jq >/dev/null 2>&1; then
    # One jq program that emits "title<TAB>cwd".
    #   -R  reads each line as RAW text (not pre-parsed), and
    #   -n  with `inputs` lets us pull those lines in ourselves, so that
    #   `fromjson? // empty` can SKIP any malformed/truncated line instead of
    #   aborting the whole file. (A single corrupt line is common in a live
    #   session log and must not blank out an otherwise-good title.)
    # We then pick the first non-null aiTitle, lastPrompt and cwd across the
    # surviving objects. Doing it in one jq invocation keeps loading fast, and
    # gsub flattens tabs/newlines in the title so the TAB separator is safe.
    out=$(jq -rRn '
      [inputs | fromjson? // empty] as $o
    | ($o | map(.aiTitle)    | map(select(. != null)) | .[0]) as $t
    | ($o | map(.lastPrompt) | map(select(. != null)) | .[0]) as $p
    | ($o | map(.cwd)        | map(select(. != null)) | .[0]) as $c
    | ((($t // $p // "") | gsub("[\t\n\r]"; " ")) + "\t" + ($c // ""))
    ' "$file" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    out=$(python3 - "$file" <<'PYEOF' 2>/dev/null
import json, sys
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
# Flatten any tab/newline in the title so the TAB separator stays unambiguous.
chosen = (title or prompt or "")
for ch in ("\t", "\n", "\r"):
    chosen = chosen.replace(ch, " ")
print(chosen + "\t" + cwd)
PYEOF
)
  else
    # No JSON parser: fall back to the granular grep-based readers. csp_session_title
    # already flattens tabs/newlines, so the join below stays unambiguous.
    title=$(csp_session_title "$file")
    cwd=$(csp_session_project "$file")
    out="$title$tab$cwd"
  fi

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
# Last-modified time of FILE in epoch seconds — our "last active" signal. Uses
# BSD `stat` (macOS) first, then GNU `stat` (Linux). Prints 0 if
# neither works, which csp_humanize_age renders as "just now" rather than
# crashing.
# -----------------------------------------------------------------------------
csp_file_mtime() {
  local file="$1" m
  m=$(stat -f '%m' "$file" 2>/dev/null) || m=$(stat -c '%Y' "$file" 2>/dev/null) || m=0
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
  # -ww so long argument lists aren't truncated; grep only the resume ids.
  ps -eo args=w 2>/dev/null \
    | grep -oE -- '--resume [0-9a-fA-F-]{8,}' \
    | awk '{print $2}' \
    | sort -u
}

# -----------------------------------------------------------------------------
# csp_list_session_files
#
# Print the path of every session .jsonl under the Claude projects directory,
# newest first, capped at CSP_MAX_SESSIONS so the menu can never grow without
# bound. `ls -t` sorts by modification time (most recently active first), which
# is exactly the order a user wants to scan.
# -----------------------------------------------------------------------------
csp_list_session_files() {
  local dir="$CSP_CLAUDE_DIR/projects"
  [ -d "$dir" ] || return 0
  # List newest-first; head enforces the hard cap. `2>/dev/null` hides the
  # "no matches" noise when a project folder has no sessions yet.
  ls -t "$dir"/*/*.jsonl 2>/dev/null | head -n "$CSP_MAX_SESSIONS"
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
# csp_resume_session ID PROJECT
#
# Hand control to Claude Code, resuming session ID. We `cd` into the session's
# original project directory first (if it still exists) so the resumed session
# has the right working directory, then `exec` claude so it replaces this
# process — when you quit Claude you're back at your shell, not this picker.
# -----------------------------------------------------------------------------
csp_resume_session() {
  local id="$1" project="$2"
  # cd into the project if it still exists. If the cd fails for any reason we
  # deliberately continue from the current directory rather than aborting — the
  # session can still be resumed, just from wherever we already are.
  if [ -n "$project" ] && [ -d "$project" ]; then
    cd "$project" 2>/dev/null || true
  fi
  exec claude --resume "$id"
}
