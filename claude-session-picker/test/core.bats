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

@test "backend: auto defaults to hub even when tmux is available" {
  # tmux is opt-in; merely having it installed must NOT change the default.
  run csp_choose_backend 1 0 ""
  [ "$output" = "hub" ]
}

@test "backend: auto defaults to hub when tmux is absent" {
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

@test "backend: an unrecognised forced value falls through to auto (hub)" {
  # e.g. a typo like "Hub" is not honoured as an override, so we get the
  # default auto choice, which is now hub even with tmux available.
  run csp_choose_backend 1 0 "Hub"
  [ "$output" = "hub" ]
}

# --- csp_backend_is_valid ----------------------------------------------------

@test "backend-valid: empty, hub, tmux are valid" {
  run csp_backend_is_valid "";     [ "$status" -eq 0 ]
  run csp_backend_is_valid "hub";  [ "$status" -eq 0 ]
  run csp_backend_is_valid "tmux"; [ "$status" -eq 0 ]
}

@test "backend-valid: typos and unknown values are invalid" {
  run csp_backend_is_valid "Hub";    [ "$status" -ne 0 ]
  run csp_backend_is_valid "screen"; [ "$status" -ne 0 ]
  run csp_backend_is_valid "tmx";    [ "$status" -ne 0 ]
}

# --- csp_marker_for_session --------------------------------------------------

@test "marker: a live session with no state shows the working dot" {
  run csp_marker_for_session 1
  [ "$output" = "$CSP_MARKER_WORKING" ]
}

@test "marker: a non-live session with no state shows nothing" {
  run csp_marker_for_session 0
  [ "$output" = "$CSP_MARKER_NONE" ]
}

@test "marker: live + state 'working' shows the working dot" {
  run csp_marker_for_session 1 working
  [ "$output" = "$CSP_MARKER_WORKING" ]
}

@test "marker: live + state 'waiting' shows the attention star" {
  run csp_marker_for_session 1 waiting
  [ "$output" = "$CSP_MARKER_ATTENTION" ]
}

@test "marker: RECONCILER — not live but state 'working' becomes attention" {
  # The hook said working but the process is gone (crash/kill mid-turn): we must
  # surface it as needs-attention, not leave a stuck working dot or blank.
  run csp_marker_for_session 0 working
  [ "$output" = "$CSP_MARKER_ATTENTION" ]
}

@test "marker: state 'waiting' ALWAYS shows attention, even when not detected live" {
  # STATE is authoritative: a session started as a bare `claude` (e.g. via 'n')
  # reads as not-live because it has no `--resume <id>` to match, but if the
  # hook says it's waiting for you it MUST still show ✳ — never go blank. This
  # is the inversion bug the marker rule is designed to prevent.
  run csp_marker_for_session 0 waiting
  [ "$output" = "$CSP_MARKER_ATTENTION" ]
}

@test "marker: an unknown state falls back to the live/blank rule" {
  run csp_marker_for_session 1 bogus
  [ "$output" = "$CSP_MARKER_WORKING" ]
  run csp_marker_for_session 0 bogus
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

# --- display-width helpers (CJK alignment) -----------------------------------

@test "width: ASCII counts one column per character" {
  run csp_display_width "hello"
  [ "$output" = "5" ]
}

@test "width: CJK characters count two columns each" {
  run csp_display_width "白銀"       # 2 wide chars -> 4 columns
  [ "$output" = "4" ]
}

@test "width: mixed ASCII and CJK adds up correctly" {
  run csp_display_width "abc白d"     # 4 ascii (4) + 1 CJK (2) = 6
  [ "$output" = "6" ]
}

@test "width: 2-byte characters (Cyrillic/accented/Greek) count as ONE column" {
  # Regression: the old (chars+bytes)/2 heuristic over-counted these as ~1.5x,
  # misaligning any accented-Latin/Greek/Cyrillic title.
  run csp_display_width "ДД"          # 2 Cyrillic → 2 columns (not 3)
  [ "$output" = "2" ]
  run csp_display_width "éé"          # 2 accented Latin → 2
  [ "$output" = "2" ]
  run csp_display_width "αβγ"         # 3 Greek → 3
  [ "$output" = "3" ]
}

@test "width: an emoji counts as two columns" {
  run csp_display_width "🎉"
  [ "$output" = "2" ]
}

@test "byte-len: measures UTF-8 byte length, not character count" {
  run csp_byte_len "白"              # one 3-byte CJK char
  [ "$output" = "3" ]
  run csp_byte_len "a"
  [ "$output" = "1" ]
}

@test "pad: pads a short string to the requested display width" {
  run csp_pad_display "hi" 6
  [ "$output" = "hi    " ]           # 2 + 4 spaces = 6 columns
}

@test "pad: pads a CJK string by display width, not char count" {
  run csp_pad_display "白銀" 6        # width 4 -> add 2 spaces
  [ "$output" = "白銀  " ]
}

@test "pad: a string already at/over width is unchanged" {
  run csp_pad_display "hello" 3
  [ "$output" = "hello" ]
}

@test "truncate-display: a CJK title is cut to fit its column width" {
  # 6 wide chars = 12 columns; fit into 8 -> keep chars whose width <=7 + '…'
  run csp_truncate_display "實作切換工具" 8
  [ "$(csp_display_width "$output")" -le 8 ]
  case "$output" in *…) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

# --- csp_format_line ---------------------------------------------------------

@test "format: selected row starts with the cursor pointer" {
  run csp_format_line "$CSP_MARKER_LIVE" "my title" "proj/dir" "2h ago" 1
  case "$output" in "›"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "1" ]
}

@test "format: unselected row does not start with the pointer" {
  run csp_format_line "$CSP_MARKER_NONE" "my title" "proj/dir" "2h ago" 0
  case "$output" in "›"*) ok=1 ;; *) ok=0 ;; esac
  [ "$ok" = "0" ]
}

@test "format: CJK and ASCII rows align to the same project column" {
  # The project field must start at the same display column regardless of
  # whether the title is Chinese or English.
  cjk=$(csp_format_line " " "白銀交易訊號框架研究" "proj/a" "1m ago" 0)
  ascii=$(csp_format_line " " "Refactor the parser" "proj/b" "1m ago" 0)
  # Column where "proj" appears, measured in display width of the prefix.
  cjk_pre="${cjk%%proj/a*}"
  ascii_pre="${ascii%%proj/b*}"
  [ "$(csp_display_width "$cjk_pre")" = "$(csp_display_width "$ascii_pre")" ]
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

# --- csp_count_attention / csp_next_attention (the '*' jump + urgency count) --

@test "attention: count is 0 for an empty marker list" {
  run csp_count_attention ""
  [ "$output" = "0" ]
}

@test "attention: counts only the ✳ (needs-you) markers" {
  # markers, one per line, in list order: ● ✳ (blank) ✳
  markers="$(printf '%s\n%s\n%s\n%s' "$CSP_MARKER_WORKING" "$CSP_MARKER_ATTENTION" "$CSP_MARKER_NONE" "$CSP_MARKER_ATTENTION")"
  run csp_count_attention "$markers"
  [ "$output" = "2" ]
}

@test "attention: next jumps forward to the nearest ✳ and wraps around" {
  # indices:        0=●        1=✳             2=blank            3=✳
  markers="$(printf '%s\n%s\n%s\n%s' "$CSP_MARKER_WORKING" "$CSP_MARKER_ATTENTION" "$CSP_MARKER_NONE" "$CSP_MARKER_ATTENTION")"
  # From 0, the next ✳ is index 1.
  run csp_next_attention 0 4 "$markers"; [ "$output" = "1" ]
  # From 1, the next ✳ is index 3.
  run csp_next_attention 1 4 "$markers"; [ "$output" = "3" ]
  # From 3, it wraps around back to index 1.
  run csp_next_attention 3 4 "$markers"; [ "$output" = "1" ]
}

@test "attention: next is a no-op (returns current) when nothing needs attention" {
  markers="$(printf '%s\n%s\n%s' "$CSP_MARKER_WORKING" "$CSP_MARKER_NONE" "$CSP_MARKER_NONE")"
  run csp_next_attention 1 3 "$markers"
  [ "$output" = "1" ]
}

@test "attention: next on an empty list returns 0 (never out of range)" {
  run csp_next_attention 0 0 ""
  [ "$output" = "0" ]
}

# --- csp_filter_indices (type-to-filter '/') ---------------------------------

@test "filter: an empty needle matches every row, in order" {
  rows="$(printf 'alpha\nbeta\ngamma')"
  run csp_filter_indices "" "$rows"
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "0 1 2" ]
}

@test "filter: matches a substring and returns only matching indices" {
  rows="$(printf 'refactor parser\nflaky test\nparser cleanup')"
  run csp_filter_indices "parser" "$rows"
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "0 2" ]
}

@test "filter: matching is case-insensitive for ASCII" {
  rows="$(printf 'Refactor Parser\nflaky test')"
  run csp_filter_indices "PARSER" "$rows"
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "0" ]
}

@test "filter: no match yields no indices (empty output)" {
  rows="$(printf 'alpha\nbeta')"
  run csp_filter_indices "zzz" "$rows"
  [ -z "$output" ]
}

@test "filter: an empty haystack yields nothing (no phantom index 0)" {
  run csp_filter_indices "" ""
  [ -z "$output" ]
  run csp_filter_indices "anything" ""
  [ -z "$output" ]
}

@test "filter: CJK substrings match (no case folding needed)" {
  rows="$(printf '重構解析器\n測試修復')"
  run csp_filter_indices "解析" "$rows"
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "0" ]
}

@test "filter: a needle with spaces matches within a line" {
  rows="$(printf 'fix the flaky test\nunrelated')"
  run csp_filter_indices "flaky test" "$rows"
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "0" ]
}
