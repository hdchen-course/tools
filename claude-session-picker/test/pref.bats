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

@test "pref: saving twice OVERWRITES (not appends) so load isn't stale" {
  csp_save_backend_pref "tmux"
  csp_save_backend_pref "hub"
  run csp_load_backend_pref
  [ "$output" = "hub" ]
  # The file must contain exactly one line, not two.
  run wc -l < "$CSP_PREF_FILE"
  [ "$(printf '%s' "$output" | tr -d ' ')" = "1" ]
}

@test "pref: a CRLF (hand-edited on Windows) value still loads" {
  mkdir -p "$(dirname "$CSP_PREF_FILE")"
  printf 'tmux\r\n' > "$CSP_PREF_FILE"
  run csp_load_backend_pref
  [ "$output" = "tmux" ]
}

@test "pref: a trailing space is tolerated" {
  mkdir -p "$(dirname "$CSP_PREF_FILE")"
  printf 'tmux \n' > "$CSP_PREF_FILE"
  run csp_load_backend_pref
  [ "$output" = "tmux" ]
}

@test "pref: an unreadable pref file prints nothing to stderr and yields empty" {
  mkdir -p "$(dirname "$CSP_PREF_FILE")"
  printf 'tmux\n' > "$CSP_PREF_FILE"
  chmod 000 "$CSP_PREF_FILE"
  # Capture stderr: it must be silent (the redirection-failure leak bug).
  run bash -c "CSP_PREF_FILE='$CSP_PREF_FILE' CSP_SOURCED_FOR_TEST=1 . '$BATS_TEST_DIRNAME/../bin/claude-session-picker'; csp_load_backend_pref 2>&1 1>/dev/null"
  chmod 644 "$CSP_PREF_FILE"
  [ -z "$output" ]        # no 'Permission denied' leaked
}

@test "precedence: CSP_BACKEND=hub overrides a saved tmux preference" {
  csp_save_backend_pref "tmux"
  # Re-source with the env var set; the startup block should pick hub.
  run bash -c "CSP_BACKEND=hub CSP_PREF_FILE='$CSP_PREF_FILE' CSP_SOURCED_FOR_TEST=1 bash -c '. \"$BATS_TEST_DIRNAME/../bin/claude-session-picker\"; printf %s \"\$CSP_BACKEND_CHOICE\"'"
  [ "$output" = "hub" ]
}

@test "toggle: refusing tmux (not available) must NOT persist a tmux preference" {
  # Simulate a box without tmux. The refusal path prints a prompt and waits for
  # Enter on the terminal — point CSP_TTY at /dev/null so it can't block the
  # test (this is exactly why the tty access is abstracted). Terminal-mode calls
  # are stubbed since there's no real terminal here.
  rm -f "$CSP_PREF_FILE"
  export CSP_TTY=/dev/null
  CSP_ACTIVE_BACKEND="hub"
  csp_tmux_available() { return 1; }
  csp_restore_terminal() { :; }
  csp_enter_raw_mode() { :; }
  csp_toggle_backend > /dev/null 2>&1
  [ "$CSP_ACTIVE_BACKEND" = "hub" ]          # stayed hub, did not switch
  [ ! -f "$CSP_PREF_FILE" ] || {             # and did not write a tmux pref
    run csp_load_backend_pref; [ "$output" != "tmux" ]; }
}

@test "toggle: switching to hub from tmux persists hub without touching the tty" {
  export CSP_TTY=/dev/null
  CSP_ACTIVE_BACKEND="tmux"
  csp_restore_terminal() { :; }
  csp_enter_raw_mode() { :; }
  csp_toggle_backend
  [ "$CSP_ACTIVE_BACKEND" = "hub" ]
  run csp_load_backend_pref
  [ "$output" = "hub" ]
}
