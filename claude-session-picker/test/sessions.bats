#!/usr/bin/env bats
# =============================================================================
# sessions.bats — tests for lib/sessions.sh against a FAKE Claude store.
#
# We build a throwaway ~/.claude/projects tree in a temp dir and point the code
# at it with CSP_CLAUDE_DIR. No real Claude data is touched and no `claude`
# process is launched. This verifies the JSON extraction (whatever parser is
# available), the newest-first listing, the cap, and title/project fallbacks.
#
# Run with:  bats test/sessions.bats
# =============================================================================

setup() {
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"   # stable char counting for titles
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
  . "$BATS_TEST_DIRNAME/../lib/sessions.sh"

  export CSP_CLAUDE_DIR="$BATS_TEST_TMPDIR/claude"
  export CSP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta"

  # A session with an AI title and a cwd.
  cat > "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl" <<'EOF'
{"type":"mode","mode":"normal"}
{"type":"ai-title","aiTitle":"Refactor the parser"}
{"type":"user","cwd":"/Volumes/demo/alpha","message":{"content":"hi"}}
EOF

  # A session with NO ai-title, only a lastPrompt — tests the fallback.
  cat > "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta/id-beta.jsonl" <<'EOF'
{"type":"mode","mode":"normal"}
{"type":"last-prompt","lastPrompt":"fix the flaky test","cwd":"/Volumes/demo/beta"}
{"type":"user","cwd":"/Volumes/demo/beta","message":{"content":"hi"}}
EOF
}

@test "list: finds every session file, newest first" {
  # Make beta newer than alpha so ordering is deterministic.
  touch -t 202601010000 "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  touch -t 202606010000 "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta/id-beta.jsonl"
  run csp_list_session_files
  [ "$status" -eq 0 ]
  first=$(printf '%s\n' "$output" | head -1)
  case "$first" in *id-beta.jsonl) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "id: derived from the file name" {
  run csp_session_id_from_path "/a/b/id-alpha.jsonl"
  [ "$output" = "id-alpha" ]
}

@test "title: prefers the AI-generated title" {
  run csp_session_title "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$output" = "Refactor the parser" ]
}

@test "title: falls back to the last prompt when no AI title" {
  run csp_session_title "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta/id-beta.jsonl"
  [ "$output" = "fix the flaky test" ]
}

@test "title: missing everything yields (untitled)" {
  empty="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-empty.jsonl"
  printf '{"type":"mode","mode":"normal"}\n' > "$empty"
  run csp_session_title "$empty"
  [ "$output" = "(untitled)" ]
}

@test "project: read from the cwd field" {
  run csp_session_project "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$output" = "/Volumes/demo/alpha" ]
}

@test "meta: single-pass reader returns title<TAB>cwd" {
  run csp_session_meta "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$(csp_field "$output" 1)" = "Refactor the parser" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/alpha" ]
}

@test "meta: falls back to lastPrompt for the title" {
  run csp_session_meta "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta/id-beta.jsonl"
  [ "$(csp_field "$output" 1)" = "fix the flaky test" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/beta" ]
}

@test "meta: a title containing tabs/newlines cannot corrupt the field split" {
  # A malicious/odd title with an embedded tab and newline must be flattened so
  # csp_field still reads exactly two fields: the whole title, then the cwd.
  tricky="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-tricky.jsonl"
  printf '%s\n' '{"type":"ai-title","aiTitle":"fix\tthe\nflaky test"}' > "$tricky"
  printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/alpha"}' >> "$tricky"
  run csp_session_meta "$tricky"
  # cwd must survive intact in field 2 (proves the title didn't leak a tab).
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/alpha" ]
  # title in field 1 must contain no tab character.
  title="$(csp_field "$output" 1)"
  case "$title" in *"$(printf '\t')"*) leaked=1 ;; *) leaked=0 ;; esac
  [ "$leaked" = "0" ]
}

@test "meta: a good title is recovered even when other lines are malformed" {
  # Session logs can contain a truncated or garbage line. One bad line must not
  # blank out an otherwise-readable title/cwd.
  mixed="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-mixed.jsonl"
  printf '%s\n' 'not json at all' > "$mixed"
  printf '%s\n' '{"broken' >> "$mixed"
  printf '%s\n' '{"type":"ai-title","aiTitle":"recovered title"}' >> "$mixed"
  printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/alpha"}' >> "$mixed"
  run csp_session_meta "$mixed"
  [ "$(csp_field "$output" 1)" = "recovered title" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/alpha" ]
}

@test "meta: a zero-byte session file does not crash" {
  empty="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-zero.jsonl"
  : > "$empty"
  run csp_session_meta "$empty"
  [ "$status" -eq 0 ]
  [ "$(csp_field "$output" 1)" = "(untitled)" ]
}

@test "meta: control characters and ANSI escapes are stripped from the title" {
  # A title from conversation content could contain an escape sequence that
  # would clear the screen or retitle the window when drawn. It must be neutered.
  esc="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-esc.jsonl"
  printf '{"type":"ai-title","aiTitle":"%b"}\n' 'a[2J[Hbc' > "$esc"
  printf '{"type":"user","cwd":"/Volumes/demo/alpha"}\n' >> "$esc"
  run csp_session_meta "$esc"
  title="$(csp_field "$output" 1)"
  # No ESC (0x1b) or BEL (0x07) may survive.
  case "$title" in *$'\033'*) bad=1 ;; *$'\007'*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
  # cwd still intact.
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/alpha" ]
}

@test "meta: a huge tab-less title is handled quickly (no quadratic freeze)" {
  # Regression test for the quadratic bash-3.2 string split. A ~256KB single
  # title must be clipped by the extractor, so this returns effectively instantly
  # rather than freezing. We assert it finishes and the title is clipped short.
  big="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-big.jsonl"
  {
    printf '{"type":"last-prompt","lastPrompt":"'
    # 256K of 'x' with no tabs/newlines.
    i=0; while [ "$i" -lt 256 ]; do printf '%01024d' 0 | tr '0' 'x'; i=$((i + 1)); done
    printf '","cwd":"/Volumes/demo/alpha"}\n'
  } > "$big"
  run csp_session_meta "$big"
  [ "$status" -eq 0 ]
  title="$(csp_field "$output" 1)"
  # Clipped well below the raw size (extractor clip is CSP_META_TITLE_CLIP=256).
  [ "${#title}" -le 300 ]
}

@test "meta: missing everything yields (untitled) and ?" {
  empty="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-empty2.jsonl"
  printf '{"type":"mode","mode":"normal"}\n' > "$empty"
  run csp_session_meta "$empty"
  [ "$(csp_field "$output" 1)" = "(untitled)" ]
  [ "$(csp_field "$output" 2)" = "?" ]
}

@test "list: handles a very large number of sessions without ARG_MAX errors" {
  # The find|xargs approach must cope with far more files than a shell glob
  # could pass as one argument list. 1500 keeps the test fast but well past the
  # point a naive glob would risk "argument list too long" on small ARG_MAX.
  many="$CSP_CLAUDE_DIR/projects/-Volumes-demo-many"
  mkdir -p "$many"
  i=1
  while [ "$i" -le 1500 ]; do
    printf '{"type":"mode"}\n' > "$many/s$i.jsonl"
    i=$((i + 1))
  done
  run csp_list_session_files
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c . || true)
  # Capped at CSP_MAX_SESSIONS (1000) and definitely produced output.
  [ "$count" -gt 0 ]
  [ "$count" -le "$CSP_MAX_SESSIONS" ]
}

@test "list: finds sessions even when the project path contains spaces" {
  # NUL-separated find|xargs must not split on spaces in directory names.
  spaced="$CSP_CLAUDE_DIR/projects/-Volumes-my project-dir"
  mkdir -p "$spaced"
  printf '{"type":"ai-title","aiTitle":"spaced"}\n' > "$spaced/sp.jsonl"
  run csp_list_session_files
  case "$output" in *"my project"*"/sp.jsonl") ok=1 ;; *"my project"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cap: never lists more than CSP_MAX_SESSIONS files" {
  CSP_MAX_SESSIONS=2
  # Create 5 sessions; expect only 2 back.
  for n in 1 2 3 4 5; do
    printf '{"type":"mode"}\n' > "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/s$n.jsonl"
  done
  run csp_list_session_files
  count=$(printf '%s\n' "$output" | grep -c . || true)
  [ "$count" -le 2 ]
}

@test "list: ordering is GLOBAL newest-first, and the cap keeps the newest" {
  # Regression for the batched-sort bug: build many files with a known newest,
  # cap to 1, and require that the single kept file is the globally newest —
  # which fails if each xargs batch were sorted independently.
  many="$CSP_CLAUDE_DIR/projects/-Volumes-demo-many"
  mkdir -p "$many"
  n=1
  while [ "$n" -le 60 ]; do
    touch -t "202601010000.$(printf '%02d' "$((n % 60))")" "$many/s$n.jsonl" 2>/dev/null \
      || touch "$many/s$n.jsonl"
    n=$((n + 1))
  done
  # Make one specific file unambiguously the newest.
  sleep 1; touch "$many/WINNER.jsonl"
  CSP_MAX_SESSIONS=1
  run csp_list_session_files
  first=$(printf '%s\n' "$output" | head -1)
  case "$first" in *WINNER.jsonl) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "list: an existing but EMPTY store yields nothing (no cwd leak)" {
  # Regression for the xargs-with-no-input bug: a project dir with no *.jsonl
  # must produce zero lines, not fall back to listing the current directory.
  empty="$BATS_TEST_TMPDIR/emptystore"
  mkdir -p "$empty/projects/-Volumes-demo-empty"
  # Run from a directory that DOES contain files, to catch a cwd-listing leak.
  run bash -c "cd '$BATS_TEST_DIRNAME' && CSP_CLAUDE_DIR='$empty' bash -c '. \"$BATS_TEST_DIRNAME/../lib/core.sh\"; . \"$BATS_TEST_DIRNAME/../lib/sessions.sh\"; csp_list_session_files'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mtime: returns a positive epoch for an existing file" {
  run csp_file_mtime "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$output" -gt 0 ]
}

@test "mtime: a non-numeric stat result is coerced to 0 (never breaks arithmetic)" {
  # Simulate the wrong-platform stat dialect that "succeeds" but prints junk.
  stat() { printf 'not-a-number\n'; return 0; }
  run csp_file_mtime "/whatever"
  [ "$output" = "0" ]
  # And the value is safe to use in arithmetic (the real consumer does now-mtime).
  run bash -c "m=$output; echo \$((100 - m))"
  [ "$output" = "100" ]
}

@test "delete: removes a real session file under the projects dir" {
  f="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-del.jsonl"
  printf '{"type":"mode"}\n' > "$f"
  [ -f "$f" ]
  run csp_delete_session_file "$f"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
}

@test "delete: refuses a path outside the projects dir" {
  outside="$BATS_TEST_TMPDIR/precious.jsonl"
  printf 'keep me\n' > "$outside"
  run csp_delete_session_file "$outside"
  [ "$status" -ne 0 ]
  [ -f "$outside" ]        # untouched
}

@test "delete: refuses a non-.jsonl file even inside projects" {
  other="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/notes.txt"
  printf 'keep\n' > "$other"
  run csp_delete_session_file "$other"
  [ "$status" -ne 0 ]
  [ -f "$other" ]
}

@test "delete: refuses a path containing .. segments" {
  f="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  run csp_delete_session_file "$CSP_CLAUDE_DIR/projects/../projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$status" -ne 0 ]
  [ -f "$f" ]              # the real file survives
}

@test "delete: refuses a directory" {
  d="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  run csp_delete_session_file "$d"
  [ "$status" -ne 0 ]
  [ -d "$d" ]
}

@test "state: write then read round-trips working/waiting" {
  csp_write_state "sess-1" "working"
  run csp_read_state "sess-1"
  [ "$output" = "working" ]
  csp_write_state "sess-1" "waiting"
  run csp_read_state "sess-1"
  [ "$output" = "waiting" ]
}

@test "state: reading an unknown session yields nothing (not an error)" {
  run csp_read_state "never-seen"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state: an invalid stored value is ignored" {
  mkdir -p "$CSP_STATE_DIR"
  printf 'bogus\n' > "$(csp_state_file "sess-x")"
  run csp_read_state "sess-x"
  [ -z "$output" ]
}

@test "state: a value with NO trailing newline still loads" {
  # A crash mid-write or a hand-edited file may lack the trailing newline; the
  # value must not be dropped just because `read -n` reports EOF.
  mkdir -p "$CSP_STATE_DIR"
  printf 'working' > "$(csp_state_file "sess-nonl")"   # no \n
  run csp_read_state "sess-nonl"
  [ "$output" = "working" ]
}

@test "state: clear removes the recorded state" {
  csp_write_state "sess-2" "waiting"
  [ -n "$(csp_read_state "sess-2")" ]
  csp_clear_state "sess-2"
  run csp_read_state "sess-2"
  [ -z "$output" ]
}

@test "state: a session id with odd characters can't escape the state dir" {
  # The id is sanitised, so a path-traversal-looking id stays inside the dir.
  csp_write_state "../../etc/evil" "working"
  # Nothing was created outside the state dir.
  [ ! -e "$BATS_TEST_TMPDIR/etc/evil" ]
  # And it reads back correctly from within the state dir.
  run csp_read_state "../../etc/evil"
  [ "$output" = "working" ]
}

@test "missing projects dir is handled without error" {
  export CSP_CLAUDE_DIR="$BATS_TEST_TMPDIR/does-not-exist"
  run csp_list_session_files
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
