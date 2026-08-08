#!/usr/bin/env bats
# =============================================================================
# keys.bats — tests for the picker's keypress decoding (csp_read_key).
#
# csp_read_key turns raw terminal input — single characters and the multi-byte
# escape sequences that arrow keys send — into the small vocabulary the main
# loop understands (j/k/g/G/q/_/…). We feed it bytes on stdin and assert the
# decoded key, so this covers the arrow-key handling without a real terminal.
#
# The picker script guards its main loop behind CSP_SOURCED_FOR_TEST so we can
# source it here and call csp_read_key directly.
#
# Run with:  bats test/keys.bats
# =============================================================================

# Helper: decode one input string through csp_read_key in a fresh shell that
# sources the picker (main loop suppressed via CSP_SOURCED_FOR_TEST).
decode() {
  CSP_SOURCED_FOR_TEST=1 bash -c \
    ". '$BATS_TEST_DIRNAME/../bin/claude-session-picker'; printf '$1' | csp_read_key"
}

@test "key: a plain letter passes through unchanged" {
  run decode 'j'
  [ "$output" = "j" ]
}

@test "key: up arrow decodes to k" {
  # ESC [ A  is the up-arrow sequence.
  run decode '\033[A'
  [ "$output" = "k" ]
}

@test "key: down arrow decodes to j" {
  run decode '\033[B'
  [ "$output" = "j" ]
}

@test "key: right arrow is a harmless no-op (does NOT quit)" {
  run decode '\033[C'
  [ "$output" = "_" ]
  [ "$output" != "q" ]
}

@test "key: left arrow is a harmless no-op (does NOT quit)" {
  run decode '\033[D'
  [ "$output" = "_" ]
  [ "$output" != "q" ]
}

@test "key: an unknown escape sequence is ignored, not treated as quit" {
  # e.g. Home key: ESC [ H — we should ignore rather than quit.
  run decode '\033[H'
  [ "$output" = "_" ]
}
