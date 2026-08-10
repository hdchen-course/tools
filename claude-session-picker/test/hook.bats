#!/usr/bin/env bats
# =============================================================================
# hook.bats — tests for hooks/csp-hook.sh (the ●/✳ state-recording hook).
#
# The hook is run by Claude Code with a state argument and the hook JSON on
# stdin; it extracts the session id and writes a tiny state file. These tests
# drive it directly with crafted stdin and a throwaway CSP_STATE_DIR, and assert
# both what it records and — critically — that it stays silent and harmless
# (its stdout on UserPromptSubmit is injected into Claude's context, so any
# stray output would pollute the conversation).
#
# Run with:  bats test/hook.bats
# =============================================================================

setup() {
  HOOK="$BATS_TEST_DIRNAME/../hooks/csp-hook.sh"
  export CSP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  # For reading state back to assert on it.
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
  . "$BATS_TEST_DIRNAME/../lib/sessions.sh"
}

@test "hook: records working for a valid session id" {
  printf '{"session_id":"abc-123"}' | "$HOOK" working
  run csp_read_state "abc-123"
  [ "$output" = "working" ]
}

@test "hook: records waiting for a valid session id" {
  printf '{"session_id":"abc-123"}' | "$HOOK" waiting
  run csp_read_state "abc-123"
  [ "$output" = "waiting" ]
}

# How many state files exist (0 if the dir was never even created).
csp_state_count() {
  [ -d "$CSP_STATE_DIR" ] || { printf '0'; return; }
  find "$CSP_STATE_DIR" -type f 2>/dev/null | grep -c . || printf '0'
}

@test "hook: a null session_id writes nothing (no 'None' file)" {
  printf '{"session_id":null}' | "$HOOK" working
  [ "$(csp_state_count)" = "0" ]
}

@test "hook: a non-string session_id (object/number) writes nothing" {
  printf '{"session_id":{"a":1}}' | "$HOOK" working
  printf '{"session_id":12345}'   | "$HOOK" working
  [ "$(csp_state_count)" = "0" ]
}

@test "hook: a missing session_id writes nothing and exits 0" {
  run bash -c "printf '{\"foo\":\"bar\"}' | '$HOOK' working"
  [ "$status" -eq 0 ]
  [ ! -d "$CSP_STATE_DIR" ] || [ -z "$(ls "$CSP_STATE_DIR")" ]
}

@test "hook: an invalid state argument is ignored" {
  run bash -c "printf '{\"session_id\":\"x\"}' | '$HOOK' garbage"
  [ "$status" -eq 0 ]
  [ ! -d "$CSP_STATE_DIR" ] || [ -z "$(ls "$CSP_STATE_DIR")" ]
}

@test "hook: empty and non-JSON stdin are handled, exit 0, no output" {
  run bash -c "printf '' | '$HOOK' working"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c "printf 'not json at all' | '$HOOK' waiting"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "hook: prints NOTHING to stdout or stderr on success (context safety)" {
  # UserPromptSubmit stdout is injected into Claude's context — must be empty.
  run bash -c "printf '{\"session_id\":\"abc-123\"}' | '$HOOK' working 2>&1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook: a session_id with path-traversal can't escape the state dir" {
  printf '{"session_id":"../../etc/evil"}' | "$HOOK" working
  # Nothing created outside the state dir...
  [ ! -e "$BATS_TEST_TMPDIR/etc/evil" ]
  # ...and because the id has slashes it's rejected outright, so no file at all.
  [ ! -d "$CSP_STATE_DIR" ] || [ -z "$(ls "$CSP_STATE_DIR")" ]
}

@test "hook: prefers the top-level session_id over a nested one" {
  printf '{"tool_input":{"session_id":"NESTED-wrong"},"session_id":"real-id-42"}' | "$HOOK" working
  run csp_read_state "real-id-42"
  [ "$output" = "working" ]
  run csp_read_state "NESTED-wrong"
  [ -z "$output" ]
}

@test "hook: a huge stdin is bounded and finishes promptly" {
  # 2MB of junk with a valid id at the very front; must record it and not hang.
  { printf '{"session_id":"front-id","junk":"'; head -c 2000000 /dev/zero | tr '\0' 'x'; printf '"}'; } \
    | "$HOOK" working
  run csp_read_state "front-id"
  [ "$output" = "working" ]
}

@test "hook: inside OUR tmux, tags the current window with @csp_sid (dedup of bare sessions)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  sock="csp-hooktag-$$"; sess="claude-sessions"
  sd="$BATS_TEST_TMPDIR/hooktag-state"; mkdir -p "$sd"
  # The window runs an interactive shell (so $TMUX is set) and we export
  # CSP_TMUX_SOCKET + CSP_TMUX_SESSION + CSP_STATE_DIR to THIS server/session. We
  # seed the per-instance ownership token in the owner file AND stamp the SAME
  # value as @csp_owner (as csp_tmux_enter's fresh path + configure_home would),
  # so csp_inside_tmux recognises it as OUR tmux (right socket, right session,
  # token matches) and the hook tags the window. A flag file marks completion.
  # The owner file is keyed on the RESOLVED socket PATH, so create the server
  # first, then write the token to the path-keyed file (same tr-sanitize the
  # helper uses).
  tok="csp-hooktag-token-$$"
  tmux -L "$sock" new-session -d -s "$sess" -n w
  tmux -L "$sock" set-option -g @csp_owner "$tok"
  # The owner file is keyed on an injective HEX of the resolved socket path (same
  # encoding csp_tmux_owner_file uses). Use $() to strip the trailing newline.
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  ownerkey=$(printf '%s' "$sockpath" | od -An -tx1 | tr -d ' \n')
  printf '%s\n' "$tok" > "$sd/tmux-owner.$ownerkey"
  sleep 0.5
  tmux -L "$sock" send-keys -t "=$sess:w" \
    "export CSP_TMUX_SOCKET='$sock' CSP_TMUX_SESSION='$sess' CSP_STATE_DIR='$sd'; printf '{\"session_id\":\"tag-me-77\"}' | '$HOOK' working; echo done > '$sd/flag'" Enter
  local i; for i in $(seq 1 40); do [ -f "$sd/flag" ] && break; sleep 0.25; done
  run tmux -L "$sock" show-options -w -t "=$sess:w" @csp_sid
  tmux -L "$sock" kill-server 2>/dev/null || true
  case "$output" in *tag-me-77*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "hook: inside an UNRELATED tmux (same socket name, NO marker), does NOT tag (no pollution)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # The strongest pollution case the review caught: the user's own tmux happens
  # to use a socket whose NAME equals our CSP_TMUX_SOCKET, but it's a different
  # server for which no per-instance token was ever established. csp_inside_tmux
  # must still say "not ours" (no owner file / no matching token), so the hook
  # leaves the window's options alone.
  sock="csp-foreign-$$"; sess="claude-sessions"
  sd="$BATS_TEST_TMPDIR/foreign-state"; mkdir -p "$sd"
  # Same socket name AND same session name as ours, but NO owner file exists for
  # this socket under CSP_STATE_DIR (so csp_tmux_owner_token is empty) — a foreign
  # server that only coincides in naming. An empty token can never match, so it
  # must be judged not ours even if it wore a menu window.
  tmux -L "$sock" new-session -d -s "$sess" -n w      # no owner token, no menu window
  sleep 0.5
  tmux -L "$sock" send-keys -t "=$sess:w" \
    "export CSP_TMUX_SOCKET='$sock' CSP_TMUX_SESSION='$sess' CSP_STATE_DIR='$sd'; printf '{\"session_id\":\"nope-99\"}' | '$HOOK' working; echo done > '$sd/flag'" Enter
  local i; for i in $(seq 1 40); do [ -f "$sd/flag" ] && break; sleep 0.25; done
  # State IS still recorded (that part is socket-independent) — read from the
  # same dir the hook wrote to.
  run env CSP_STATE_DIR="$sd" bash -c '. "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"; csp_read_state nope-99'
  [ "$output" = "working" ]
  # ...but the foreign window carries NO @csp_sid option.
  run tmux -L "$sock" show-options -w -t "=$sess:w" @csp_sid
  case "$output" in *nope-99*) polluted=1 ;; *) polluted=0 ;; esac
  [ "$polluted" = "0" ]
  # AND — the High-finding fix — the hook DID record an ownership-independent
  # residency marker in OUR OWN state dir (from its read-only $TMUX/$TMUX_PANE),
  # so the delete guard can protect this live-but-untaggable session. The recorded
  # socket path must be this server's.
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  run env CSP_STATE_DIR="$sd" bash -c '. "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/sessions.sh"; csp_read_residency nope-99'
  tmux -L "$sock" kill-server 2>/dev/null || true
  [ -n "$output" ]
  case "$output" in *"$sockpath"*) rec_ok=1 ;; *) rec_ok=0 ;; esac
  [ "$rec_ok" = "1" ]
}

@test "hook: inside OUR own tmux, does NOT leave a residency record (tag covers it)" {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  # Case (a): our own server. The @csp_sid tag protects the session, so no
  # residency record should linger — and if a stale one existed it's cleared.
  sock="csp-ownres-$$"; sess="claude-sessions"
  sd="$BATS_TEST_TMPDIR/ownres-state"; mkdir -p "$sd/resident"
  tok="csp-ownres-token-$$"
  tmux -L "$sock" new-session -d -s "$sess" -n w
  tmux -L "$sock" set-option -g @csp_owner "$tok"
  sockpath=$(tmux -L "$sock" display-message -p '#{socket_path}')
  ownerkey=$(printf '%s' "$sockpath" | od -An -tx1 | tr -d ' \n')
  printf '%s\n' "$tok" > "$sd/tmux-owner.$ownerkey"
  # Pre-plant a stale residency record for this id to prove the hook clears it.
  printf '%s\n%s\n' "$sockpath" "%99" > "$sd/resident/own-tag-1"
  sleep 0.5
  tmux -L "$sock" send-keys -t "=$sess:w" \
    "export CSP_TMUX_SOCKET='$sock' CSP_TMUX_SESSION='$sess' CSP_STATE_DIR='$sd'; printf '{\"session_id\":\"own-tag-1\"}' | '$HOOK' working; echo done > '$sd/flag'" Enter
  local i; for i in $(seq 1 40); do [ -f "$sd/flag" ] && break; sleep 0.25; done
  run tmux -L "$sock" show-options -w -t "=$sess:w" @csp_sid
  tmux -L "$sock" kill-server 2>/dev/null || true
  case "$output" in *own-tag-1*) tagged=1 ;; *) tagged=0 ;; esac
  [ "$tagged" = "1" ]                       # window WAS tagged (our server)
  [ ! -f "$sd/resident/own-tag-1" ]         # and the stale residency was cleared
}
