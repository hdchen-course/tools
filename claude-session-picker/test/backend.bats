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
