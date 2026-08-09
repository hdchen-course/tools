#!/usr/bin/env bats
# =============================================================================
# install.bats — tests for install.sh and uninstall.sh argument handling.
#
# These run the real scripts against a throwaway --prefix directory, so they
# never touch your actual ~/.local/bin. They focus on the safety-relevant
# behaviours: a missing --prefix argument must fail cleanly (not with a cryptic
# `set -u` error), uninstall must only remove a symlink that points into this
# repo, and a real (non-symlink) file at the target must never be clobbered.
#
# Run with:  bats test/install.bats
# =============================================================================

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  PREFIX="$BATS_TEST_TMPDIR/bin"
}

# --- --prefix argument guard ---------------------------

@test "install: --prefix with no argument fails cleanly, not with a set -u error" {
  run "$ROOT/install.sh" --prefix
  [ "$status" -ne 0 ]
  # The message is our friendly one, and NOT bash's "unbound variable".
  case "$output" in
    *"--prefix needs a directory argument"*) ok=1 ;;
    *) ok=0 ;;
  esac
  [ "$ok" = "1" ]
  case "$output" in *"unbound variable"*) leaked=1 ;; *) leaked=0 ;; esac
  [ "$leaked" = "0" ]
}

@test "uninstall: --prefix with no argument fails cleanly, not with a set -u error" {
  run "$ROOT/uninstall.sh" --prefix
  [ "$status" -ne 0 ]
  case "$output" in
    *"--prefix needs a directory argument"*) ok=1 ;;
    *) ok=0 ;;
  esac
  [ "$ok" = "1" ]
  case "$output" in *"unbound variable"*) leaked=1 ;; *) leaked=0 ;; esac
  [ "$leaked" = "0" ]
}

# --- install then uninstall round-trip ---------------------------------------

@test "install: creates a symlink that points back into this repo" {
  run "$ROOT/install.sh" --prefix "$PREFIX"
  [ "$status" -eq 0 ]
  [ -L "$PREFIX/claude-session-picker" ]
  target="$(readlink "$PREFIX/claude-session-picker")"
  case "$target" in */bin/claude-session-picker) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "uninstall: removes the symlink it created" {
  "$ROOT/install.sh" --prefix "$PREFIX" >/dev/null 2>&1
  run "$ROOT/uninstall.sh" --prefix "$PREFIX"
  [ "$status" -eq 0 ]
  [ ! -e "$PREFIX/claude-session-picker" ]
}

# --- safety: never clobber a real file the user put there --------------------

@test "install: refuses to overwrite a non-symlink even with --force" {
  mkdir -p "$PREFIX"
  printf 'USER OWN FILE\n' > "$PREFIX/claude-session-picker"
  run "$ROOT/install.sh" --prefix "$PREFIX" --force
  [ "$status" -ne 0 ]
  # The user's file must still be there, untouched.
  [ -f "$PREFIX/claude-session-picker" ]
  run cat "$PREFIX/claude-session-picker"
  [ "$output" = "USER OWN FILE" ]
}

@test "uninstall: refuses to remove a symlink that does NOT point into this repo" {
  mkdir -p "$PREFIX"
  ln -s /bin/ls "$PREFIX/claude-session-picker"
  run "$ROOT/uninstall.sh" --prefix "$PREFIX"
  [ "$status" -eq 0 ]
  # The unrelated symlink must survive.
  [ -L "$PREFIX/claude-session-picker" ]
}

# --- Hook-snippet command escaping (shell-quote + JSON-escape) ---------------
# The printed hooks snippet embeds $ROOT (the repo path) in a JSON "command"
# string that Claude Code later runs through a shell. A path with spaces or
# shell metacharacters must stay literal (shell-quoted) AND keep the JSON valid
# (backslash/quote escaped). We source just the helper functions from install.sh
# and assert the produced value for hostile paths.
# Source just the escaping helpers from install.sh into THIS shell, then set
# ROOT directly (no nested-bash interpolation to fight) and call the helper.
_load_hook_helpers() {
  eval "$(sed -n '/^csp_sh_quote()/,/^}/p; /^csp_json_escape()/,/^}/p; /^csp_hook_command()/,/^}/p' "$BATS_TEST_DIRNAME/../install.sh")"
}

@test "install: hook command single-quotes a path with spaces" {
  _load_hook_helpers
  ROOT="/Users/me/my tools"
  out=$(csp_hook_command working)
  [ "$out" = "'/Users/me/my tools/hooks/csp-hook.sh' working" ]
}

@test "install: hook command neutralises shell metacharacters (\$(), quotes)" {
  _load_hook_helpers
  ROOT="/tmp/a\$(touch PWNED)b'c"      # literal: a, $(touch PWNED), b, ', c
  out=$(csp_hook_command working)
  # The $(...) text is present but INERT — it sits inside the single-quoted path,
  # and the embedded single quote is escaped as '\'' then JSON-escaped.
  case "$out" in *'$(touch PWNED)'*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  case "$out" in "'"*) starts_quoted=1 ;; *) starts_quoted=0 ;; esac
  [ "$starts_quoted" = "1" ]
  # And running the command value through a shell must NOT create PWNED.
  rm -f "$BATS_TEST_TMPDIR/PWNED"
  ( cd "$BATS_TEST_TMPDIR" && sh -c ": $out" 2>/dev/null || true )
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "install: hook command keeps JSON valid for a backslash path" {
  _load_hook_helpers
  ROOT='/tmp/a\b'
  out=$(csp_hook_command working)
  case "$out" in *'a\\b'*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "install: hook command produces VALID JSON even for a newline/tab path" {
  # A POSIX path may contain control chars; the command value must still form a
  # parseable JSON string (\n, \t, \u00XX), not a raw control char. We build the
  # FULL {"command":"…"} object and parse it with python (available in CI) — a
  # fragment check would miss an invalid-control-char error.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available to validate JSON"
  _load_hook_helpers
  ROOT="$(printf '/tmp/a\nb\tc')"        # embedded newline + tab
  out=$(csp_hook_command working)
  printf '{"command":"%s"}\n' "$out" > "$BATS_TEST_TMPDIR/h.json"
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["command"])' "$BATS_TEST_TMPDIR/h.json"
  [ "$status" -eq 0 ]                    # parses without JSONDecodeError
  # The decoded command still starts with the single-quoted (inert) path.
  case "$output" in "'/tmp/a"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "install: EVERY control byte 0x01-0x1F escapes to valid, round-tripping JSON" {
  # Guard the generic \u00XX branch (not just \n/\t): for each control byte, build
  # {"command":"…"} and confirm python parses it AND the decoded value contains
  # that exact byte (i.e. we escaped it, didn't drop or mangle it). NUL is skipped
  # — a shell variable / POSIX path cannot contain it.
  command -v python3 >/dev/null 2>&1 || skip "python3 not available to validate JSON"
  _load_hook_helpers
  local b
  for b in $(seq 1 31); do
    # Build ROOT = "/tmp/a<byte>b" with the raw control byte via printf %b octal.
    local oct; oct=$(printf '%03o' "$b")
    ROOT="$(printf "/tmp/a\\${oct}b")"
    out=$(csp_hook_command working)
    printf '{"command":"%s"}\n' "$out" > "$BATS_TEST_TMPDIR/cb.json"
    run python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))          # raises if invalid JSON
want=chr(int(sys.argv[2]))
sys.exit(0 if want in d["command"] else 1)' "$BATS_TEST_TMPDIR/cb.json" "$b"
    [ "$status" -eq 0 ] || { echo "byte 0x$(printf '%02x' "$b") failed JSON round-trip"; false; }
  done
}
