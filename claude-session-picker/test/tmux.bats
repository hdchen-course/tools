#!/usr/bin/env bats
# =============================================================================
# tmux.bats — tests for the tmux backend against a REAL tmux on a throwaway
# socket. These were added because the tmux "resident picker" UX shipped with
# zero coverage and a UX review found several config bugs (window numbering,
# per-window status format, config leaking onto the user's own tmux). Each test
# creates an isolated server (our own CSP_TMUX_SOCKET), asserts behaviour, and
# kills it in teardown. The whole suite skips if tmux isn't installed.
#
# Run with:  bats test/tmux.bats
# =============================================================================

setup() {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
  . "$BATS_TEST_DIRNAME/../lib/backend.sh"
  # Unique names so parallel/rerun test invocations never collide, and so we
  # NEVER touch the user's real tmux server.
  export CSP_TMUX_SOCKET="csp-test-$$-${BATS_TEST_NUMBER:-0}"
  export CSP_TMUX_SESSION="csptest"
  # A fake claude on PATH so opening a session never launches the real one.
  FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
  printf '#!/bin/sh\nsleep 60\n' > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
  PATH="$FAKEBIN:$PATH"
}

teardown() {
  command -v tmux >/dev/null 2>&1 || return 0
  command tmux -L "$CSP_TMUX_SOCKET" kill-server 2>/dev/null || true
}

# Helper: create the holding session (window 0 = menu) the way csp_tmux_enter
# would, then configure it. We use a plain sleep for window 0 so we don't need
# an interactive picker in these tests.
make_home() {
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux_configure_home
}

@test "configure: forces base-index 0 and renumber-windows on (globally, our socket)" {
  make_home
  [ "$(csp_tmux show-options -g base-index)" = "base-index 0" ]
  [ "$(csp_tmux show-options -g renumber-windows)" = "renumber-windows on" ]
}

@test "configure: enables mouse so the scroll wheel scrolls the pane (regression)" {
  # Without `mouse on`, tmux translates the wheel into arrow keys — scrolling a
  # resumed session just walks its input history instead of the pane. This is
  # the bug report: "scrolling brings up previously typed input".
  make_home
  [ "$(csp_tmux show-options -g mouse)" = "mouse on" ]
}

@test "open: sessions accumulate as windows; the menu stays window 0" {
  make_home
  csp_tmux_open id-a /tmp alpha
  csp_tmux_open id-b /tmp beta
  run csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}'
  # Expect: 0:menu 1:alpha 2:beta
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "0:menu" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "1:alpha" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "2:beta" ]
}

@test "open: resuming the SAME session twice reuses its window (no duplicate)" {
  # Resuming one transcript twice would run two Claude processes over the same
  # conversation. The second Enter must switch to the existing window, not open
  # a new one. Windows are tagged with @csp_sid; the second open finds the tag.
  make_home
  csp_tmux_open id-a /tmp alpha
  csp_tmux_open id-b /tmp beta
  before=$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" | grep -c .)
  # Re-open id-a: should NOT add a window.
  csp_tmux_open id-a /tmp alpha-again
  after=$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" | grep -c .)
  [ "$before" = "$after" ]
  # The session's ACTIVE window is now the original id-a window (dedup selected
  # it). Query the active window's tag via the session's active-window flag.
  active_sid=$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" \
    -F '#{window_active} #{@csp_sid}' | awk '$1==1 {print $2}')
  [ "$active_sid" = "id-a" ]
}

@test "open: a brand-new ('new') session always opens fresh, never deduped" {
  make_home
  csp_tmux_open new /tmp one
  csp_tmux_open new /tmp two
  # Two distinct 'new' sessions → two windows besides the menu.
  n=$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" | grep -c .)
  [ "$n" = "3" ]
}

@test "open: a NEW session window inherits our window-status-format (bug D)" {
  make_home
  csp_tmux_open id-a /tmp alpha
  # The just-opened window (index 1) must resolve OUR format, not tmux's default.
  run csp_tmux display-message -p -t "=$CSP_TMUX_SESSION:1" '#{window-status-format}'
  case "$output" in *'window_name'*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "numbering: closing a middle session renumbers so there are no gaps (bug B)" {
  make_home
  csp_tmux_open id-a /tmp alpha
  csp_tmux_open id-b /tmp beta
  csp_tmux_open id-c /tmp gamma            # 0:menu 1:alpha 2:beta 3:gamma
  csp_tmux kill-window -t "=$CSP_TMUX_SESSION:1" 2>/dev/null   # close alpha
  # renumber-windows on => indices collapse to 0,1,2 (no gap at 1)
  run csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}'
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "0 1 2 " ]
}

@test "isolation: our config does NOT leak onto the user's default tmux server (bug C)" {
  make_home
  # Our socket has the custom format...
  run csp_tmux show-options -g window-status-format
  case "$output" in *'window_name'*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # ...the DEFAULT server must NOT (it either isn't running, or shows tmux's own
  # default which contains "#W", never our "window_name" truncation).
  run bash -c 'command tmux show-options -g window-status-format 2>/dev/null || true'
  case "$output" in *'#{=9:window_name}'*) leaked=1 ;; *) leaked=0 ;; esac
  [ "$leaked" = "0" ]
}

@test "status bar fits 80 columns (window list is not fully squeezed out)" {
  # status-left empty + status-right <= 44 leaves room for the window list.
  make_home
  [ "$(csp_tmux show-options -g status-left)" = "status-left ''" ] \
    || [ "$(csp_tmux show-options -g status-left)" = 'status-left ' ]
  right_len=$(csp_tmux show-options -g status-right-length | awk '{print $2}')
  [ "$right_len" -le 46 ]
}

@test "label: CJK project names are preserved, not collapsed to underscores" {
  run csp_tmux_sanitize_label "工作/專案"
  # Must still contain the CJK characters (old tr -c would have made it "_/_").
  case "$output" in *工作*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "label: control chars/newlines are removed and never empty" {
  run csp_tmux_sanitize_label "$(printf 'a\nb\tc')"
  case "$output" in *$'\n'*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
  run csp_tmux_sanitize_label ""
  [ "$output" = "session" ]
}

@test "inside-tmux detection keys off OUR socket, not any tmux" {
  # A TMUX pointing at a DIFFERENT socket must NOT count as inside our tmux
  # (so launching from the user's own tmux still re-execs into ours).
  TMUX="/private/tmp/someone-elses,123,0" run csp_inside_tmux
  [ "$status" -ne 0 ]
  TMUX="/private/tmp/$CSP_TMUX_SOCKET,123,0" run csp_inside_tmux
  [ "$status" -eq 0 ]
}

@test "inside-tmux: a socket whose name merely EXTENDS ours is not a match (bug 6)" {
  # Exact basename compare: 'claude-sessions' must not match 'claude-sessions-x'
  # nor a directory that ends in the name.
  CSP_TMUX_SOCKET="claude-sessions"
  TMUX="/private/tmp/claude-sessions-extra,1,0" run csp_inside_tmux
  [ "$status" -ne 0 ]
  TMUX="/tmp/evil/claude-sessions,1,0" run csp_inside_tmux
  [ "$status" -eq 0 ]     # basename IS exactly our socket → correctly inside
}

@test "label: a project name ending in ';' does not break new-window (bug 3)" {
  # A trailing ';' would make tmux parse the window command as a 2nd tmux command.
  run csp_tmux_sanitize_label "tmp/PWNED;"
  case "$output" in *';'*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
  # And it really opens a window (the failure mode was new-window returning 1).
  make_home
  run csp_tmux_open id-x "/tmp" "tmp/danger;"
  [ "$status" -eq 0 ]
}

@test "enter: reaches the real tmux attach (regression for the exec-a-function blocker)" {
  # Blocker #1 was `exec csp_tmux ...` — exec can't run a shell function, so it
  # died with "exec: csp_tmux: not found" and tmux mode never worked. We can't
  # actually attach without a client, but we CAN assert the failure signature is
  # gone: run csp_tmux_enter with no controlling terminal and confirm it does
  # NOT emit "csp_tmux: not found" / "exec:". The holding session should get
  # created (proving we got past has-session into the create+attach path).
  self="$BATS_TEST_DIRNAME/../bin/claude-session-picker"
  run bash -c "CSP_TMUX_SOCKET='$CSP_TMUX_SOCKET' CSP_TMUX_SESSION='$CSP_TMUX_SESSION' \
    bash -c '. \"$BATS_TEST_DIRNAME/../lib/core.sh\"; . \"$BATS_TEST_DIRNAME/../lib/backend.sh\"; \
    csp_tmux_enter \"$self\"' </dev/null 2>&1"
  case "$output" in
    *"csp_tmux: not found"*|*"exec: csp_tmux"*) bad=1 ;;
    *) bad=0 ;;
  esac
  [ "$bad" = "0" ]
  # And the holding session exists (we reached the create step, not an early
  # function-not-found death).
  csp_tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null
}

@test "session name: ':' and '.' are stripped so tmux targets don't mis-parse (bug 4)" {
  # Re-source with a hostile session name and confirm it's been sanitised.
  CSP_TMUX_SESSION="a:b.c" bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SESSION"' > "$BATS_TEST_TMPDIR/sess"
  run cat "$BATS_TEST_TMPDIR/sess"
  case "$output" in *[:.]*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
  [ "$output" = "abc" ]
}

@test "socket name: '/' ',' '.' are stripped so inside-tmux detection can't break (safety 1)" {
  # A socket containing ',' or '/' would corrupt csp_inside_tmux's basename parse
  # of the TMUX env var and make the picker re-exec into a broken nested attach.
  CSP_TMUX_SOCKET="a,b/c.d" bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SOCKET"' > "$BATS_TEST_TMPDIR/sock"
  run cat "$BATS_TEST_TMPDIR/sock"
  [ "$output" = "abcd" ]
  # And the sanitized socket now round-trips through inside-tmux detection.
  CSP_TMUX_SOCKET=abcd TMUX="/private/tmp/tmux-0/abcd,1,0" bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    csp_inside_tmux'
}

@test "socket name: empty after stripping falls back to the default" {
  CSP_TMUX_SOCKET="..." bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SOCKET"' > "$BATS_TEST_TMPDIR/sock2"
  run cat "$BATS_TEST_TMPDIR/sock2"
  [ "$output" = "claude-sessions" ]
}
