# Changelog

All notable changes to `claude-session-picker` are recorded here. The installed
command is a symlink updated in place by `git pull`, so this file (and the
`--version` output) is how you tell which build you're running.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/);
this project uses simple `MAJOR.MINOR.PATCH` version numbers.

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
