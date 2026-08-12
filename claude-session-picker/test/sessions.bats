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
  # Start from a known default regardless of the CALLER's environment — a test
  # that asserts "the default is 64" must not inherit CSP_META_HEAD_LINES=500
  # from whoever invoked bats.
  unset CSP_META_HEAD_LINES
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

@test "list-with-mtime: each line is '<mtime> <path>', newest first" {
  touch -t 202601010000 "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-alpha.jsonl"
  touch -t 202606010000 "$CSP_CLAUDE_DIR/projects/-Volumes-demo-beta/id-beta.jsonl"
  run csp_list_session_files_with_mtime
  [ "$status" -eq 0 ]
  first=$(printf '%s\n' "$output" | head -1)
  # Leading field is all digits (the mtime), and the newest (beta) is first.
  mt="${first%% *}"
  case "$mt" in ''|*[!0-9]*) ok=0 ;; *) ok=1 ;; esac
  [ "$ok" = "1" ]
  case "$first" in *id-beta.jsonl) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # The plain listing is the same paths with the mtime column stripped.
  run csp_list_session_files
  case "$(printf '%s\n' "$output" | head -1)" in *id-beta.jsonl) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "meta: reads only the file HEAD (title/cwd near the top), ignores later junk" {
  # A well-formed head with cwd+aiTitle, then far past the head-window a line
  # with a DIFFERENT cwd that must NOT override the real one.
  big="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-head.jsonl"
  {
    printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/real"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"head title"}'
    n=0; while [ "$n" -lt 200 ]; do printf '%s\n' '{"type":"assistant","content":"x"}'; n=$((n+1)); done
    printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/WRONG"}'
  } > "$big"
  run csp_session_meta "$big"
  [ "$(csp_field "$output" 1)" = "head title" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/real" ]
}

@test "meta: CSP_META_HEAD_LINES override widens the scan window" {
  # A title that only appears PAST the default 64-line window: with the default
  # it's missed (untitled); with a raised override it's found. Proves the env
  # override is honoured (and re-read at source time).
  deep="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-deep.jsonl"
  {
    printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/real"}'
    n=0; while [ "$n" -lt 100 ]; do printf '%s\n' '{"type":"assistant","content":"x"}'; n=$((n+1)); done
    printf '%s\n' '{"type":"ai-title","aiTitle":"deep title"}'   # ~line 102
  } > "$deep"
  # Default (64): title is beyond the window → (untitled).
  run csp_session_meta "$deep"
  [ "$(csp_field "$output" 1)" = "(untitled)" ]
  # Override to 500 (re-source so the constant is recomputed): now found.
  run env CSP_META_HEAD_LINES=500 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    m=$(csp_session_meta "'"$deep"'"); csp_field "$m" 1'
  [ "$output" = "deep title" ]
}

@test "meta: a non-numeric CSP_META_HEAD_LINES falls back to the default" {
  run env CSP_META_HEAD_LINES=bogus bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    printf "%s" "$CSP_META_HEAD_LINES"'
  [ "$output" = "64" ]
}

@test "meta: CSP_META_HEAD_LINES is normalised before shell arithmetic" {
  # 0 would make head read nothing. Oversized values are capped lexically before
  # arithmetic so they cannot overflow and wrap back to a small positive limit.
  run env CSP_META_HEAD_LINES=0 bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    printf "%s" "$CSP_META_HEAD_LINES"'
  [ "$output" = "64" ]
  run env CSP_META_HEAD_LINES=00064 bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    printf "%s" "$CSP_META_HEAD_LINES"'
  [ "$output" = "64" ]
  run env CSP_META_HEAD_LINES=999999999 bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    printf "%s" "$CSP_META_HEAD_LINES"'
  [ "$output" = "100000" ]
  # This value wrapped to 1 when converted before the upper-bound check.
  run env CSP_META_HEAD_LINES=18446744073709551617 bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    printf "%s" "$CSP_META_HEAD_LINES"'
  [ "$output" = "100000" ]
}

@test "meta: the built-in (no jq/python) reader ALSO honours CSP_META_HEAD_LINES" {
  # Regression: the dependency-light fallback used to scan the whole file,
  # ignoring the limit. Force that path by shadowing jq/python detection.
  deep="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-deepfb.jsonl"
  {
    printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/real"}'
    n=0; while [ "$n" -lt 30 ]; do printf '%s\n' '{"type":"assistant"}'; n=$((n+1)); done
    printf '%s\n' '{"type":"ai-title","aiTitle":"fallback deep title"}'   # ~line 32
  } > "$deep"
  # limit=5 via the fallback: the title (line 32) must NOT be found.
  run env CSP_META_HEAD_LINES=5 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" bash -c '
    command() { if [ "$1" = "-v" ] && { [ "$2" = jq ] || [ "$2" = python3 ]; }; then return 1; fi; builtin command "$@"; }
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    csp_session_meta "'"$deep"'"'
  [ "$(csp_field "$output" 1)" = "(untitled)" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/real" ]
  # limit=64 via the fallback: now the title and project are both found.
  run env CSP_META_HEAD_LINES=64 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" bash -c '
    command() { if [ "$1" = "-v" ] && { [ "$2" = jq ] || [ "$2" = python3 ]; }; then return 1; fi; builtin command "$@"; }
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    csp_session_meta "'"$deep"'"'
  [ "$(csp_field "$output" 1)" = "fallback deep title" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/real" ]
}

@test "meta: fallback stops reading at CSP_META_HEAD_LINES" {
  # A FIFO makes read-ahead observable: line 2 is deliberately delayed. With a
  # limit of 1, the parser must return after line 1 instead of waiting for line 2.
  fifo="$BATS_TEST_TMPDIR/meta-head.fifo"
  mkfifo "$fifo"
  {
    printf '%s\n' '{"type":"ai-title","aiTitle":"first","cwd":"/Volumes/demo/first"}'
    sleep 3
    printf '%s\n' '{"type":"ai-title","aiTitle":"outside limit"}'
  } > "$fifo" &
  writer=$!
  started=$SECONDS
  run env CSP_META_HEAD_LINES=1 bash -c '
    command() { if [ "$1" = "-v" ] && { [ "$2" = jq ] || [ "$2" = python3 ]; }; then return 1; fi; builtin command "$@"; }
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    csp_session_meta "'"$fifo"'"'
  elapsed=$((SECONDS - started))
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 2 ]
  [ "$(csp_field "$output" 1)" = "first" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/first" ]
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

@test "meta: the awk fallback REPLACES control chars with a space, matching jq/python" {
  # Regression: the awk fallback used to DELETE control chars (gsub(..., "")),
  # so an embedded newline rendered "line1line2" — while jq/python replace with
  # a space, giving "line1 line2". The same session then showed a different
  # title depending on which extractor was installed. All paths must agree:
  # control chars become a single space.
  # Use a real tab byte (0x09) via %b: a control char that stays on ONE physical
  # line (unlike a literal newline, which would split the JSON record and is a
  # separate line-oriented limitation of the awk reader). Deletion would yield
  # "line1line2"; replacement yields "line1 line2".
  nl="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-nl.jsonl"
  printf '{"type":"ai-title","aiTitle":"%b"}\n' 'line1\tline2' > "$nl"
  printf '{"type":"user","cwd":"/Volumes/demo/alpha"}\n' >> "$nl"
  # Force the awk fallback by shadowing jq/python3 detection.
  run env CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" bash -c '
    command() { if [ "$1" = "-v" ] && { [ "$2" = jq ] || [ "$2" = python3 ]; }; then return 1; fi; builtin command "$@"; }
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    csp_session_meta "'"$nl"'"'
  [ "$(csp_field "$output" 1)" = "line1 line2" ]
  [ "$(csp_field "$output" 2)" = "/Volumes/demo/alpha" ]
}

@test "meta: control characters in the CWD are stripped too (not just the title)" {
  # Regression: every parser neutered the title but passed cwd through verbatim,
  # so an ESC/BEL in Claude's own cwd field could reach the screen or break the
  # --list TSV. All three parsers must strip control chars from cwd as well.
  #
  # The control chars are delivered as VALID JSON escapes. A RAW control byte
  # inside a JSON string is invalid JSON, which jq/python reject upstream (the
  # strip would then never run and the test would pass vacuously). We write the
  # fixture so the FILE holds the literal escape TEXT (backslash-u-001b = ESC,
  # backslash-u-0007 = BEL); jq/python DECODE these into cwd, giving the strip
  # real control bytes to remove. We assert the exact resulting cwd so the strip
  # is genuinely exercised, not merely "no control char present".
  cc="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-cwd.jsonl"
  printf '{"aiTitle":"safe","cwd":"/Volumes/demo/a%su001b[2Jb%su0007c"}\n' '\' '\' > "$cc"
  # Sanity: the fixture on disk holds the literal escape TEXT, not raw bytes.
  grep -q 'a\\u001b\[2Jb\\u0007c' "$cc"
  # jq and python decode the escapes -> each control char becomes one space:
  #   /Volumes/demo/a [2Jb c
  for shadow in '' 'jq'; do
    run env CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_SHADOW="$shadow" bash -c '
      command() { for s in $CSP_SHADOW; do if [ "$1" = "-v" ] && [ "$2" = "$s" ]; then return 1; fi; done; builtin command "$@"; }
      . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
      csp_session_meta "'"$cc"'"'
    cwd="$(csp_field "$output" 2)"
    case "$cwd" in *$'\033'*|*$'\007'*|*$'\t'*) bad=1 ;; *) bad=0 ;; esac
    [ "$bad" = "0" ]
    [ "$cwd" = "/Volumes/demo/a [2Jb c" ]
  done
  # awk path: it sees the literal escape TEXT (no real control byte), so the
  # field is control-char-free either way -- the guard still holds.
  run env CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_SHADOW="jq python3" bash -c '
    command() { for s in $CSP_SHADOW; do if [ "$1" = "-v" ] && [ "$2" = "$s" ]; then return 1; fi; done; builtin command "$@"; }
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
    csp_session_meta "'"$cc"'"'
  cwd="$(csp_field "$output" 2)"
  case "$cwd" in *$'\033'*|*$'\007'*|*$'\t'*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
}

@test "meta: a cwd of ONLY control chars becomes '?' on every parser (not a blank)" {
  # After stripping, an all-control cwd would be only spaces; it must collapse to
  # the "?" placeholder, and all three parsers must agree (the awk path extracts
  # from such a line where jq/python reject it as invalid JSON).
  co="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-cwdonly.jsonl"
  printf '{"aiTitle":"t","cwd":"%b"}\n' '\007\007' > "$co"
  for shadow in '' 'jq' 'jq python3'; do
    run env CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_SHADOW="$shadow" bash -c '
      command() { for s in $CSP_SHADOW; do if [ "$1" = "-v" ] && [ "$2" = "$s" ]; then return 1; fi; done; builtin command "$@"; }
      . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
      csp_session_meta "'"$co"'"'
    [ "$(csp_field "$output" 2)" = "?" ]
  done
}

@test "meta: an empty aiTitle falls back to lastPrompt on ALL parsers (jq // trap)" {
  # Regression: jq's // treats a present-but-empty "aiTitle":"" as a value, so
  # jq showed (untitled) while python/awk correctly used the prompt. Now all
  # three select only a non-empty string.
  et="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-empty.jsonl"
  printf '%s\n' '{"aiTitle":"","lastPrompt":"real prompt here","cwd":"/Volumes/demo/alpha"}' > "$et"
  for shadow in '' 'jq' 'jq python3'; do
    run env CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_SHADOW="$shadow" bash -c '
      command() { for s in $CSP_SHADOW; do if [ "$1" = "-v" ] && [ "$2" = "$s" ]; then return 1; fi; done; builtin command "$@"; }
      . '"$BATS_TEST_DIRNAME"'/../lib/core.sh; . '"$BATS_TEST_DIRNAME"'/../lib/sessions.sh
      csp_session_meta "'"$et"'"'
    [ "$(csp_field "$output" 1)" = "real prompt here" ]
  done
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

@test "state: write is atomic — leaves no temp file and lands the value whole" {
  csp_write_state "sess-atomic" "working"
  # The final state file holds exactly the value...
  run csp_read_state "sess-atomic"
  [ "$output" = "working" ]
  # ...and no ".$$.tmp" scratch file is left behind in the state dir (which would
  # mean the rename didn't happen or a temp leaked).
  run bash -c 'ls "'"$CSP_STATE_DIR"'"/*.tmp 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "0" ]
}

@test "state: concurrent writers leave a valid value and no temp residue" {
  # Two background processes hammer the same state file with alternating
  # working/waiting writes. This is the concurrency the atomic write is FOR.
  # We can't deterministically catch a torn read mid-flight on a fast local FS
  # (that timing is exactly why the guarantee must be structural, not tested by
  # luck), so we assert what IS deterministic after the storm: the file survives,
  # holds exactly one valid token (the rename never leaves it empty or partial),
  # and NO .tmp scratch file leaked from any writer. With a truncate-in-place
  # write the temp-residue check still passes, but the structural guarantee — a
  # reader only ever sees the pre- or post-rename inode — is what this documents.
  id="sess-race"
  csp_write_state "$id" "working"
  f="$(csp_state_file "$id")"
  ( i=0; while [ "$i" -lt 200 ]; do csp_write_state "$id" working; i=$((i+1)); done ) &
  w1=$!
  ( i=0; while [ "$i" -lt 200 ]; do csp_write_state "$id" waiting; i=$((i+1)); done ) &
  w2=$!
  wait "$w1" "$w2" 2>/dev/null || true
  # Survives as exactly one valid token (never emptied by a mid-write truncate).
  v=$(cat "$f" 2>/dev/null)
  case "$v" in working|waiting) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # csp_read_state agrees, and no temp file leaked from the concurrent writers.
  run csp_read_state "$id"; case "$output" in working|waiting) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  run bash -c 'ls "'"$CSP_STATE_DIR"'"/*.tmp 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "0" ]
}

@test "state: reading an unknown session yields nothing (not an error)" {
  run csp_read_state "never-seen"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# csp_delete_would_hit_live lives in bin/ (wiring), so source that with the main
# loop suppressed. Its signals: a live --resume process, an open tmux window
# tagged @csp_sid=<id> on our socket, hook state "working", OR — the fail-closed
# backstop — a transcript FILE whose mtime is within CSP_LIVE_MTIME_WINDOW (a
# live Claude keeps writing its .jsonl). A lone "waiting" hook state with NO live
# window/process AND a stale/absent file stays deletable (the crashed/idle case).
# We pass CSP_TMUX_SOCKET so the tmux query targets a throwaway socket, never the
# user's real tmux. $2 (optional) is the transcript file passed to the guard.
_delete_guard() {  # $1 = id, $2 = file (optional)
  CSP_SOURCED_FOR_TEST=1 CSP_STATE_DIR="$CSP_STATE_DIR" \
  CSP_TMUX_SOCKET="${CSP_TMUX_SOCKET:-csp-dg-$$}" CSP_TMUX_SESSION="${CSP_TMUX_SESSION:-csptest}" \
  bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
    csp_delete_would_hit_live "'"$1"'" "'"${2:-}"'" && echo LIVE || echo NOTLIVE'
}

@test "delete-guard: a session the hook marks 'working' is treated as live" {
  mkdir -p "$CSP_STATE_DIR"
  csp_write_state "sess-working" "working"
  [ "$(_delete_guard sess-working)" = "LIVE" ]
}

@test "delete-guard: a lone 'waiting'/idle session (no window, no process) stays deletable" {
  mkdir -p "$CSP_STATE_DIR"
  csp_write_state "sess-waiting" "waiting"
  [ "$(_delete_guard sess-waiting)" = "NOTLIVE" ]
  [ "$(_delete_guard sess-never-seen)" = "NOTLIVE" ]
}

@test "delete-guard: a bare session with an OPEN tmux window is live even when 'waiting'" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  mkdir -p "$CSP_STATE_DIR"
  # A bare 'n' session: hook state is "waiting" (Claude stopped for input) and no
  # --resume process exists — but its tmux window is open, so it IS in use and
  # must NOT be deletable. This is the High finding the review caught.
  export CSP_TMUX_SOCKET="csp-dgwin-$$" CSP_TMUX_SESSION="csptest"
  csp_write_state "sess-barewin" "waiting"
  tmux -L "$CSP_TMUX_SOCKET" new-session -d -s "$CSP_TMUX_SESSION" -n work "sleep 30"
  tmux -L "$CSP_TMUX_SOCKET" set-option -w -t "=$CSP_TMUX_SESSION:work" '@csp_sid' "sess-barewin"
  result="$(_delete_guard sess-barewin)"
  tmux -L "$CSP_TMUX_SOCKET" kill-server 2>/dev/null || true
  [ "$result" = "LIVE" ]
}

# Helper: write a 3-line residency record (socket, server_pid, pane) for ID.
_write_residency() {  # $1=id $2=socket $3=server_pid $4=pane
  mkdir -p "$CSP_STATE_DIR/resident"
  printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$CSP_STATE_DIR/resident/$1"
}

@test "delete-guard: a live RESIDENCY (session in an UNOWNED tmux pane) blocks deletion, idle-independent" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # The round-2 High finding: a bare session running in a legacy/foreign server we
  # can't tag, idle at a prompt (stale mtime), with no @csp_sid tag and no
  # "working" state. The hook records (socket,pid,pane) in our state dir; the guard
  # must block while that pane is open — regardless of ownership or idle time.
  sock="csp-resid-$$"
  tmux -L "$sock" new-session -d -s foreign -n w "sleep 30"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  spid=$(tmux -L "$sock" display-message -p '#{pid}')
  pane=$(tmux -L "$sock" display-message -p -t "=foreign:w" '#{pane_id}')
  _write_residency sess-resid "$sockpath" "$spid" "$pane"   # NO tag, NO state, stale/no file
  result="$(_delete_guard sess-resid)"
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$result" = "LIVE" ]
}

@test "delete-guard: a LEGACY 2-line residency record (socket,pane) still probes the right pane" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # An upgrading user may have a round-2 (socket, pane) record on disk (no pid
  # line). csp_read_residency must treat the non-numeric 2nd line as the pane, so
  # the guard still checks that exact pane rather than over-blocking or misreading.
  sock="csp-legacy-$$"
  tmux -L "$sock" new-session -d -s foreign -n w "sleep 30"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  pane=$(tmux -L "$sock" display-message -p -t "=foreign:w" '#{pane_id}')
  mkdir -p "$CSP_STATE_DIR/resident"
  printf '%s\n%s\n' "$sockpath" "$pane" > "$CSP_STATE_DIR/resident/sess-legacy"   # 2-line
  live="$(_delete_guard sess-legacy)"
  # Now close that pane (kill the server) → the legacy record must become deletable.
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$live" = "LIVE" ]
}

@test "delete-guard: a residency whose pane has CLOSED (same instance) self-clears and becomes deletable" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Server is up, SAME recorded instance (pid matches), but the recorded pane is
  # gone (session ended) → positive dead signal: clear the record, allow deletion.
  sock="csp-resid2-$$"
  tmux -L "$sock" new-session -d -s foreign -n w "sleep 30"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  spid=$(tmux -L "$sock" display-message -p '#{pid}')
  _write_residency sess-gone "$sockpath" "$spid" "%9999"    # a pane id that doesn't exist
  result="$(_delete_guard sess-gone)"
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$result" = "NOTLIVE" ]
  [ ! -f "$CSP_STATE_DIR/resident/sess-gone" ]              # cleaned up by the probe
}

@test "delete-guard: a residency with NO pane id but a live same-instance server still blocks" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # If the hook had $TMUX but no $TMUX_PANE, only socket+pid are recorded. As long
  # as that exact server is reachable, the session is treated as live — we must NOT
  # fall back to the mtime-only gap the High finding exploited.
  sock="csp-resid3-$$"
  tmux -L "$sock" new-session -d -s foreign -n w "sleep 30"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  spid=$(tmux -L "$sock" display-message -p '#{pid}')
  _write_residency sess-nopane "$sockpath" "$spid" ""       # socket+pid, empty pane
  result="$(_delete_guard sess-nopane)"
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$result" = "LIVE" ]
}

@test "delete-guard: a probe FAILURE with the recorded server pid still ALIVE keeps blocking (fail closed)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # The round-3 High finding: a transient list-panes failure must NOT be read as
  # "server dead". We simulate an unreachable socket (bogus path) but record a pid
  # that IS alive (this bats process, $$). Since we can't prove that instance is
  # dead, the guard must stay LIVE and keep the record.
  _write_residency sess-transient "$BATS_TEST_TMPDIR/unreachable.sock" "$$" "%0"
  [ "$(_delete_guard sess-transient)" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-transient" ]           # record preserved
}

@test "delete-guard: a residency whose recorded server pid is GONE self-clears and becomes deletable" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Positive proof of death: socket unreachable AND the recorded server pid is not
  # a live process. Only then may we clear and allow deletion.
  # Pick a pid that is (almost certainly) not running.
  deadpid=999999
  while kill -0 "$deadpid" 2>/dev/null; do deadpid=$(( deadpid + 1 )); done
  _write_residency sess-deadpid "$BATS_TEST_TMPDIR/unreachable.sock" "$deadpid" "%0"
  [ "$(_delete_guard sess-deadpid)" = "NOTLIVE" ]
  [ ! -f "$CSP_STATE_DIR/resident/sess-deadpid" ]
}

@test "delete-guard: socket REUSE by a different instance (recorded pid alive) keeps blocking" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # The round-3 socket-reuse High finding: the recorded socket path is now held by
  # a DIFFERENT tmux server (different pid) whose panes don't include ours. If our
  # recorded instance pid is still alive, the guard must NOT clear — the session
  # may still be running in the old instance we simply can't enumerate here.
  sock="csp-reuse-$$"
  tmux -L "$sock" new-session -d -s other -n w "sleep 30"   # the REPLACEMENT server
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  # Record a DIFFERENT (alive) instance pid — use $$ (this process) as a stand-in
  # for the old server still running elsewhere — and a pane the replacement lacks.
  _write_residency sess-reuse "$sockpath" "$$" "%12345"
  result="$(_delete_guard sess-reuse)"
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$result" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-reuse" ]
}

# A pid that is (almost certainly) not a live process — used so the ONLY thing
# that can keep a residency "live" is the output-validation guard, not the
# recorded-pid-still-alive branch. Isolates the round-4 High fix.
_dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do p=$(( p + 1 )); done
  printf '%s' "$p"
}

@test "residency-live: a SUCCESSFUL probe with EMPTY output stays LIVE (round-4 High, fail closed)" {
  # The round-4 High: `tmux list-panes` exiting 0 with empty output is NOT positive
  # proof the pane is gone. We record a DEAD pid so the only thing that can keep it
  # live is the output-validation guard (not the pid-alive reuse branch). A fake
  # tmux exits 0 and prints nothing; the guard must keep the record and stay live.
  mkdir -p "$CSP_STATE_DIR/resident"
  _write_residency sess-emptyout "/tmp/whatever.sock" "$(_dead_pid)" "%0"
  fakebin="$BATS_TEST_TMPDIR/emptyout-bin"; mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$fakebin/tmux"; chmod +x "$fakebin/tmux"
  run env CSP_STATE_DIR="$CSP_STATE_DIR" PATH="$fakebin:$PATH" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-emptyout && echo LIVE || echo DEAD'
  [ "$output" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-emptyout" ]   # record preserved
}

@test "residency-live: a SUCCESSFUL probe with MALFORMED output stays LIVE (fail closed)" {
  # Exit 0 but the lines don't match "<pid> <%pane>" (e.g. an error banner on
  # stdout). Recorded pid is DEAD, so only the validation guard can keep it live.
  mkdir -p "$CSP_STATE_DIR/resident"
  _write_residency sess-garbled "/tmp/whatever.sock" "$(_dead_pid)" "%0"
  fakebin="$BATS_TEST_TMPDIR/garbled-bin"; mkdir -p "$fakebin"
  printf '#!/bin/sh\necho "protocol version mismatch"\nexit 0\n' > "$fakebin/tmux"; chmod +x "$fakebin/tmux"
  run env CSP_STATE_DIR="$CSP_STATE_DIR" PATH="$fakebin:$PATH" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-garbled && echo LIVE || echo DEAD'
  [ "$output" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-garbled" ]
}

@test "residency-live: MIXED valid+malformed output stays LIVE (round-5: don't trust a partial listing)" {
  # Round-5 High: the guard used to grep OUT malformed lines and treat the rest as
  # a complete listing — so a dropped/garbled line for our pane could clear a live
  # record. A listing with ANY malformed line is untrustworthy → stay live. Here
  # the recorded pane is %7; output has a good "4242 %0" and a truncated "4242 %".
  mkdir -p "$CSP_STATE_DIR/resident"
  # Record pid MATCHES the listing (4242) so the ONLY thing that can keep it live
  # is the whole-output validation (else the different-instance branch would).
  _write_residency sess-mixed "/tmp/whatever.sock" "4242" "%7"
  fakebin="$BATS_TEST_TMPDIR/mixed-bin"; mkdir -p "$fakebin"
  # A good line "4242 %0" and a truncated line "4242 %" (malformed). Use echo to
  # avoid printf's % handling.
  { echo '#!/bin/sh'; echo 'echo "4242 %0"'; echo 'echo "4242 %"'; echo 'exit 0'; } > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  run env CSP_STATE_DIR="$CSP_STATE_DIR" PATH="$fakebin:$PATH" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-mixed && echo LIVE || echo DEAD'
  [ "$output" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-mixed" ]
}

@test "residency-live: INCONSISTENT pids across lines stays LIVE (round-5: untrustworthy listing)" {
  # A valid-looking listing whose lines report DIFFERENT server pids is inconsistent
  # (a real server's panes all share its pid) → untrustworthy → stay live. Recorded
  # pane %7 is absent, but we must not clear on an inconsistent listing.
  mkdir -p "$CSP_STATE_DIR/resident"
  # Record pid 4242 matches the FIRST line; the listing mixes 4242 and 5555.
  _write_residency sess-incpid "/tmp/whatever.sock" "4242" "%7"
  fakebin="$BATS_TEST_TMPDIR/incpid-bin"; mkdir -p "$fakebin"
  { echo '#!/bin/sh'; echo 'echo "4242 %0"'; echo 'echo "5555 %1"'; echo 'exit 0'; } > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  run env CSP_STATE_DIR="$CSP_STATE_DIR" PATH="$fakebin:$PATH" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-incpid && echo LIVE || echo DEAD'
  [ "$output" = "LIVE" ]
  [ -f "$CSP_STATE_DIR/resident/sess-incpid" ]
}

@test "residency-live: a VALID same-instance listing WITHOUT our pane clears (positive proof)" {
  # The complement: a well-formed listing from the SAME server pid that genuinely
  # lacks our pane is positive proof → clear + dead.
  mkdir -p "$CSP_STATE_DIR/resident"
  _write_residency sess-realgone "/tmp/whatever.sock" "4242" "%7"
  fakebin="$BATS_TEST_TMPDIR/realgone-bin"; mkdir -p "$fakebin"
  # Same pid (4242), but only pane %0 exists — %7 is gone.
  { echo '#!/bin/sh'; echo 'echo "4242 %0"'; echo 'exit 0'; } > "$fakebin/tmux"; chmod +x "$fakebin/tmux"
  run env CSP_STATE_DIR="$CSP_STATE_DIR" PATH="$fakebin:$PATH" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-realgone && echo LIVE || echo DEAD'
  [ "$output" = "DEAD" ]
  [ ! -f "$CSP_STATE_DIR/resident/sess-realgone" ]  # cleared on positive proof
}

@test "residency-live: a LEGACY pidless record stays LIVE but is NOT bound to the current socket owner" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Round-5 High: a legacy (socket, pane) record has no pid. We must NOT derive its
  # instance from whoever currently owns the (reusable) socket — that could be a
  # REPLACEMENT server, and binding to it could later prove a false death. So a
  # legacy record on a reachable server stays LIVE (fail closed) and is left
  # pidless until a fresh hook writes a full 3-field record.
  sock="csp-upg-$$"
  tmux -L "$sock" new-session -d -s foreign -n w "sleep 30"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  pane=$(tmux -L "$sock" display-message -p -t "=foreign:w" '#{pane_id}')
  mkdir -p "$CSP_STATE_DIR/resident"
  printf '%s\n%s\n' "$sockpath" "$pane" > "$CSP_STATE_DIR/resident/sess-upg"   # 2-line legacy
  run env CSP_STATE_DIR="$CSP_STATE_DIR" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_residency_is_live sess-upg && echo LIVE || echo DEAD'
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$output" = "LIVE" ]
  # The record was NOT rewritten to bind a pid from the reusable socket owner.
  line2=$(sed -n '2p' "$CSP_STATE_DIR/resident/sess-upg")
  [ -z "$line2" ] || [ "$line2" = "$pane" ]   # still 2-line (pane on line 2), no injected pid
}

@test "residency: csp_clear_residency_if_matches requires socket AND server-pid (AND pane) to match" {
  mkdir -p "$CSP_STATE_DIR/resident"
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  _write_residency sess-cond "/tmp/A.sock" "111" "%1"
  # Wrong socket → NOT cleared.
  csp_clear_residency_if_matches sess-cond "/tmp/B.sock" "111" "%1"
  [ -f "$CSP_STATE_DIR/resident/sess-cond" ]
  # Right socket, WRONG server pid (reuse of socket+pane after restart) → NOT cleared.
  csp_clear_residency_if_matches sess-cond "/tmp/A.sock" "222" "%1"
  [ -f "$CSP_STATE_DIR/resident/sess-cond" ]
  # Right socket + right pid, wrong pane → NOT cleared.
  csp_clear_residency_if_matches sess-cond "/tmp/A.sock" "111" "%9"
  [ -f "$CSP_STATE_DIR/resident/sess-cond" ]
  # Missing event pid → can't prove ownership → NOT cleared.
  csp_clear_residency_if_matches sess-cond "/tmp/A.sock" "" "%1"
  [ -f "$CSP_STATE_DIR/resident/sess-cond" ]
  # Full match (socket + pid + pane) → cleared.
  csp_clear_residency_if_matches sess-cond "/tmp/A.sock" "111" "%1"
  [ ! -f "$CSP_STATE_DIR/resident/sess-cond" ]
}

@test "residency: a non-matching claim RESTORES the record intact (atomic claim/restore)" {
  mkdir -p "$CSP_STATE_DIR/resident"
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  _write_residency sess-restore "/tmp/A.sock" "111" "%1"
  before=$(cat "$CSP_STATE_DIR/resident/sess-restore")
  # A mismatching end (different pid) must leave the record byte-for-byte intact —
  # the claim is renamed away, found not-ours, then renamed back.
  csp_clear_residency_if_matches sess-restore "/tmp/A.sock" "999" "%1"
  [ -f "$CSP_STATE_DIR/resident/sess-restore" ]
  after=$(cat "$CSP_STATE_DIR/resident/sess-restore")
  [ "$before" = "$after" ]
  # And no stray .claim.* file leaked in the resident dir.
  run bash -c "ls '$CSP_STATE_DIR/resident/'.claim.* 2>/dev/null | grep -c ."
  [ "$output" = "0" ]
}

@test "residency: if a NEWER record appears at the slot during a non-matching claim, it is NOT clobbered" {
  mkdir -p "$CSP_STATE_DIR/resident"
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  # Simulate the race: stub `mv` so that AFTER the claim-rename moves the old record
  # away, a newer record is written to the original slot before the restore. The
  # matcher must discard its stale claim rather than overwrite the newer record.
  # We emulate by pre-seeding: the matcher renames f->claim (old), then finds not
  # ours; we make a newer record appear at f before the restore check by wrapping.
  _write_residency sess-race "/tmp/OLD.sock" "111" "%1"
  # Run the matcher in a subshell where, right after it claims (file disappears),
  # a concurrent writer drops a NEW record. We approximate with a background writer
  # that waits for the slot to be empty then writes the new record.
  f="$CSP_STATE_DIR/resident/sess-race"
  ( while [ -e "$f" ]; do :; done; printf '%s\n%s\n%s\n' "/tmp/NEW.sock" "222" "%5" > "$f" ) &
  writer=$!
  csp_clear_residency_if_matches sess-race "/tmp/OLD.sock" "999" "%1"   # mismatch (pid 999)
  wait "$writer" 2>/dev/null || true
  # The NEWER record must be intact (not overwritten by the restored OLD one).
  [ -f "$f" ]
  line1=$(sed -n '1p' "$f")
  [ "$line1" = "/tmp/NEW.sock" ]
}

@test "state: csp_clear_state_unless_working keeps a 'working' value but clears others" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  # "working" is a delete-blocking signal that may belong to a newer instance →
  # must NOT be cleared. "waiting" (or any non-working) is cosmetic → cleared.
  csp_write_state keepw working
  csp_clear_state_unless_working keepw
  run csp_read_state keepw
  [ "$output" = "working" ]                         # preserved
  csp_write_state dropw waiting
  csp_clear_state_unless_working dropw
  run csp_read_state dropw
  [ -z "$output" ]                                  # cleared
}

@test "state: csp_clear_state_unless_working does not clobber a NEWER record written during the claim" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  # Race: an old SessionEnd clears a non-working state, but a newer instance writes
  # "working" to the slot meanwhile. The atomic claim/restore (ln, no-clobber) must
  # leave the newer "working" intact. We approximate: seed "waiting", and have a
  # background writer drop "working" the instant the slot goes empty.
  f=$(csp_state_file racew)
  csp_write_state racew waiting
  ( while [ -e "$f" ]; do :; done; printf 'working\n' > "$f" ) &
  writer=$!
  csp_clear_state_unless_working racew
  wait "$writer" 2>/dev/null || true
  # The newer "working" must survive (either our claim saw waiting and dropped it,
  # then the writer created working; or ln refused to clobber it).
  run csp_read_state racew
  [ "$output" = "working" ]
}

@test "residency: csp_record_residency reports failure when the state dir is unwritable" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  # Point the state dir at a path that can't be created (under a regular file).
  blocker="$BATS_TEST_TMPDIR/blocker"; : > "$blocker"
  run env CSP_STATE_DIR="$blocker/state" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_record_residency x /tmp/s.sock 1 %0 && echo OK || echo FAIL'
  [ "$output" = "FAIL" ]
}

@test "state: csp_write_state reports failure when the state dir cannot be created" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  blocker="$BATS_TEST_TMPDIR/wblocker"; : > "$blocker"
  run env CSP_STATE_DIR="$blocker/state" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_write_state x working && echo OK || echo FAIL'
  [ "$output" = "FAIL" ]
}

@test "state-store: csp_state_store_healthy is true for a normal dir, false when unwritable" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  run env CSP_STATE_DIR="$BATS_TEST_TMPDIR/healthy" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_state_store_healthy && echo HEALTHY || echo SICK'
  [ "$output" = "HEALTHY" ]
  blocker="$BATS_TEST_TMPDIR/sblocker"; : > "$blocker"
  run env CSP_STATE_DIR="$blocker/state" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"
    csp_state_store_healthy && echo HEALTHY || echo SICK'
  [ "$output" = "SICK" ]
}

@test "delete-guard: an UNHEALTHY state store makes the guard fail closed (block)" {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"; . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
  # If the state store is unwritable/unreadable, the hook may have SILENTLY failed
  # to record a live session, so a clean "no signal" is untrustworthy → block. No
  # process, no window, no file: with a HEALTHY store this id would be deletable;
  # with a sick store it must be treated as live.
  blocker="$BATS_TEST_TMPDIR/dgblocker"; : > "$blocker"
  result=$(CSP_SOURCED_FOR_TEST=1 CSP_STATE_DIR="$blocker/state" \
    CSP_TMUX_SOCKET="csp-dgh-$$" CSP_TMUX_SESSION="csptest" bash -c '
      . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
      csp_delete_would_hit_live "no-signal-id" && echo LIVE || echo NOTLIVE')
  [ "$result" = "LIVE" ]
}

@test "delete-guard: a FRESH transcript (recent mtime) is live even with no tmux/process (fail closed)" {
  # The topology-independent backstop for the High data-loss finding: a live bare
  # session that the picker's tmux ownership no longer recognises still keeps
  # writing its .jsonl. A file touched now is within CSP_LIVE_MTIME_WINDOW, so the
  # guard must refuse deletion even though there's NO tmux window and NO process.
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  fresh="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-fresh.jsonl"
  printf '%s\n' '{"type":"user"}' > "$fresh"   # just written → recent mtime
  [ "$(_delete_guard id-fresh "$fresh")" = "LIVE" ]
}

@test "delete-guard: a STALE transcript (old mtime) with no window/process is deletable" {
  # The other side of the backstop: a crashed/finished session's .jsonl goes
  # stale. With an mtime well past CSP_LIVE_MTIME_WINDOW and no live signal, it
  # must remain deletable — the backstop must not pin every old session forever.
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  stale="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-stale.jsonl"
  printf '%s\n' '{"type":"user"}' > "$stale"
  touch -t 200001010000 "$stale"   # year 2000 → far outside the live window
  [ "$(_delete_guard id-stale "$stale")" = "NOTLIVE" ]
}

@test "delete-guard: mtime backstop is skipped when no file is passed (back-compat)" {
  # Callers that don't pass a file (older call sites / --list style) must not be
  # broken: with no file arg and no other live signal, the guard says deletable.
  [ "$(_delete_guard id-nofile)" = "NOTLIVE" ]
}

@test "delete-guard: an existing file whose mtime is UNREADABLE (0) fails closed (live)" {
  # csp_file_mtime coerces an unreadable/non-numeric stat to 0. An existing file we
  # can't stat is the textbook "can't prove it's dead" case, so the guard must
  # block (treat as live) rather than let now-0 look like a huge, deletable age.
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  f="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-nomtime.jsonl"
  printf '%s\n' '{"type":"user"}' > "$f"
  # Force the mtime read to 0 by stubbing csp_file_mtime in the sourced context.
  result=$(CSP_SOURCED_FOR_TEST=1 CSP_STATE_DIR="$CSP_STATE_DIR" \
    CSP_TMUX_SOCKET="csp-nm-$$" CSP_TMUX_SESSION="csptest" bash -c '
      . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
      csp_file_mtime() { echo 0; }   # simulate an unreadable stat
      csp_delete_would_hit_live "id-nomtime" "'"$f"'" && echo LIVE || echo NOTLIVE')
  [ "$result" = "LIVE" ]
}

@test "delete-action: the confirm prompt includes the project + age discriminator (not just the title)" {
  # Many sessions share a title (or are "(untitled)"); the confirm must include the
  # project path + age so the user can tell WHICH session they're deleting even if
  # the cursor slid onto a same-titled neighbour. We capture the prompt string.
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  keep="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-desc.jsonl"
  printf '%s\n' '{"type":"ai-title","aiTitle":"(untitled)"}' > "$keep"
  run env CSP_SOURCED_FOR_TEST=1 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_STATE_DIR="$CSP_STATE_DIR" \
       CSP_TTY=/dev/null bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
    csp_count=1; csp_ids=(id-desc); csp_titles=("(untitled)")
    csp_projects=("demo/alpha"); csp_ages=("3d ago")
    csp_files=("'"$keep"'"); csp_view=(0); csp_view_count=1
    # Capture the confirm prompt, then decline (return 1) so nothing is deleted.
    csp_confirm() { printf "PROMPT=[%s]\n" "$1"; return 1; }
    csp_restore_terminal() { :; }; csp_enter_raw_mode() { :; }
    csp_pause_notice() { :; }; csp_load_sessions() { :; }; csp_tty_print() { :; }; csp_tty_readline() { :; }
    csp_delete_would_hit_live() { return 1; }   # not live → reach the confirm
    csp_action_delete 0'
  case "$output" in
    *'(untitled)'*'demo/alpha'*'3d ago'*) ok=1 ;;
    *) ok=0 ;;
  esac
  [ "$ok" = "1" ] || { echo "prompt was: $output"; false; }
}

@test "delete-action: a session that goes live DURING the confirm prompt is not unlinked" {
  # Action-level: the second (post-confirmation) liveness check must stop the
  # unlink even if the first check passed. We drive csp_action_delete with stubs:
  # csp_confirm always says yes; csp_delete_would_hit_live is idle on the FIRST
  # call and live on the SECOND (simulating a resume during the prompt); and we
  # assert csp_delete_session_file is never reached (the file survives).
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  keep="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-keep.jsonl"
  printf '%s\n' '{"type":"ai-title","aiTitle":"keep me"}' > "$keep"
  run env CSP_SOURCED_FOR_TEST=1 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_STATE_DIR="$CSP_STATE_DIR" \
       CSP_TTY=/dev/null bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
    # Minimal model with one session at index 0.
    csp_count=1; csp_ids=(id-keep); csp_titles=("keep me")
    csp_files=("'"$keep"'"); csp_view=(0); csp_view_count=1
    # Stubs: confirm yes; terminal ops no-op; reload no-op; pause no-op.
    csp_confirm() { return 0; }
    csp_restore_terminal() { :; }; csp_enter_raw_mode() { :; }
    csp_pause_notice() { :; }; csp_load_sessions() { :; }; csp_tty_print() { :; }; csp_tty_readline() { :; }
    # First liveness check idle, second (post-confirm) live.
    __n=0
    csp_delete_would_hit_live() { __n=$(( __n + 1 )); [ "$__n" -ge 2 ]; }
    csp_action_delete 0
    [ -f "'"$keep"'" ] && echo SURVIVED || echo DELETED'
  [ "$output" = "SURVIVED" ]
}

@test "delete-action: a REAL tagged tmux window blocks the unlink (no stubbed guard)" {
  # Integration counterpart to the stubbed test above: exercise the ACTUAL
  # csp_delete_would_hit_live wiring (via csp_tmux_window_for_sid) — a real tmux
  # window tagged @csp_sid=<id> must stop csp_action_delete from unlinking, so a
  # broken session-id/window wiring would be caught here.
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  mkdir -p "$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha"
  keep="$CSP_CLAUDE_DIR/projects/-Volumes-demo-alpha/id-live.jsonl"
  printf '%s\n' '{"type":"ai-title","aiTitle":"live one"}' > "$keep"
  sock="csp-delwin-$$"; sess="csptest"
  tmux -L "$sock" new-session -d -s "$sess" -n work "sleep 30"
  tmux -L "$sock" set-option -w -t "=$sess:work" '@csp_sid' "id-live"
  run env CSP_SOURCED_FOR_TEST=1 CSP_CLAUDE_DIR="$CSP_CLAUDE_DIR" CSP_STATE_DIR="$CSP_STATE_DIR" \
       CSP_TMUX_SOCKET="$sock" CSP_TMUX_SESSION="$sess" CSP_TTY=/dev/null bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../bin/claude-session-picker"
    csp_count=1; csp_ids=(id-live); csp_titles=("live one")
    csp_files=("'"$keep"'"); csp_view=(0); csp_view_count=1
    # Confirm yes (so only the REAL liveness guard can stop it); terminal no-ops.
    csp_confirm() { return 0; }
    csp_restore_terminal() { :; }; csp_enter_raw_mode() { :; }
    csp_pause_notice() { :; }; csp_load_sessions() { :; }; csp_tty_print() { :; }; csp_tty_readline() { :; }
    csp_action_delete 0
    [ -f "'"$keep"'" ] && echo SURVIVED || echo DELETED'
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ "$output" = "SURVIVED" ]
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
