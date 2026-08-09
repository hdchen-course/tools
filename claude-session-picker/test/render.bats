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

@test "render: the frame never exceeds the actual terminal width (incl. <42 cols)" {
  # Regression: CSP_INNER used to be floored at 40, so on a 30- or 40-column
  # terminal the frame rules (CSP_INNER+2 wide) were WIDER than the screen and
  # wrapped/scrolled. Now CSP_INNER = min(cols-2, 96), so the frame's character
  # count (each box glyph is one terminal column) never exceeds cols. We count
  # CHARACTERS, not csp_display_width (which intentionally treats CJK as 2 cols
  # and would miscount the box-drawing glyphs).
  local c chars plain
  # Include sub-6-column micro-pane widths: the title rule has fixed chrome
  # ("┌─ … ┐") and must drop the title entirely rather than overflow.
  for c in 3 4 5 6 10 20 30 40 42 60 80 200; do
    csp_build_chrome "$c" 5
    plain="$(strip_sgr "$CSP_CHROME_TOP")"
    chars=${#plain}
    [ "$chars" -le "$c" ] || { echo "cols=$c frame_chars=$chars CSP_INNER=$CSP_INNER"; false; }
    # Bottom rule too (same width contract).
    plain="$(strip_sgr "$CSP_CHROME_BOT")"; chars=${#plain}
    [ "$chars" -le "$c" ] || { echo "cols=$c BOT chars=$chars"; false; }
  done
}

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
  csp_ids=(a b); csp_titles=("alpha" "beta"); csp_titles_full=("alpha" "beta")
  csp_projects=("p/a" "p/b")
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
  csp_titles_full=("refactor parser" "flaky test" "parser cleanup")
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

# Draw in the CURRENT shell (never a subshell) and set two globals:
#   CSP_TEST_SB  — the status-bar line, colour-stripped, leading pad removed
#   CSP_TEST_SB_W — its display width
# Drawing in-process matters: csp_draw mutates CSP_INNER/CSP_BUF, and a `$(...)`
# capture would run it in a subshell whose CSP_INNER never reaches the caller —
# so the test would compare the width against a STALE CSP_INNER. Assigning
# globals here keeps width and CSP_INNER from the SAME draw.
_measure_status_bar() {
  local buf plain
  csp_draw 0 >/dev/null                 # populates CSP_BUF / updates CSP_INNER
  buf="$(printf '%s' "$CSP_BUF" | sed 's/\x1b\[K//g')"
  # Status bar is the second-to-last line of the buffer (bottom rule is last).
  plain="$(printf '%s\n' "$buf" | sed -n "$(( $(printf '%s\n' "$buf" | grep -c '') - 1 ))p")"
  plain="$(strip_sgr "$plain")"
  CSP_TEST_SB="${plain# }"
  CSP_TEST_SB_W=$(csp_display_width "$CSP_TEST_SB")
}

# Build a 3-session model with a ✳ (so the attention badge is present) and CJK
# titles/projects, then force a terminal size via stubs.
_setup_cjk_model() {
  csp_count=3
  csp_ids=(a b c); csp_titles=("重構解析器" "flaky test" "解析清理")
  csp_titles_full=("重構解析器" "flaky test" "解析清理")
  csp_projects=("專案/甲" "p/y" "專案/乙"); csp_fullprojects=(/t /t /t)
  csp_files=(a.jsonl b.jsonl c.jsonl); csp_ages=("1m ago" "2m ago" "3m ago")
  csp_lives=(0 0 0); csp_states=("" "" ""); csp_markers=(" " "✳" " "); CSP_HAVE_STATE=1
  local k r
  for k in 0 1 2; do
    r=$(csp_format_line "${csp_markers[$k]}" "${csp_titles[$k]}" "${csp_projects[$k]}" "${csp_ages[$k]}" 0)
    csp_rows[$k]="$r"
  done
}

@test "render: status bar never overflows the frame — badge + CJK filter, many widths" {
  _setup_cjk_model
  local cols
  csp_visible_rows() { printf '10'; }
  for cols in 40 50 60 80 100 120; do
    # Stub the width probe so csp_draw uses exactly this width, and bust the
    # chrome cache so it actually rebuilds for the new width this iteration.
    eval "csp_term_cols() { printf '%s' $cols; }"
    CSP_CHROME_COLS=""
    CSP_FILTER="解析"; csp_rebuild_view; csp_retally_attention
    _measure_status_bar
    # Must fit within the inner content width (never wrap the frame).
    [ "$CSP_TEST_SB_W" -le "$CSP_INNER" ] \
      || { echo "cols=$cols INNER=$CSP_INNER width=$CSP_TEST_SB_W : [$CSP_TEST_SB]"; false; }
  done
}

@test "filter: matches the FULL project path and FULL title, not the display strings" {
  # The filter haystack must use csp_fullprojects (full cwd) and csp_titles_full
  # (untruncated title), so a query can match a parent dir the display dropped or
  # text past the 60-col title cut — the docs promise "any part of a title or
  # project path".
  csp_count=1
  csp_ids=(a)
  # Display title truncated; full title has extra text past the cut.
  csp_titles=("short shown")
  csp_titles_full=("short shown … then a UNIQUEWORD far past the visible part")
  # Display project is the last two components only; full path has more parents.
  csp_projects=("EnglishTraining/tools")
  csp_fullprojects=("/Users/me/work/EnglishTraining/tools")
  csp_files=(a.jsonl); csp_ages=("1m ago"); csp_states=(""); csp_markers=(" ")
  # A parent directory dropped from the display path still matches.
  CSP_FILTER="work"; csp_rebuild_view
  [ "$csp_view_count" -eq 1 ]
  # Text past the display-title truncation still matches.
  CSP_FILTER="UNIQUEWORD"; csp_rebuild_view
  [ "$csp_view_count" -eq 1 ]
  # A genuine non-match still yields nothing.
  CSP_FILTER="zzz-no-such"; csp_rebuild_view
  [ "$csp_view_count" -eq 0 ]
}

# Build a TINY (2-row) visible model but set the status-bar drivers directly to
# the large values a big, all-attention, filtered list would produce. The status
# bar's width math reads only CSP_ATTENTION_COUNT, csp_count, csp_view_count,
# selected and CSP_FILTER — so we set those rather than formatting hundreds of
# rows (which was fork-heavy enough to time the suite out). Two real rows keep
# the draw loop honest without the cost.
_setup_wide_statusbar() {
  local badge_count="$1" total="$2" filter="$3"
  # csp_count/csp_view_count are set to the (large) total for the "X/Y of Z"
  # width, but only TWO rows are ever drawn: selected=0 with visible=2 keeps the
  # draw window at indices 0..1, so csp_view/csp_rows need only two entries and
  # no out-of-range read occurs. This exercises the status-bar width math at
  # scale without formatting a large model.
  csp_count="$total"
  csp_ids=(a b); csp_titles=(t t); csp_titles_full=(t t)
  csp_projects=(p p); csp_fullprojects=(/t /t); csp_files=(a.jsonl b.jsonl)
  csp_ages=("1m ago" "1m ago"); csp_lives=(0 0); csp_states=("" ""); csp_markers=("✳" "✳")
  local k r
  for k in 0 1; do r=$(csp_format_line "✳" t p "1m ago" 0); csp_rows[$k]="$r"; done
  CSP_HAVE_STATE=1
  csp_view=(0 1); csp_view_count="$total"
  CSP_ATTENTION_COUNT="$badge_count"
  CSP_FILTER="$filter"
}

@test "render: badge + active filter together never overflow a narrow (40 col) frame" {
  # Edge case: at 40 cols the RIGHT block alone (N✳ badge + a 20-col-bounded
  # filter position) can exceed CSP_INNER — the earlier short-filter/tiny-count
  # fixture never triggered the shrink block. Drive it with a 3-digit badge count
  # and a long (bounded to 20 cols) filter so badge_col + pos_col > 40.
  _setup_wide_statusbar 150 150 "解析工作階段重構清理維護"
  csp_visible_rows() { printf '2'; }
  eval "csp_term_cols() { printf '40'; }"
  CSP_CHROME_COLS=""
  [ "$CSP_ATTENTION_COUNT" -gt 0 ]        # badge is genuinely present
  _measure_status_bar
  [ "$CSP_TEST_SB_W" -le "$CSP_INNER" ] \
    || { echo "INNER=$CSP_INNER width=$CSP_TEST_SB_W : [$CSP_TEST_SB]"; false; }
}

@test "render: an oversized right block (badge + wide filter + big counts) is truncated to fit" {
  # Hard case at a 40-col frame: a large ✳ badge, a 20-col-bounded filter, AND
  # 6-digit "X/Y of Z" counts push the right block well past the frame. The code
  # drops the badge and then hard-truncates the position to CSP_INNER-1, so the
  # emitted bar (leading pad + position) still fits exactly. This is the belt of
  # the two-layer guard (drop badge → truncate); the gap-floor tweak is the
  # suspenders behind it.
  _setup_wide_statusbar 1000 100000 "解析工作階段重構清理維護"
  csp_visible_rows() { printf '2'; }
  eval "csp_term_cols() { printf '42'; }"     # CSP_INNER = 40
  CSP_CHROME_COLS=""
  _measure_status_bar
  [ "$CSP_TEST_SB_W" -le "$CSP_INNER" ] \
    || { echo "INNER=$CSP_INNER width=$CSP_TEST_SB_W : [$CSP_TEST_SB]"; false; }
}

@test "render: a long/wide filter query is truncated in the status bar, not shown whole" {
  _setup_cjk_model
  eval "csp_term_cols() { printf '120'; }"
  csp_visible_rows() { printf '10'; }
  CSP_CHROME_COLS=""     # bust chrome cache so the stubbed width takes effect
  CSP_FILTER="解析器工作階段重構清理維護測試除錯優化更多更多更多"
  csp_rebuild_view; csp_retally_attention
  _measure_status_bar
  # The bounded query ends with the ellipsis, and the whole bar still fits.
  case "$CSP_TEST_SB" in *"…"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
  [ "$CSP_TEST_SB_W" -le "$CSP_INNER" ]
}
