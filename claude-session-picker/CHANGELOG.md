# Changelog

All notable changes to `claude-session-picker` are recorded here. The installed
command is a symlink updated in place by `git pull`, so this file (and the
`--version` output) is how you tell which build you're running.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/);
this project uses simple `MAJOR.MINOR.PATCH` version numbers.

## 1.2.0

### Added
- **Type-to-filter** — press `/`, type any part of a title or project path, and
  the list narrows to the matches (case-insensitive; works with CJK). The status
  bar shows the active query and the visible/total split (`/parser  1/2 of 42`);
  an empty query clears it. Filtering never changes your sessions — it only
  chooses which rows are shown, layered over the model via a view-index map.
- **Jump to next needs-you** — `*` moves the cursor to the next `✳` session and
  wraps around, so a session waiting for you can't get lost far down a long,
  recency-sorted list. A `N✳ *:jump` badge in the status bar shows how many need
  you (counted over the currently visible rows).
- **On-screen marker legend** — the header now spells out `● working  ✳ needs
  you`, and when the optional status hooks aren't wired it adds a one-line
  "live status off" hint pointing at `--doctor` / the README. With hooks present
  it's a plain legend, no nag.
- **`--doctor`** — a read-only preflight that reports, as OK/WARN lines, whether
  `claude` is on PATH, which JSON parser will be used (jq/python3/awk), whether
  the status hooks are wired, the session store and state dir, and tmux
  availability. Exits non-zero only if `claude` itself is missing.
- **`--list`** — print every session as `id<TAB>title<TAB>project<TAB>age` and
  exit, for composing with other tools (e.g. `claude-session-picker --list | fzf`)
  without the picker taking on a fuzzy-finder dependency.

### Fixed
- **Delete never removes a session that's in use, checked twice.** Liveness is
  re-evaluated at delete time and again after you confirm (closing a stale-
  snapshot gap), and it now also honours the hook `working` state — so a bare
  session started with `n` (which has no `claude --resume <id>` to detect) is
  protected too. The refusal message says whether it's actually running or just
  marked busy, and how to clear a stale flag.
- **`n` sessions become dedupable.** With hooks installed, the hook tags its tmux
  window with the session id, so a later `Enter` on that session switches to the
  existing window instead of starting a second copy over the same transcript.
- **The frame never exceeds the terminal width.** The inner width is now
  `min(cols-2, 96)` (previously floored at 40, which drew a frame wider than a
  <42-column terminal and made it wrap/scroll); the title rule and the marker
  legend degrade gracefully on very narrow terminals.
- **The installer's hook snippet is shell- and JSON-safe.** The hook path is
  single-quoted and the whole command JSON-escaped, so a repo path containing
  spaces, quotes, backslashes, or shell metacharacters produces a valid,
  non-executable command string.
- **Filter matches the full title and full project path**, not the on-screen
  (truncated title / shortened path) strings — so a query for a parent directory
  or for text past the 60-column title cut now matches, as the docs promise.
- **Status bar can't overflow even on a very narrow terminal.** When the badge +
  filter position alone exceed the frame width, the right block is shrunk in
  priority order (drop the badge, then hard-truncate the position) before laying
  out the key hints, so the bar never wraps at 40 columns.
- **tmux menu recovery always lands you on `0:menu`.** A `menu` window orphaned at
  a non-zero index (e.g. by an earlier partial recovery) is now swapped back to
  index 0 rather than skipped, closing the menu-less-window-0 gap.
- **tmux: no duplicate concurrent resume.** Opening a session that already has a
  window switches to it instead of launching a second `claude --resume` over the
  same transcript. Each session window is tagged with its id (`@csp_sid`).
- **tmux: quitting is consistent after toggling to hub.** `q` now decides
  detach-vs-exit from whether you're physically inside the tmux menu, not the
  logical backend — so toggling to hub (`t`) while still in the menu no longer
  strands the client or kills neighbouring session windows.
- **tmux: `n` opens in the directory you re-attached from**, not the one the
  resident picker was first launched in (recorded per-attach in a tmux session
  env var, read live).
- **tmux: menu recovery is checked.** If rebuilding the menu window (after a
  previous `q` closed it) fails, the picker falls back to hub instead of
  attaching you to an arbitrary window with a menu-less status bar.
- **Hook state writes are atomic** (temp file + rename), so the picker never
  reads a half-written `working`/`waiting` state and overlapping hooks can't
  corrupt it.
- **tmux: the scroll wheel now scrolls the pane** instead of walking a session's
  input history. tmux defaults to `mouse off`, which turns the wheel into arrow
  keys sent to the program; the picker now sets `mouse on` on its own dedicated
  socket (your `~/.tmux.conf` is untouched).
- **Control characters in a session's `cwd` are now stripped** in every metadata
  parser (jq/python/awk), matching the title handling — a crafted or corrupted
  transcript can no longer emit an escape sequence to the screen or break the
  `--list` TSV through the project column.
- **Empty `aiTitle` falls back to the last prompt consistently.** The jq path
  treated a present-but-empty `"aiTitle":""` as a value (so a session showed
  `(untitled)` under jq but the real prompt under python/awk); all three parsers
  now select only a non-empty string.
- **Delete is safer.** Liveness is re-checked at the moment of deletion (not from
  the possibly-stale list snapshot), so a session resumed since the last load
  can't be deleted mid-run; and a failed delete is now reported instead of
  silently looking like success.
- **Docs corrected.** The safety notes no longer claim the tool "never deletes"
  anything under `~/.claude`; they now state that browsing is read-only while the
  explicit `d` action permanently removes a transcript after confirmation.
- **Status bar never wraps the frame.** Spacing now uses display width (columns)
  throughout — a character count under-measured a CJK filter query (1 char = 2
  columns) and could push the bar past the frame; the shown query is bounded to
  20 columns; and the key hints degrade to a compact set (or drop out) when the
  attention badge and position need the room, so the bar fits at any width.

### Engineering
- Added a `shellcheck` gate to `test/run-all.sh` (runs if installed, skips
  cleanly if not) with a documented, minimal exclude list; the whole tree is
  clean. Removed dead locals/variables it surfaced.
- Shared `csp_pause_notice` helper for the "show a message, wait for Enter"
  moments (session still running, delete failed, tmux not installed), so they
  toggle terminal state identically. Dropped the now-unused `csp_lives` array
  (delete re-checks liveness live; the marker uses a local). `test/render.bats`
  gained status-bar-overflow coverage and `sessions.bats` gained cwd-sanitize,
  empty-title, and control-only-cwd regression tests, plus tmux dedup /
  brand-new-session and atomic-state-write coverage, plus full-path/full-title
  filter matching, a narrow-frame badge+filter overflow guard, and orphaned-menu
  recovery, plus a status-bar right-block boundary (CSP_INNER-exact) case, an
  open-tmux-window delete guard, a delete confirm-race action test, installer
  control-char JSON validity, and an unrelated-tmux hook-isolation test.
- tmux ownership is proven by a server-global `@csp_owner` marker, not just the
  socket name — so a user's unrelated tmux whose socket happens to share the
  basename (a different path) is never mistaken for the picker's, and the hook
  never tags a window in it. Added same-basename-different-path and
  real-tagged-window regression tests, plus a parameterized 0x01–0x1F JSON
  round-trip. Test suite grew to 215.
- New pure, unit-tested helpers in `lib/core.sh`: `csp_filter_indices`,
  `csp_next_attention`, `csp_count_attention`. A shared `csp_prompt_line` now
  backs both the delete confirmation and the filter query (one home for the
  raw↔cooked terminal transition). New `test/render.bats` gives the draw layer
  its first coverage (legend fits the frame, status bar never overflows at any
  width incl. CJK filters, no-match hint). Test suite grew to 189.

## 1.1.1

### Fixed
- Validate `CSP_META_HEAD_LINES` by decimal format and significant-digit length
  before shell arithmetic, preventing oversized values from wrapping to a small
  limit on Bash 3.2.
- Stream the no-jq/no-python metadata fallback through a bounded parser instead
  of copying the complete file head into a Bash variable.
- The awk fallback now **replaces** control characters in a title with a space
  instead of deleting them, matching the jq and python readers. Previously a
  title with an embedded tab/newline rendered as `line1line2` through the
  fallback but `line1 line2` through the primary parsers, so the same session
  could show a different title depending on which tools were installed.

## 1.1.0

### Added
- `CSP_META_HEAD_LINES` environment variable — how many lines from the top of
  each session file are scanned for its title/project (default 64). Raise it if
  a future Claude Code format ever writes the title lower in the file. The value
  is normalised to a sane positive integer (non-numeric or `0` → default; very
  large values are capped).
- `CSP_TMUX_SOCKET` documented — the dedicated `tmux -L` socket name the tool
  runs on; change it in the unlikely event of a socket-name collision.

### Fixed
- The built-in (no-jq/no-python) title reader now honours `CSP_META_HEAD_LINES`
  too — previously it scanned the whole file, ignoring the limit.
- tmux mode hardening: `CSP_TMUX_SOCKET` is sanitized (a name with `,`/`/`
  previously broke the "am I inside our tmux?" check and caused a re-exec into a
  broken nested attach); the picker window launches via `env VAR=val …` so it
  works under a csh/tcsh default-shell; `TMUX_TMPDIR` is forwarded across the
  re-exec.

## 1.0.0

First tagged release. A zero-dependency, keyboard-driven menu for listing and
resuming Claude Code sessions from a single terminal.

### Features
- **Session menu** — reads Claude Code's own store
  (`~/.claude/projects/**/*.jsonl`), newest first, showing each session's title
  (Claude's `aiTitle`, else your last prompt), project path, and last-active age.
- **Resume / new / delete** — `Enter` resumes the selected session, `n` starts a
  new one, `d` deletes a session's transcript (with confirmation; never a
  running one).
- **Two backends, chosen with `t` (remembered):**
  - **hub** (default, no dependencies) — one session at a time in the terminal;
    quitting returns you to the menu.
  - **tmux** (opt-in) — the picker lives resident in window 0 of a dedicated,
    isolated tmux socket; each session opens as another window and keeps running
    in the background. A persistent status bar lists the windows and spells out
    the `Ctrl-b` switch keys (`0`=menu, `n`/`p`=switch, `w`=list, `d`=detach).
    `CSP_BACKEND=hub|tmux` forces a mode for one run.
- **Status markers** — `●` (green) working, `✳` (yellow) stopped and wants you.
  Driven by optional Claude Code hooks (`hooks/csp-hook.sh`); a reconciler shows
  `✳` when a session was left "working" but its process is gone (crash/kill).
- **Framed TUI** — bordered panel, reverse-video selection, scrolling viewport,
  and correct column alignment for mixed English/CJK titles.
- `--version` / `--help` flags.

### Engineering
- Pure logic (`lib/core.sh`) separated from disk/process I/O (`lib/sessions.sh`)
  and session execution (`lib/backend.sh`); the entrypoint only wires input →
  logic → drawing.
- Bash 3.2 compatible (macOS system bash); JSON parsing degrades jq → python3 →
  built-in reader, so it runs on a bare machine.
- Terminal always restored on every exit path (cursor, alt-screen, mouse mode,
  saved `stty`), trap installed before raw mode; interrupts route to one clean
  handler.
- Flicker-free single-write rendering with cached chrome and precomputed rows;
  session titles parsed from the file head to keep startup fast on multi-MB
  logs.
- tmux runs on a dedicated socket so it never touches your `~/.tmux.conf` or
  other tmux sessions.
- Shell-injection-safe: paths/ids handed to tmux are quoted; window labels and
  session names are sanitized.
- ~150 `bats` tests (pure logic, session parsing, backends, key decoding,
  install/uninstall, preferences, hooks, and real-tmux integration).

### Install / uninstall
- `install.sh` symlinks the command into `~/.local/bin` (never copies), offers
  optional tmux, and prints — but never applies — the hook snippet. `uninstall.sh`
  removes only its own symlink and never touches your `~/.claude` data.
