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
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
  . "$BATS_TEST_DIRNAME/../lib/sessions.sh"

  export CSP_CLAUDE_DIR="$BATS_TEST_TMPDIR/claude"
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

@test "meta: missing everything yields (untitled) and ?" {
  empty="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-empty2.jsonl"
  printf '{"type":"mode","mode":"normal"}\n' > "$empty"
  run csp_session_meta "$empty"
  [ "$(csp_field "$output" 1)" = "(untitled)" ]
  [ "$(csp_field "$output" 2)" = "?" ]
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

@test "mtime: returns a positive epoch for an existing file" {
  run csp_file_mtime "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  [ "$output" -gt 0 ]
}

@test "missing projects dir is handled without error" {
  export CSP_CLAUDE_DIR="$BATS_TEST_TMPDIR/does-not-exist"
  run csp_list_session_files
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
