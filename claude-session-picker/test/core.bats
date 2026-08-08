#!/usr/bin/env bats
# =============================================================================
# core.bats — unit tests for lib/core.sh (the pure logic).
#
# These tests read NO files and launch NO programs. They feed known inputs to
# the pure functions and assert exact outputs. That is what lets us claim the
# decision logic is correct and memory-safe: every boundary (empty list,
# out-of-range index, oversized title, multi-byte text, id look-alikes) is
# exercised here.
#
# Run with:  bats test/core.bats
# =============================================================================

setup() {
  # A UTF-8 locale so ${#text} counts CHARACTERS, not bytes — this is what makes
  # the multibyte (Chinese) truncation test meaningful and stable across shells.
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
  . "$BATS_TEST_DIRNAME/../lib/core.sh"
}

# --- csp_choose_backend (how sessions are run) -------------------------------

@test "backend: auto picks tmux when tmux is available" {
  run csp_choose_backend 1 0 ""
  [ "$output" = "tmux" ]
}

@test "backend: auto picks hub when tmux is absent" {
  run csp_choose_backend 0 0 ""
  [ "$output" = "hub" ]
}

@test "backend: forcing hub always yields hub" {
  run csp_choose_backend 1 1 "hub"
  [ "$output" = "hub" ]
}

@test "backend: forcing tmux yields tmux only if tmux exists" {
  run csp_choose_backend 1 0 "tmux"
  [ "$output" = "tmux" ]
}

@test "backend: forcing tmux falls back to hub when tmux is absent" {
  # We must never promise the tmux backend when the tmux command isn't there.
  run csp_choose_backend 0 0 "tmux"
  [ "$output" = "hub" ]
}

# --- csp_marker_for_session --------------------------------------------------

@test "marker: a live session shows the running dot" {
  run csp_marker_for_session 1
  [ "$output" = "$CSP_MARKER_LIVE" ]
}

@test "marker: a non-live session shows nothing" {
  run csp_marker_for_session 0
  [ "$output" = "$CSP_MARKER_NONE" ]
}

# --- csp_clamp_index (the memory-safety guard) -------------------------------

@test "clamp: empty list always yields index 0" {
  run csp_clamp_index 5 0
  [ "$output" = "0" ]
}

@test "clamp: index inside range is unchanged" {
  run csp_clamp_index 2 5
  [ "$output" = "2" ]
}

@test "clamp: going below top wraps to last item" {
  run csp_clamp_index -1 5
  [ "$output" = "4" ]
}

@test "clamp: going past bottom wraps to first item" {
  run csp_clamp_index 5 5
  [ "$output" = "0" ]
}

@test "clamp: far out-of-range never escapes the list" {
  run csp_clamp_index 9999 3
  [ "$output" = "0" ]
}

# --- csp_encode_project_dir --------------------------------------------------

@test "encode: slashes become dashes like Claude's folder names" {
  run csp_encode_project_dir "/Volumes/work/tools"
  [ "$output" = "-Volumes-work-tools" ]
}

# --- csp_short_path ----------------------------------------------------------

@test "short path: keeps the last two components" {
  run csp_short_path "/Users/me/work/EnglishTraining/tools"
  [ "$output" = "EnglishTraining/tools" ]
}

@test "short path: a bare name is returned as-is" {
  run csp_short_path "tools"
  [ "$output" = "tools" ]
}

# --- csp_truncate ------------------------------------------------------------

@test "truncate: short text is unchanged" {
  run csp_truncate "hello" 20
  [ "$output" = "hello" ]
}

@test "truncate: long text is cut and gets an ellipsis" {
  run csp_truncate "abcdefghij" 5
  [ "$output" = "abcd…" ]
  # 4 kept chars + the ellipsis character = 5 visible characters
  [ "${#output}" -eq 5 ]
}

@test "truncate: multibyte (Chinese) text is measured by character, not byte" {
  run csp_truncate "實作切換工具很好用" 4
  # 3 kept characters + ellipsis = 4 characters
  [ "${#output}" -eq 4 ]
}

# --- csp_format_line ---------------------------------------------------------

@test "format: selected row starts with the cursor marker" {
  run csp_format_line "$CSP_MARKER_LIVE" "my title" "proj/dir" "2h ago" 1
  case "$output" in ">"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "format: pathological long title cannot exceed the line cap" {
  long=$(printf 'x%.0s' $(seq 1 500))
  run csp_format_line " " "$long" "p" "now" 0
  [ "${#output}" -le "$CSP_MAX_LINE_LEN" ]
}

# --- csp_field ---------------------------------------------------------------

@test "field: reads the requested tab-separated column" {
  line=$(printf 'title\tid123\t/proj')
  run csp_field "$line" 2
  [ "$output" = "id123" ]
}

@test "field: asking past the end returns empty, not an error" {
  line=$(printf 'a\tb')
  run csp_field "$line" 9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- csp_humanize_age --------------------------------------------------------

@test "age: under a minute reads 'just now'" {
  run csp_humanize_age 30
  [ "$output" = "just now" ]
}

@test "age: minutes, hours and days are rendered" {
  run csp_humanize_age 120;    [ "$output" = "2m ago" ]
  run csp_humanize_age 7200;   [ "$output" = "2h ago" ]
  run csp_humanize_age 172800; [ "$output" = "2d ago" ]
}

@test "age: empty or non-numeric input never crashes" {
  run csp_humanize_age ""
  [ "$output" = "just now" ]
  run csp_humanize_age "abc"
  [ "$output" = "just now" ]
}

# --- csp_window_start (scrolling viewport math) ------------------------------

@test "window: everything fits → starts at the top" {
  run csp_window_start 3 5 10
  [ "$output" = "0" ]
}

@test "window: selection near the top stays at the top" {
  run csp_window_start 0 100 10
  [ "$output" = "0" ]
}

@test "window: selection in the middle centres the window" {
  # visible/2 = 5, so start = 50 - 5 = 45
  run csp_window_start 50 100 10
  [ "$output" = "45" ]
}

@test "window: selection at the very end clamps to the last full page" {
  # count - visible = 90
  run csp_window_start 99 100 10
  [ "$output" = "90" ]
}

@test "window: zero visible rows never divides by zero or goes negative" {
  run csp_window_start 5 100 0
  [ "$output" = "0" ]
}

# --- csp_is_live (whole-line id matching) ------------------------------------

@test "live: exact id in the running list matches" {
  running=$(printf 'aaa\nbbb\nccc')
  run csp_is_live "bbb" "$running"
  [ "$status" -eq 0 ]
}

@test "live: an id that is only a substring of a running id does NOT match" {
  running=$(printf 'bbbbbb')
  run csp_is_live "bbb" "$running"
  [ "$status" -ne 0 ]
}

@test "live: an empty id is never live" {
  running=$(printf 'aaa\nbbb')
  run csp_is_live "" "$running"
  [ "$status" -ne 0 ]
}

@test "live: nothing running means nothing is live" {
  run csp_is_live "aaa" ""
  [ "$status" -ne 0 ]
}
