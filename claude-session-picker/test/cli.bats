#!/usr/bin/env bats
# =============================================================================
# cli.bats — tests for the informational command-line flags.
#
# --version and --help must work with NO terminal, NO claude on PATH, and NO
# tmux — they're the things a user or a bug report reaches for first. They must
# print to stdout and exit 0 without touching the terminal or launching anything.
#
# Run with:  bats test/cli.bats
# =============================================================================

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin/claude-session-picker"
}

@test "cli: --version prints the tool name and a version, exits 0" {
  run "$BIN" --version
  [ "$status" -eq 0 ]
  case "$output" in claude-session-picker\ [0-9]*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: -V is an alias for --version" {
  run "$BIN" -V
  [ "$status" -eq 0 ]
  case "$output" in claude-session-picker\ [0-9]*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --help prints usage and exits 0" {
  run "$BIN" --help
  [ "$status" -eq 0 ]
  case "$output" in *Usage:*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --version works even with claude NOT on PATH (no dependency)" {
  # A bare environment must still report the version.
  run env PATH=/usr/bin:/bin "$BIN" --version
  [ "$status" -eq 0 ]
  case "$output" in claude-session-picker\ [0-9]*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --doctor prints a report and exits 0 when claude is present" {
  # A fake claude on PATH so the essential check passes regardless of the host.
  fake="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fake"
  printf '#!/bin/sh\n:\n' > "$fake/claude"; chmod +x "$fake/claude"
  run env PATH="$fake:/usr/bin:/bin" NO_COLOR=1 "$BIN" --doctor
  [ "$status" -eq 0 ]
  case "$output" in *"doctor"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  case "$output" in *"claude command found"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --doctor exits non-zero and warns when claude is missing" {
  run env PATH=/usr/bin:/bin NO_COLOR=1 "$BIN" --doctor
  [ "$status" -ne 0 ]
  case "$output" in *"claude command NOT on PATH"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --doctor reports the JSON parser and is read-only (no state dir created)" {
  fake="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fake"
  printf '#!/bin/sh\n:\n' > "$fake/claude"; chmod +x "$fake/claude"
  state="$BATS_TEST_TMPDIR/state-should-not-appear"
  run env PATH="$fake:/usr/bin:/bin" NO_COLOR=1 CSP_STATE_DIR="$state" "$BIN" --doctor
  [ "$status" -eq 0 ]
  case "$output" in *"JSON parser:"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # Doctor must not write anything: the state dir it merely REPORTS on stays absent.
  [ ! -e "$state" ]
}

@test "cli: --help mentions --doctor and --list" {
  run "$BIN" --help
  [ "$status" -eq 0 ]
  case "$output" in *"--doctor"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  case "$output" in *"--list"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "cli: --list prints one TSV row per session (id, title, project, age)" {
  # A fake store with one session, and a fake claude so the PATH gate passes.
  fake="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fake"
  printf '#!/bin/sh\n:\n' > "$fake/claude"; chmod +x "$fake/claude"
  cdir="$BATS_TEST_TMPDIR/claude"
  proj="$cdir/projects/-Volumes-demo-alpha"; mkdir -p "$proj"
  {
    printf '%s\n' '{"type":"ai-title","aiTitle":"my session title"}'
    printf '%s\n' '{"type":"user","cwd":"/Volumes/demo/alpha"}'
  } > "$proj/id-one.jsonl"
  run env PATH="$fake:/usr/bin:/bin" NO_COLOR=1 CSP_CLAUDE_DIR="$cdir" "$BIN" --list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  # Exactly 4 tab-separated fields, and the id/title/project are what we wrote.
  nf=$(printf '%s' "${lines[0]}" | awk -F'\t' '{print NF}')
  [ "$nf" -eq 4 ]
  f1=$(printf '%s' "${lines[0]}" | cut -f1); [ "$f1" = "id-one" ]
  f2=$(printf '%s' "${lines[0]}" | cut -f2); [ "$f2" = "my session title" ]
  f3=$(printf '%s' "${lines[0]}" | cut -f3); [ "$f3" = "demo/alpha" ]
}

@test "cli: --list on an empty store prints nothing and exits 0" {
  fake="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fake"
  printf '#!/bin/sh\n:\n' > "$fake/claude"; chmod +x "$fake/claude"
  cdir="$BATS_TEST_TMPDIR/empty-claude"; mkdir -p "$cdir/projects"
  run env PATH="$fake:/usr/bin:/bin" NO_COLOR=1 CSP_CLAUDE_DIR="$cdir" "$BIN" --list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli: version matches the top CHANGELOG.md entry" {
  # Keep --version and the changelog in lock-step.
  v=$("$BIN" --version | awk '{print $2}')
  head=$(grep -m1 '^## ' "$BATS_TEST_DIRNAME/../CHANGELOG.md" | sed 's/^## //')
  [ "$v" = "$head" ]
}
