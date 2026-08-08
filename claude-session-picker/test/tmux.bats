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
