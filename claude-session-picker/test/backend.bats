#!/usr/bin/env bats
# =============================================================================
# backend.bats — tests for lib/backend.sh.
#
# We test the safe parts without launching Claude or tmux:
#   - csp_shell_quote correctly quotes tricky strings so a path/id can never
#     break out of its argument when handed to tmux.
#   - The hub backend actually runs the command we give it and RETURNS control
#     (that "return to the menu" behaviour is the whole point of hub mode). We
#     verify this by pointing `claude` at a fake stub on PATH.
#
# Run with:  bats test/backend.bats
# =============================================================================

setup() {
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
  . "$BATS_TEST_DIRNAME/../lib/backend.sh"
}

# --- csp_shell_quote ---------------------------------------------------------

@test "quote: a plain path is wrapped in single quotes" {
  run csp_shell_quote "/Volumes/work/tools"
  [ "$output" = "'/Volumes/work/tools'" ]
}

@test "quote: an embedded single quote is escaped, not left open" {
  # A name like  it's mine  must not break the surrounding quotes.
  run csp_shell_quote "it's mine"
  [ "$output" = "'it'\\''s mine'" ]
}

# --- csp_tmux_sanitize_label -------------------------------------------------

@test "label: a normal project path is kept" {
  run csp_tmux_sanitize_label "EnglishTraining/tools"
  [ "$output" = "EnglishTraining/tools" ]
}

@test "label: newlines and odd characters are replaced" {
  run csp_tmux_sanitize_label "$(printf 'a\nb c!')"
  case "$output" in *$'\n'*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]        # no newline survives (tmux would reject it)
}

@test "label: an empty or all-stripped label falls back to 'session'" {
  run csp_tmux_sanitize_label ""
  [ "$output" = "session" ]
  run csp_tmux_sanitize_label "$(printf '\n\n')"
  [ "$output" = "session" ]
}

@test "label: a leading dash is removed so tmux can't read it as a flag" {
  run csp_tmux_sanitize_label "-badflag"
  case "$output" in -*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
}

@test "quote: a shell-injection attempt is neutralised" {
  # If someone crafted a project path with a command in it, quoting must keep it
  # a literal string, so `eval`-ing our composed command can't run `rm`.
  quoted=$(csp_shell_quote '; rm -rf /')
  run bash -c "printf '%s' $quoted"
  [ "$output" = "; rm -rf /" ]
}

# --- hub backend returns control ---------------------------------------------

@test "hub: runs the resume command and returns to the caller" {
  # Fake `claude` writes proof-of-run to a file and exits, so csp_hub_open must
  # come back (unlike the tmux backend which hands off).
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/claude" <<EOF
#!/bin/sh
echo "resumed \$2" > "$BATS_TEST_TMPDIR/proof"
EOF
  chmod +x "$stub/claude"

  PATH="$stub:$PATH" csp_hub_open "session-xyz" ""
  # If we got here, control returned. And the stub ran with our id.
  run cat "$BATS_TEST_TMPDIR/proof"
  [ "$output" = "resumed session-xyz" ]
}

@test "hub: 'new' starts claude without --resume" {
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/claude" <<EOF
#!/bin/sh
echo "args=[\$*]" > "$BATS_TEST_TMPDIR/proof2"
EOF
  chmod +x "$stub/claude"

  PATH="$stub:$PATH" csp_hub_open "new" ""
  run cat "$BATS_TEST_TMPDIR/proof2"
  [ "$output" = "args=[]" ]
}

# --- csp_tmux_version / csp_tmux_supported (version gate) --------------------
# The concurrent backend needs tmux >= CSP_TMUX_MIN (features like `if-shell -F`,
# `#{==:}`/`#{&&:}` format conditionals, `exit-empty`, `#{pid}`, `#{socket_path}`
# that older tmux — e.g. the 1.8 on some Linux hosts — lacks). These tests pin the
# parse-and-compare logic by stubbing what `tmux -V` reports.

# csp_tmux_version reads `command tmux -V`, which bypasses shell functions — so we
# stub tmux with a real executable on PATH (same technique the hub tests use).
_stub_tmux_version() {   # $1 = what `tmux -V` should print
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  printf '#!/bin/sh\n[ "$1" = -V ] && echo "%s"\n' "$1" > "$stub/tmux"
  chmod +x "$stub/tmux"
  printf '%s' "$stub"
}

@test "version: parses a plain 'tmux X.Y' string" {
  stub=$(_stub_tmux_version "tmux 3.4")
  run env PATH="$stub:$PATH" bash -c '. "'"$BATS_TEST_DIRNAME"'/../lib/backend.sh"; csp_tmux_version'
  [ "$output" = "3.4" ]
}

@test "version: strips a 'next-' build prefix" {
  stub=$(_stub_tmux_version "tmux next-3.5")
  run env PATH="$stub:$PATH" bash -c '. "'"$BATS_TEST_DIRNAME"'/../lib/backend.sh"; csp_tmux_version'
  [ "$output" = "3.5" ]
}

@test "supported: tmux 1.8 is rejected (too old for the concurrent backend)" {
  csp_tmux_available() { return 0; }
  csp_tmux_version() { printf '1.8'; }
  run csp_tmux_supported
  [ "$status" -ne 0 ]
}

@test "supported: tmux just below the minor floor is rejected" {
  csp_tmux_available() { return 0; }
  csp_tmux_version() { printf '2.3'; }
  run csp_tmux_supported
  [ "$status" -ne 0 ]
}

@test "supported: a patch/pre-release suffix on a too-old base is still rejected (2.3.1, 2.3-rc1)" {
  # Regression: minor was parsed with `tr -cd '0-9'`, which spliced non-adjacent
  # digits — "2.3.1" → minor "31", "2.3-rc1" → "31" — both wrongly clearing the
  # 2.4 floor. Only the CONTIGUOUS numeric prefix after the first dot counts, so
  # both are minor 3 (base 2.3) and MUST be rejected.
  csp_tmux_available() { return 0; }
  local v
  for v in 2.3.1 2.3-rc1; do
    eval "csp_tmux_version() { printf '%s' '$v'; }"
    run csp_tmux_supported
    [ "$status" -ne 0 ] || { echo "expected $v rejected (base 2.3 < 2.4)"; return 1; }
  done
}

@test "supported: a patch suffix on a new-enough base is still accepted (2.4.1, 2.5-rc1)" {
  # Mirror of the above: the contiguous-prefix parse must not over-reject either.
  csp_tmux_available() { return 0; }
  local v
  for v in 2.4.1 2.5-rc1 3.4.2; do
    eval "csp_tmux_version() { printf '%s' '$v'; }"
    run csp_tmux_supported
    [ "$status" -eq 0 ] || { echo "expected $v accepted"; return 1; }
  done
}

@test "supported: accepts a pre-captured version argument WITHOUT forking tmux" {
  # The startup path probes `tmux -V` once and passes the string in, so
  # csp_tmux_supported must not re-fork. Stub csp_tmux_version to FAIL loudly if
  # it's called — then confirm the argument form ignores it entirely.
  csp_tmux_available() { return 0; }
  csp_tmux_version() { echo "csp_tmux_version was called" >&2; return 1; }
  run csp_tmux_supported "1.8"
  [ "$status" -ne 0 ]                       # 1.8 rejected via the passed value
  [ -z "$output" ]                          # version helper never ran
  run csp_tmux_supported "3.4"
  [ "$status" -eq 0 ]                       # 3.4 accepted via the passed value
  [ -z "$output" ]
}

@test "supported: exactly the minimum version is accepted" {
  csp_tmux_available() { return 0; }
  csp_tmux_version() { printf '%s' "$CSP_TMUX_MIN"; }
  run csp_tmux_supported
  [ "$status" -eq 0 ]
}

@test "supported: a newer major/minor and a lettered patch are accepted" {
  csp_tmux_available() { return 0; }
  # These are POST-strip forms (csp_tmux_version already removes the "next-"/
  # "openbsd-" prefixes — see the dedicated "strips a 'next-' build prefix"
  # test), so the compare path is genuinely exercised here rather than the
  # unparseable-major fallback. 3.5 must be accepted via major 3 > 2, not because
  # a stray prefix left the major empty.
  for v in 2.5 3.0 3.2a 3.5; do
    eval "csp_tmux_version() { printf '%s' '$v'; }"
    run csp_tmux_supported
    [ "$status" -eq 0 ] || { echo "expected $v supported"; return 1; }
  done
}

@test "supported: an unparseable version (dev build) is assumed supported, not blocked" {
  csp_tmux_available() { return 0; }
  csp_tmux_version() { printf 'master'; }
  run csp_tmux_supported
  [ "$status" -eq 0 ]
}

@test "supported: tmux missing entirely is not supported" {
  csp_tmux_available() { return 1; }
  run csp_tmux_supported
  [ "$status" -ne 0 ]
}
