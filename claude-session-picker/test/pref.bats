#!/usr/bin/env bats
# =============================================================================
# pref.bats — tests for the persisted backend preference (the 't' toggle).
#
# The picker remembers whether you last chose hub or tmux mode in a small file,
# so the choice sticks between runs. These tests exercise the load/save helpers
# and the precedence logic, by sourcing the picker script in test mode (its main
# loop and traps are suppressed via CSP_SOURCED_FOR_TEST) and pointing the
# preference file at a throwaway path.
#
# Run with:  bats test/pref.bats
# =============================================================================

setup() {
  export CSP_PREF_FILE="$BATS_TEST_TMPDIR/pref/backend"
  export CSP_SOURCED_FOR_TEST=1
  # Sourcing defines the helpers without starting the TUI.
  . "$BATS_TEST_DIRNAME/../bin/claude-session-picker"
}

@test "pref: save then load round-trips a valid value" {
  csp_save_backend_pref "tmux"
  run csp_load_backend_pref
  [ "$output" = "tmux" ]
}

@test "pref: save creates the directory if missing" {
  [ ! -d "$(dirname "$CSP_PREF_FILE")" ]
  csp_save_backend_pref "hub"
  [ -f "$CSP_PREF_FILE" ]
  run csp_load_backend_pref
  [ "$output" = "hub" ]
}

@test "pref: loading with no file yields nothing (not an error)" {
  run csp_load_backend_pref
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pref: an invalid saved value is ignored on load" {
  mkdir -p "$(dirname "$CSP_PREF_FILE")"
  printf 'garbage\n' > "$CSP_PREF_FILE"
  run csp_load_backend_pref
  [ -z "$output" ]
}

@test "pref: a saved 'tmux' selects tmux when tmux is available" {
  csp_save_backend_pref "tmux"
  run csp_choose_backend 1 0 "$(csp_load_backend_pref)"
  [ "$output" = "tmux" ]
}

@test "pref: a saved 'tmux' still falls back to hub when tmux is absent" {
  csp_save_backend_pref "tmux"
  run csp_choose_backend 0 0 "$(csp_load_backend_pref)"
  [ "$output" = "hub" ]
}
