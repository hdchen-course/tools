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

@test "cli: version matches the top CHANGELOG.md entry" {
  # Keep --version and the changelog in lock-step.
  v=$("$BIN" --version | awk '{print $2}')
  head=$(grep -m1 '^## ' "$BATS_TEST_DIRNAME/../CHANGELOG.md" | sed 's/^## //')
  [ "$v" = "$head" ]
}
