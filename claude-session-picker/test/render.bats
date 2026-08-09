#!/usr/bin/env bats
# =============================================================================
# render.bats — regression tests for the draw/chrome layer (v1.2.0).
#
# The draw layer had no coverage until the 1.2.0 review surfaced two defects:
#   1. the marker legend was emitted un-fitted and overflowed an 80-column
#      frame in the no-hooks first-run case (wrapped → broke the layout);
#   2. the "no matches" message told users "Esc clears the filter" when Esc
#      actually quits.
# These tests source the picker (main loop suppressed via CSP_SOURCED_FOR_TEST)
# and assert the fixed behaviour so neither can regress.
#
# Run with:  bats test/render.bats
# =============================================================================

setup() {
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"
  export NO_COLOR=1
  # Source the whole picker WITHOUT running main. csp_build_chrome / csp_draw
  # and the model globals then exist for direct exercise.
  export CSP_SOURCED_FOR_TEST=1
  . "$BATS_TEST_DIRNAME/../bin/claude-session-picker"
}

# Strip SGR colour codes so width assertions measure only visible text.
strip_sgr() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

@test "render: the marker legend never exceeds the inner width (no-hooks, 80 cols)" {
  # The exact first-run case the blocker hit: hooks not wired, 80-column frame.
  CSP_HAVE_STATE=0
  csp_build_chrome 80 10
  plain="$(strip_sgr "$CSP_CHROME_LEGEND")"
  plain="${plain# }"                       # drop the one leading space
  w=$(csp_display_width "$plain")
  [ "$w" -le "$CSP_INNER" ]
  # And it still contains the base legend (feature isn't silently dropped).
  case "$plain" in *"working"*"needs you"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "render: the legend fits even on a very narrow (40 col) terminal" {
  CSP_HAVE_STATE=0
  csp_build_chrome 40 10
  plain="$(strip_sgr "$CSP_CHROME_LEGEND")"; plain="${plain# }"
  [ "$(csp_display_width "$plain")" -le "$CSP_INNER" ]
}

@test "render: with hooks present the legend shows no first-run hint (no nag)" {
  CSP_HAVE_STATE=1
  csp_build_chrome 80 10
  plain="$(strip_sgr "$CSP_CHROME_LEGEND")"
  case "$plain" in *"--doctor"*) nag=1 ;; *) nag=0 ;; esac
  [ "$nag" = "0" ]
  case "$plain" in *"working"*"needs you"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "render: the no-match hint tells you how to clear, and never says 'Esc'" {
  # Build a model of 2 sessions, apply a filter that matches nothing, draw, and
  # capture the frame. The hint must NOT claim Esc clears the filter (Esc quits).
  csp_count=2
  csp_ids=(a b); csp_titles=("alpha" "beta"); csp_projects=("p/a" "p/b")
  csp_fullprojects=(/t /t); csp_files=(a.jsonl b.jsonl); csp_ages=("1m ago" "2m ago")
  csp_lives=(0 0); csp_states=("" ""); csp_markers=(" " " "); CSP_HAVE_STATE=1
  local i r
  for i in 0 1; do
    r=$(csp_format_line " " "${csp_titles[$i]}" "${csp_projects[$i]}" "${csp_ages[$i]}" 0)
    csp_rows[$i]="$r"
  done
  CSP_FILTER="zzz-nothing-matches"; csp_rebuild_view
  [ "$csp_view_count" -eq 0 ]
  out="$(strip_sgr "$(csp_draw 0)")"
  case "$out" in *"No sessions match"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  # The bug was the words "Esc clears the filter".
  case "$out" in *"Esc clears"*) bad=1 ;; *) bad=0 ;; esac
  [ "$bad" = "0" ]
}

@test "render: an active filter shows the query and visible/total in the status bar" {
  csp_count=3
  csp_ids=(a b c); csp_titles=("refactor parser" "flaky test" "parser cleanup")
  csp_projects=("p/x" "p/y" "p/z"); csp_fullprojects=(/t /t /t)
  csp_files=(a.jsonl b.jsonl c.jsonl); csp_ages=("1m ago" "2m ago" "3m ago")
  csp_lives=(0 0 0); csp_states=("" "" ""); csp_markers=(" " " " " "); CSP_HAVE_STATE=1
  local i r
  for i in 0 1 2; do
    r=$(csp_format_line " " "${csp_titles[$i]}" "${csp_projects[$i]}" "${csp_ages[$i]}" 0)
    csp_rows[$i]="$r"
  done
  CSP_FILTER="parser"; csp_rebuild_view
  [ "$csp_view_count" -eq 2 ]
  out="$(strip_sgr "$(csp_draw 0)")"
  case "$out" in *"/parser"*"of 3"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}
