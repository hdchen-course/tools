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
  # Ownership tokens (and the ●/✳ state) live under here. Isolate per test so a
  # token from one never leaks into another, and so we never touch the real one.
  export CSP_STATE_DIR="$BATS_TEST_TMPDIR/state"
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
  # Match csp_tmux_enter's fresh-path ORDER: create the server first (so the owner
  # file — keyed on the resolved socket PATH — lands under this server's key), THEN
  # mint+persist the token, THEN configure_home stamps it as @csp_owner. Minting
  # before the server exists would key the file on the socket NAME and leave
  # configure_home stamping an empty owner, so server_is_ours would reject us.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux_new_owner_token >/dev/null
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

@test "inside-tmux: OUR configured server (carries our per-instance token) is recognised" {
  make_home    # mints the token, creates the holding session, stamps @csp_owner=token
  # $TMUX points at our real socket path; the server's @csp_owner equals our
  # persisted token, so csp_inside_tmux (which queries the ambient server) is true.
  sockpath=$(command tmux -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}' 2>/dev/null)
  [ -n "$sockpath" ]
  TMUX="$sockpath,1,0" run csp_inside_tmux
  [ "$status" -eq 0 ]
}

@test "inside-tmux: a DIFFERENT socket is not ours (re-exec into our own)" {
  make_home
  TMUX="/private/tmp/someone-elses,123,0" run csp_inside_tmux
  [ "$status" -ne 0 ]
}

@test "inside-tmux: a same-BASENAME socket at a different path is NOT ours (path binding)" {
  # The regression the review caught: a user's unrelated tmux whose socket has
  # the same basename ("claude-sessions") but a different path must NOT be
  # treated as ours. csp_inside_tmux binds the ambient socket path to the one our
  # `tmux -L` resolves to, so a mismatching path fails before the token check.
  make_home    # our server exists, at ITS real path, carrying our token
  # A fake TMUX with the same basename but a bogus/foreign path: its socket path
  # won't equal our -L resolved path → not ours.
  TMUX="/tmp/some-other-place/$CSP_TMUX_SOCKET,1,0" run csp_inside_tmux
  [ "$status" -ne 0 ]
}

@test "inside-tmux: a socket whose name merely EXTENDS ours is not a match (bug 6)" {
  # Exact basename compare still holds: 'claude-sessions' must not match
  # 'claude-sessions-extra' (fails the name check before the marker check).
  CSP_TMUX_SOCKET="claude-sessions"
  TMUX="/private/tmp/claude-sessions-extra,1,0" run csp_inside_tmux
  [ "$status" -ne 0 ]
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

@test "ownership: server_is_ours accepts our marked server" {
  make_home    # sets @csp_owner
  run csp_tmux_server_is_ours
  [ "$status" -eq 0 ]
}

@test "ownership: the owner file is keyed on an INJECTIVE hex of the socket PATH (no clobber)" {
  # The review's Finding 2: keying the owner file on socket NAME alone let a second
  # instance on the SAME name but a DIFFERENT TMUX_TMPDIR (a distinct live server at
  # a different socket PATH) clobber the first's token. Follow-up: even keying on
  # the path is unsafe if done with a LOSSY tr -c (distinct paths → same key). The
  # fix uses a byte-wise hex encoding, which is one-to-one. We assert the filename
  # is the hex of the resolved socket path.
  make_home
  path=$(command tmux -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}')
  [ -n "$path" ]
  pathkey=$(printf '%s' "$path" | od -An -tx1 | tr -d ' \n')
  file=$(csp_tmux_owner_file)
  # The file is keyed on the injective hex of the full path (unique per server).
  [ "$file" = "$CSP_STATE_DIR/tmux-owner.$pathkey" ]
}

@test "ownership: the owner-file key is INJECTIVE — collision-prone paths map to distinct files" {
  # Directly guard against the lossy-key regression: /tmp/a/b and /tmp/a_b differ
  # only by a char the old tr -c would fold to '_'. Their hex keys must differ.
  keyAB=$(printf '%s' "/tmp/a/b" | od -An -tx1 | tr -d ' \n')
  keyA_B=$(printf '%s' "/tmp/a_b" | od -An -tx1 | tr -d ' \n')
  [ "$keyAB" != "$keyA_B" ]
  # And csp_tmux_owner_file uses exactly this encoding for a given resolved path.
  fileAB=$(csp_tmux_owner_file "/tmp/a/b")
  fileA_B=$(csp_tmux_owner_file "/tmp/a_b")
  [ "$fileAB" != "$fileA_B" ]
}

@test "ownership: owner-token read refuses a symlink and validates shape (both keyed files)" {
  make_home
  f=$(csp_tmux_owner_file)              # path-keyed file
  nk=$(csp_tmux_owner_file_namekey)     # name-keyed file (dual-key persist writes both)
  # A valid token round-trips (this also guards the bash-3.2 `read -r -n` bug: the
  # reader uses plain `read -r`, so a real token is actually returned, not empty).
  tok=$(csp_tmux_owner_token)
  case "$tok" in csp-*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # Replace BOTH keyed files with SYMLINKs to a secret — the read must refuse to
  # follow either and return nothing (a planted link can't redirect the read).
  printf 'csp-should-not-be-read\n' > "$BATS_TEST_TMPDIR/secret"
  rm -f "$f" "$nk"; ln -s "$BATS_TEST_TMPDIR/secret" "$f"; ln -s "$BATS_TEST_TMPDIR/secret" "$nk"
  [ -z "$(csp_tmux_owner_token)" ]
  # A garbage (wrong-shape) token reads as empty → "not ours", the safe answer.
  rm -f "$f" "$nk"; printf 'totally-not-a-token\n' > "$f"; printf 'totally-not-a-token\n' > "$nk"
  [ -z "$(csp_tmux_owner_token)" ]
  # A well-formed token with an injected disallowed char is also rejected.
  printf 'csp-abc;rm -rf\n' > "$f"; printf 'csp-abc;rm -rf\n' > "$nk"
  [ -z "$(csp_tmux_owner_token)" ]
}

@test "ownership: owner-token round-trips a real token and reads it back exactly" {
  # A valid token written by hand under BOTH keys reads back unchanged.
  make_home
  tok="csp-$(printf 'abc123def456')"
  printf '%s\n' "$tok" > "$(csp_tmux_owner_file)"
  printf '%s\n' "$tok" > "$(csp_tmux_owner_file_namekey)"
  [ "$(csp_tmux_owner_token)" = "$tok" ]
  # A large single-line junk file is rejected by the length cap.
  { printf 'csp-'; head -c 100000 /dev/zero | tr '\0' x; printf '\n'; } > "$(csp_tmux_owner_file)"
  { printf 'csp-'; head -c 100000 /dev/zero | tr '\0' x; printf '\n'; } > "$(csp_tmux_owner_file_namekey)"
  [ -z "$(csp_tmux_owner_token)" ]
}

@test "ownership: owner-token read is BOUNDED — a huge no-newline file returns fast (real function)" {
  # Regression: csp_tmux_read_token_file must use a bounded `read -n`, not plain
  # `read -r` (which slurps the WHOLE first line before the length check, hanging
  # startup on a corrupt owner file). We drive the REAL function against a large
  # regular file (16 MiB, no newline) and require it to return quickly. With the
  # bounded read this is ~instant; with plain `read -r` it reads all 16 MiB (and a
  # 32 MiB file hung >120s in the reviewer's repro) — a watchdog fails it.
  make_home
  f=$(csp_tmux_owner_file)
  rm -f "$f"
  { printf 'csp-'; head -c 16000000 /dev/zero | tr '\0' x; } > "$f"   # 16 MiB, NO newline
  start=$SECONDS
  v=$(csp_tmux_read_token_file "$f")     # THE REAL FUNCTION
  elapsed=$(( SECONDS - start ))
  # Bounded → returns in well under the time an unbounded 16 MiB slurp would take,
  # and the over-length line is rejected (empty), never truncated into a token.
  [ "$elapsed" -lt 5 ] || { echo "read took ${elapsed}s (unbounded regression)"; false; }
  [ -z "$v" ]
}

@test "ownership: new owner token is written 0600 in a 0700 dir (hardening)" {
  make_home
  f=$(csp_tmux_owner_file); d=$(dirname "$f")
  # Perms are best-effort (chmod may be a no-op on odd filesystems), but on a
  # normal box the file is 600 and the dir 700. Accept the hardened perms.
  fmode=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)
  dmode=$(stat -f '%Lp' "$d" 2>/dev/null || stat -c '%a' "$d" 2>/dev/null)
  [ "$fmode" = "600" ]
  [ "$dmode" = "700" ]
}

@test "ownership: server_is_ours REJECTS a legacy/markerless server (no per-instance token)" {
  # A server created by an OLDER build (or any server we didn't mint a token for):
  # our holding session with a menu window, but NO @csp_owner. Under the identity
  # redesign this is NOT adopted — name+window-shape is deliberately insufficient,
  # because a foreign server can wear exactly that shape. We refuse and fall back
  # to hub; data safety still holds via the delete guard's mtime backstop, so a
  # live bare session in such a server is never wrongly deleted.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"   # no configure_home
  [ -z "$(csp_tmux show-options -gv @csp_owner 2>/dev/null)" ]        # confirm markerless
  [ ! -f "$(csp_tmux_owner_file)" ]                                   # and no token established
  run csp_tmux_server_is_ours
  [ "$status" -ne 0 ]
}

@test "reuse-path: configure_home_if_owned mutates ONLY a token-matching server, atomically" {
  # Round-7 High (reuse check->configure race): ownership check and the global
  # set-options now run in ONE tmux invocation gated on @csp_owner==token, so a
  # socket swap can't slip between "it's ours" and the mutations. Verify: our own
  # server (token matches) is configured; a foreign server (no/other token) is left
  # untouched, and the call reports failure so the caller bails to hub.
  # (a) ours → configured.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  tok=$(csp_tmux_new_owner_token)
  csp_tmux set-option -g @csp_owner "$tok"
  run csp_tmux_configure_home_if_owned "$tok"
  [ "$status" -eq 0 ]
  [ "$(csp_tmux show-options -gv mouse)" = "on" ]
  csp_tmux kill-server 2>/dev/null || true
  # (b) foreign (different token) → NOT configured, and NOTHING mutated at all —
  # not even a sentinel option (F1: the old impl pre-wrote @csp_cfgok=0 before the
  # ownership check). Snapshot ALL global options and assert byte-for-byte equal.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux set-option -g @csp_owner "csp-not-ours"
  before_all=$(csp_tmux show-options -g 2>/dev/null | sort)
  run csp_tmux_configure_home_if_owned "$(csp_tmux_gen_owner_token)"
  [ "$status" -ne 0 ]
  after_all=$(csp_tmux show-options -g 2>/dev/null | sort)
  [ "$before_all" = "$after_all" ]
  # And specifically no @csp_cfgok sentinel leaked onto the foreign server.
  [ -z "$(csp_tmux show-options -gv @csp_cfgok 2>/dev/null || true)" ]
}

@test "ownership: server_is_ours REJECTS a server whose @csp_owner is a DIFFERENT token" {
  # The false-positive case the redesign closes: a server that carries SOME
  # @csp_owner value that isn't OUR persisted token (a different picker instance,
  # or a forged marker). The old fixed-string marker would have accepted any
  # server stamped "claude-session-picker"; the per-instance token must not.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux_new_owner_token >/dev/null                          # our token (keyed on live path)
  csp_tmux set-option -g @csp_owner "csp-some-other-instance"  # a foreign/forged token
  run csp_tmux_server_is_ours
  [ "$status" -ne 0 ]
}

@test "ownership: server_is_ours REJECTS a foreign server on the same socket" {
  # A user's unrelated tmux on the exact same -L socket name: no marker, and its
  # session is NOT our holding session (no menu window). Must be judged NOT ours,
  # so csp_tmux_enter refuses to configure/claim it.
  csp_tmux new-session -d -s "someone-elses" -n work "sleep 60"
  run csp_tmux_server_is_ours
  [ "$status" -ne 0 ]
}

@test "enter: does NOT mutate a foreign server on an exact socket collision" {
  # The Medium finding: csp_tmux_enter's existing-session path used to configure
  # (mutate global mouse/status/@csp_owner) any server on our socket name. Now it
  # must refuse a foreign one. Build a foreign server that ALSO happens to have a
  # session named like ours but WITHOUT a menu window (so it's structurally not
  # ours), capture its global options, run enter, and confirm nothing changed.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n work "sleep 60"   # no menu window
  # `show-options -gv @csp_owner` exits non-zero when the option is unset; append
  # `|| true` so a bats assignment isn't treated as a failing command.
  before_mouse=$(csp_tmux show-options -g mouse 2>/dev/null || true)
  before_owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)
  self="$BATS_TEST_DIRNAME/../bin/claude-session-picker"
  run bash -c "CSP_TMUX_SOCKET='$CSP_TMUX_SOCKET' CSP_TMUX_SESSION='$CSP_TMUX_SESSION' \
    bash -c '. \"$BATS_TEST_DIRNAME/../lib/core.sh\"; . \"$BATS_TEST_DIRNAME/../lib/backend.sh\"; \
    csp_tmux_enter \"$self\"' </dev/null 2>&1"
  # The foreign server's global options are untouched, and it was NOT claimed.
  after_mouse=$(csp_tmux show-options -g mouse 2>/dev/null || true)
  after_owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)
  [ "$after_mouse" = "$before_mouse" ]
  [ "$after_owner" = "$before_owner" ]
  [ -z "$after_owner" ]   # still no marker → we never claimed it
}

@test "enter: does NOT mutate a foreign server whose session is NOT named ours (fresh-path collision)" {
  # The more likely real collision (and the fresh-path gap): the user's own tmux
  # on the exact -L socket name, but with a session named something else (e.g.
  # "work"). has-session -t=ours is false, so enter falls to the FRESH path —
  # which must detect a live foreign server and refuse, NOT create a session on
  # it and stamp global options + @csp_owner.
  csp_tmux new-session -d -s "work" -n w "sleep 60"      # foreign session name
  before_mouse=$(csp_tmux show-options -g mouse 2>/dev/null || true)
  before_owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)
  before_sessions=$(csp_tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ',')
  self="$BATS_TEST_DIRNAME/../bin/claude-session-picker"
  run bash -c "CSP_TMUX_SOCKET='$CSP_TMUX_SOCKET' CSP_TMUX_SESSION='$CSP_TMUX_SESSION' \
    bash -c '. \"$BATS_TEST_DIRNAME/../lib/core.sh\"; . \"$BATS_TEST_DIRNAME/../lib/backend.sh\"; \
    csp_tmux_enter \"$self\"' </dev/null 2>&1"
  # Globals untouched, no marker stamped, and NO new (ours) session was added.
  [ "$(csp_tmux show-options -g mouse 2>/dev/null || true)" = "$before_mouse" ]
  [ "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" = "$before_owner" ]
  [ -z "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" ]
  [ "$(csp_tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ',')" = "$before_sessions" ]
  # And our holding session was NOT created on their server.
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -ne 0 ]
}

@test "atomic-home: on a CLEAN socket, creates+configures our server (token, mouse, 0:menu, boot tag set)" {
  # atomic_home creates the server and stamps token + all config, but does NOT
  # respawn window 0 (the caller does that via direct argv). So window 0 is still
  # the bootstrap placeholder, tagged @csp_boot=1.
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$tok"
  [ "$(csp_tmux show-options -gv @csp_owner)" = "$tok" ]
  [ "$(csp_tmux show-options -gv mouse)" = "on" ]
  run csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}'
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "0:menu" ]
  [ "$(csp_tmux show-options -wv -t "=$CSP_TMUX_SESSION:0" @csp_boot 2>/dev/null)" = "1" ]
}

@test "cleanup: with an EMPTY pid but our TOKEN present, tears down OUR own just-created server (no orphan)" {
  # Edge case: a transient display-message pid-read failure (srv_pid empty)
  # right after atomic_home used to make csp_tmux_enter_cleanup a no-op, orphaning
  # the bootstrap session and (since the token isn't persisted yet) breaking future
  # launches. The token — an unguessable value only we set — is a definitive
  # ownership proof, so an empty pid + matching token must still clean up.
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$tok"
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -eq 0 ]
  csp_tmux_enter_cleanup "" "$tok"          # empty pid, token matches → kill ours
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -ne 0 ]                        # torn down, not orphaned
}

@test "cleanup: with an EMPTY pid and NO token match, leaves a foreign same-named server untouched" {
  # The safety complement: a foreign server that merely shares the socket+session
  # name but lacks our token must NOT be killed even on the empty-pid path — the
  # token proof fails, so we leave it alone (strictly safer than an unconditional
  # kill).
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n w "sleep 60"   # foreign, no token
  tok=$(csp_tmux_gen_owner_token)            # a token the foreign server never had
  csp_tmux_enter_cleanup "" "$tok"           # empty pid + non-matching token → no-op
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -eq 0 ]                        # foreign server survives
}

@test "atomic-home: JOINING a foreign server (other session present) stamps/mutates NOTHING (structural TOCTOU close)" {
  # The crux of the check->create race: if new-session lands on a live foreign
  # server (a session with a different name), the atomic invocation's
  # server_sessions==1 guard must fire NONE of the global mutations — no @csp_owner,
  # no mouse, nothing — so we never touch a user's server even in the race window.
  csp_tmux new-session -d -s "foreign-race" -n w "sleep 60"   # foreign server, other name
  before_mouse=$(csp_tmux show-options -gv mouse 2>/dev/null || true)
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$tok"    # our new-session JOINS the foreign server (2 sessions now)
  # NOT stamped, NOT configured — the foreign server is pristine.
  [ -z "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" ]
  [ "$(csp_tmux show-options -gv mouse 2>/dev/null || true)" = "$before_mouse" ]
  # The foreign session is untouched (still there).
  run csp_tmux has-session -t "=foreign-race"
  [ "$status" -eq 0 ]
}

@test "atomic-home: JOINING a foreign ZERO-session server (exit-empty off) stamps/mutates NOTHING" {
  # Round-7 High: a foreign server whose only session was killed can stay alive if
  # the user set `exit-empty off`. new-session then JOINS it, leaving server_sessions
  # ==1 (ours) — which alone would misidentify it as a fresh server we created. The
  # exit-empty==1 half of the guard rejects it: our own fresh server has exit-empty
  # on (default), a survived 0-session foreign server necessarily has it off.
  csp_tmux new-session -d -s "foreign-z" -n w "sleep 60"
  csp_tmux set-option -g exit-empty off 2>/dev/null
  before_mouse=$(csp_tmux show-options -gv mouse 2>/dev/null || true)
  csp_tmux kill-session -t "foreign-z" 2>/dev/null       # 0 sessions, server still alive
  # Precondition: server alive, 0 sessions.
  run csp_tmux list-sessions
  [ "$status" -eq 0 ]
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$tok"    # our new-session JOINS the surviving foreign server
  # The foreign server must NOT be configured or stamped.
  [ -z "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" ]
  [ "$(csp_tmux show-options -gv mouse 2>/dev/null || true)" = "$before_mouse" ]
}

@test "atomic-home: RECOVERS a stale OWNED 0-session server (exit-empty off + our prior token)" {
  # Round-9 fix: a server WE previously owned can survive at 0 sessions if an OLD
  # build inherited exit-empty off from the user's config. atomic_home given the
  # PRIOR token must recognise it (server_sessions==1 AND @csp_owner==prior),
  # reconfigure it, rotate the owner to the new token, and normalise exit-empty on.
  # Without this the upgraded user would fail to launch on every attempt.
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux set-option -g exit-empty off 2>/dev/null
  prior="csp-priorowned-$$"
  csp_tmux set-option -g @csp_owner "$prior" 2>/dev/null
  csp_tmux kill-session -t "$CSP_TMUX_SESSION" 2>/dev/null    # → stale owned 0-session
  run csp_tmux list-sessions; [ "$status" -eq 0 ]            # still alive
  newtok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$newtok" "$prior"
  # Recovered: owner rotated to the NEW token, exit-empty normalised on, configured.
  [ "$(csp_tmux show-options -gv @csp_owner)" = "$newtok" ]
  [ "$(csp_tmux show-options -gv exit-empty)" = "on" ]
  [ "$(csp_tmux show-options -gv mouse)" = "on" ]
}

@test "atomic-home: a foreign 0-session server is NOT recovered even when a prior token is supplied" {
  # The recovery branch must fire ONLY for OUR prior token. A foreign 0-session
  # server carries a different (or no) @csp_owner, so passing our prior token must
  # still leave it untouched — recovery can't be used to adopt someone else's tmux.
  csp_tmux new-session -d -s "foreign-z2" -n w "sleep 60"
  csp_tmux set-option -g exit-empty off 2>/dev/null
  csp_tmux set-option -g @csp_owner "csp-someone-else" 2>/dev/null   # NOT our token
  before_mouse=$(csp_tmux show-options -gv mouse 2>/dev/null || true)
  csp_tmux kill-session -t "foreign-z2" 2>/dev/null
  csp_tmux_atomic_home "$(csp_tmux_gen_owner_token)" "csp-our-prior-not-matching"
  # Untouched: still the foreign owner, mouse unchanged (never configured).
  [ "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" = "csp-someone-else" ]
  [ "$(csp_tmux show-options -gv mouse 2>/dev/null || true)" = "$before_mouse" ]
}

@test "atomic-home: a fresh server is configured even when the user's ~/.tmux.conf sets exit-empty off (F2)" {
  # F2 regression: our exit-empty==1 guard relies on tmux DEFAULTS. If our server
  # read the user's ~/.tmux.conf with `exit-empty off`, our own fresh server would
  # inherit off and the guard would wrongly refuse to configure it — breaking the
  # tmux backend for anyone who sets that. `csp_tmux` runs `-f /dev/null`, so our
  # server ignores the user config and always has exit-empty on. Build a HOME with
  # a hostile tmux.conf and confirm a fresh atomic-home still configures.
  uhome="$BATS_TEST_TMPDIR/uhome"; mkdir -p "$uhome"
  printf 'set-option -g exit-empty off\nset-option -g mouse off\n' > "$uhome/.tmux.conf"
  run env HOME="$uhome" CSP_TMUX_SOCKET="$CSP_TMUX_SOCKET" CSP_TMUX_SESSION="$CSP_TMUX_SESSION" \
    CSP_STATE_DIR="$CSP_STATE_DIR" bash -c '
      . "'"$BATS_TEST_DIRNAME"'/../lib/core.sh"; . "'"$BATS_TEST_DIRNAME"'/../lib/backend.sh"
      tok=$(csp_tmux_gen_owner_token)
      csp_tmux_atomic_home "$tok"
      printf "owner=[%s] mouse=[%s] ee=[%s]\n" \
        "$(csp_tmux show-options -gv @csp_owner 2>/dev/null)" \
        "$(csp_tmux show-options -gv mouse 2>/dev/null)" \
        "$(csp_tmux show-options -gv exit-empty 2>/dev/null)"'
  # Our server ignored the user config: exit-empty on, mouse configured on, owner set.
  case "$output" in *"ee=[on]"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ] || { echo "got: $output"; false; }
  case "$output" in *"mouse=[on]"*) ok2=1 ;; *) ok2=0 ;; esac
  [ "$ok2" = "1" ]
  case "$output" in *"owner=[csp-"*) ok3=1 ;; *) ok3=0 ;; esac
  [ "$ok3" = "1" ]
}

@test "enter: full fresh path JOINING a foreign server bails to hub and removes ONLY our own session" {
  # End-to-end: the pre-check refuses a live foreign server; even if we force past
  # it (stub server_is_ours), the atomic guard mutates nothing and the caller's
  # ours-only/token check removes only our added session, leaving the foreign one.
  csp_tmux new-session -d -s "foreign-race" -n w "sleep 60"
  self="$BATS_TEST_DIRNAME/../bin/claude-session-picker"
  run bash -c "CSP_TMUX_SOCKET='$CSP_TMUX_SOCKET' CSP_TMUX_SESSION='$CSP_TMUX_SESSION' CSP_STATE_DIR='$CSP_STATE_DIR' \
    bash -c '. \"$BATS_TEST_DIRNAME/../lib/core.sh\"; . \"$BATS_TEST_DIRNAME/../lib/backend.sh\"; \
      csp_tmux_server_is_ours() { return 1; }; \
      csp_tmux_enter \"$self\"' </dev/null 2>&1"
  # Our holding session must NOT survive; the foreign one must remain; no stamp.
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -ne 0 ]
  run csp_tmux has-session -t "=foreign-race"
  [ "$status" -eq 0 ]
  [ -z "$(csp_tmux show-options -gv @csp_owner 2>/dev/null || true)" ]
}

@test "enter: fresh path respawns window 0 with a command containing SPACES (regression: spaced \$HOME/env)" {
  # Regression for the if-shell nesting bug: the picker command is `env VAR=val …
  # /path`, full of spaces, and forwarded env values (CSP_STATE_DIR under a spaced
  # $HOME) also contain spaces. The respawn must be direct-argv so those survive.
  # We drive the fresh path with a REAL spaced state dir and a fake claude, and
  # assert window 0 ends up running our env-prefixed command (not a dead window /
  # destroyed session). We can't attach (no client), so we stop just before exec by
  # stubbing the exec-ing tail; instead we exercise csp_tmux_atomic_home + a direct
  # respawn with a spaced command and confirm the window survives with our command.
  spaced="$BATS_TEST_TMPDIR/state dir with spaces"; mkdir -p "$spaced"
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_atomic_home "$tok"
  # Direct-argv respawn with a spaced command, exactly as the fresh path now does.
  cmd="env CSP_STATE_DIR=$(csp_shell_quote "$spaced") sleep 62"
  csp_tmux respawn-window -k -t "=$CSP_TMUX_SESSION:menu" "$cmd"
  # The session survived and window 0 runs our (spaced) command, not a dead shell.
  run csp_tmux has-session -t "=$CSP_TMUX_SESSION"
  [ "$status" -eq 0 ]
  run csp_tmux list-panes -t "=$CSP_TMUX_SESSION:0" -F '#{pane_start_command}'
  case "$output" in *"62"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "recovery: a menu window orphaned at a NON-zero index is swapped back to 0" {
  # Edge case: an earlier partial recovery can leave a 'menu' window at a
  # non-zero index. The old guard ("does ANY window named menu exist?") would see
  # it and skip verification, attaching with a non-menu window 0. Recovery must
  # instead ensure window 0 IS menu. We reproduce the orphaned state and run the
  # same recovery the enter path uses, then assert 0:menu.
  #
  # Build: window 0 = a session (not menu), window 1 = menu (orphaned).
  csp_tmux new-session -d -s "$CSP_TMUX_SESSION" -n work "sleep 60"
  csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "sleep 60"
  csp_tmux_configure_home
  # Precondition: window 0 is NOT menu, but a menu window exists (at index 1).
  run csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}'
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "0:work" ]
  # Run the recovery sequence (the branch guarded by "window 0 is not 0:menu").
  if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}' \
       | grep -qx '0:menu'; then
    if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_name}' | grep -qx menu; then
      csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "sleep 60"
    fi
    csp_tmux swap-window -s "=$CSP_TMUX_SESSION:menu" -t "=$CSP_TMUX_SESSION:0"
  fi
  # Postcondition: window 0 is now menu (the orphan was swapped in, not duplicated).
  run csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}'
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "0:menu" ]
  # Exactly one menu window (no duplicate created).
  [ "$(csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_name}' | grep -cx menu)" = "1" ]
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

@test "session name: quotes and backslashes are stripped (safe in the atomic if-shell string)" {
  # The name is interpolated into a tmux if-shell command STRING; a literal quote
  # or backslash could break that string's quoting. Confirm they're stripped.
  CSP_TMUX_SESSION='x"y'"'"'z\w' bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SESSION"' > "$BATS_TEST_TMPDIR/sess2"
  run cat "$BATS_TEST_TMPDIR/sess2"
  case "$output" in *[\"\'\\]*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
  [ "$output" = "xyzw" ]
}

@test "session name: allowlist strips tmux FORMAT metachars (#{...}, \$, backtick, ;)" {
  # F3: the name is re-parsed by tmux, so tmux format syntax like #{server_sessions}
  # would EXPAND on the second pass (→ a wrong session name + half-configured
  # server). An allowlist ([A-Za-z0-9_-]) forecloses every tmux metachar at once.
  # Each hostile input must sanitize to exactly its allowlisted characters.
  _sess_sanitized() {   # $1 raw → prints sanitized CSP_TMUX_SESSION
    CSP_TMUX_SESSION="$1" bash -c '
      . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
      . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
      printf "%s" "$CSP_TMUX_SESSION"'
  }
  [ "$(_sess_sanitized 'x#{server_sessions}y')" = "xserver_sessionsy" ]
  [ "$(_sess_sanitized 'x${HOME}y')" = "xHOMEy" ]
  [ "$(_sess_sanitized 'x`id`y')" = "xidy" ]
  [ "$(_sess_sanitized 'x;y')" = "xy" ]
  [ "$(_sess_sanitized 'a:b.c')" = "abc" ]
  # And the result NEVER contains a tmux metachar.
  local s
  for raw in 'x#{server_sessions}y' 'x${HOME}y' 'x`id`y' 'a:b.c' 'x"y' 'x\w'; do
    s=$(_sess_sanitized "$raw")
    case "$s" in *['#{}$`:.;"'\'\\]*) echo "LEAK: [$raw]->[$s]"; false ;; esac
  done
}

@test "session name: an all-metachar name falls back to the default (never empty)" {
  out=$(CSP_TMUX_SESSION='#{}$`:."' bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SESSION"')
  [ "$out" = "claude-sessions" ]
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
  # And csp_inside_tmux parses the sanitized socket basename without breaking
  # (no crash / no error) — it returns non-zero here because the synthetic $TMUX
  # names no live server bound to our socket and no per-instance token matches,
  # which is the correct "not ours" answer.
  run env CSP_TMUX_SOCKET=abcd TMUX="/private/tmp/tmux-0/abcd,1,0" bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    csp_inside_tmux'
  [ "$status" -ne 0 ]
}

@test "socket name: empty after stripping falls back to the default" {
  CSP_TMUX_SOCKET="..." bash -c '
    . '"$BATS_TEST_DIRNAME"'/../lib/core.sh
    . '"$BATS_TEST_DIRNAME"'/../lib/backend.sh
    printf "%s" "$CSP_TMUX_SOCKET"' > "$BATS_TEST_TMPDIR/sock2"
  run cat "$BATS_TEST_TMPDIR/sock2"
  [ "$output" = "claude-sessions" ]
}
