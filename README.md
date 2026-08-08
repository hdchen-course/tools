# Claude Session Picker

A tiny, keyboard-driven menu for jumping back into any of your past **Claude
Code** sessions — from one terminal, with **nothing to install**.

Claude Code already saves every conversation you have. Over time you accumulate
dozens of them across different projects, and the usual way to "not lose" one is
to keep its terminal tab open forever. This tool reads Claude's own session
files and shows them all in one menu — newest first, with a title, the project
it belongs to, and how long ago it was active — so any session is one keypress
away. A `●` marks the sessions that have a live Claude running right now.

```
Claude Session Picker   ● = running    mode: hub (one at a time)
(j/k move   Enter open   n new session   R reload   q quit)
>   Refactor the parser                        EnglishTraining/tools   just now
  ● Investigate flaky integration test         workplace/service       25m ago
    Review onboarding requirement doc          workplace/docs          2h ago
    Clean up disk space                        workplace/analysis      3d ago
-- 1/42 --
```

New here? The step-by-step user manual is at **[docs/MANUAL.md](docs/MANUAL.md)**.

## Two modes: hub and tmux

The picker can *run* a session in one of two ways. It picks one for you at
startup and prints which one on the header line, so you always know what
pressing `Enter` is about to do.

| | **hub** | **tmux** |
|---|---|---|
| Needs installed | nothing | the `tmux` command |
| When it is used | whenever `tmux` is not installed | automatically, whenever `tmux` **is** installed |
| Where a session opens | in your current terminal | in its own tmux *window* |
| While you use session A | B, C… are **stopped** (saved on disk) | B, C… keep **running** in the background |
| Quitting the session | returns you to the picker menu | leaves you in tmux; other windows still live |
| Good for | a bare remote Linux host, minimal setups | several agents working at once |

**Honest note on concurrency.** Only tmux mode gives you *truly simultaneous*
sessions. Hub mode is one-at-a-time **by design**: it hands the whole terminal to
one Claude and takes it back when that Claude exits, which is why it needs no
extra software and cannot leave your terminal in a strange state. Nothing is lost
when you switch — Claude persists every session to disk as you go, so reopening
picks up exactly where you left off. If you want several agents making progress
in parallel, install `tmux` (see [Optional: tmux](#optional-tmux)).

Force a mode with the `CSP_BACKEND` environment variable:

```sh
CSP_BACKEND=hub  claude-session-picker    # one at a time, even if tmux exists
CSP_BACKEND=tmux claude-session-picker    # windows that keep running
```

Forcing `tmux` on a machine without the `tmux` command falls back to `hub`
rather than failing — the picker never promises a mode it cannot deliver.

## Requirements

- **bash 3.2+** — the version that ships with macOS is fine; every Linux has it.
- **Claude Code** — the `claude` command. The picker refuses to start without it
  and tells you where to get it.
- Optional: **`jq`** or **`python3`** read session titles slightly faster. With
  neither, a built-in pure-bash reader is used, so a completely bare machine
  still works.
- Optional: **`tmux`** — only if you want concurrent sessions.

## Install

```sh
git clone <this-repo-url> claude-session-picker
cd claude-session-picker
./install.sh
```

`install.sh` symlinks (never copies) the `claude-session-picker` command into
`~/.local/bin`, so a later `git pull` updates your installed copy automatically.
It changes nothing else, is safe to re-run, and is fully undone by
`uninstall.sh`.

| Flag | Effect |
|------|--------|
| `--prefix DIR` | install the symlink into `DIR` instead of `~/.local/bin` |
| `--force` | overwrite an existing file/symlink at the target |
| `-h`, `--help` | print usage |

Make sure your prefix is on your `PATH` — the installer warns you and prints the
exact line to add if it isn't.

Optional convenience — bind it to a key so it's always one chord away. For zsh,
add to `~/.zshrc`:

```zsh
bindkey -s '^S' 'claude-session-picker\n'   # Ctrl-S opens the picker
```

### Optional: tmux

The installer does **not** install `tmux` and does not need it. Add it yourself
only if you want several sessions running at the same time:

```sh
brew install tmux            # macOS
sudo apt install tmux        # Debian/Ubuntu
sudo yum install tmux        # RHEL / CentOS / Fedora
```

The next time you start the picker it will notice `tmux` and switch to tmux mode
by itself. Nothing else changes; use `CSP_BACKEND=hub` any time you want the
simple one-at-a-time behaviour back.

## Usage

```sh
claude-session-picker
```

| Key | Action |
|-----|--------|
| `j` / `k`, or ↓ / ↑ | move the cursor (wraps around at both ends) |
| `g` / `G` | jump to the first / last session |
| `Enter` | open the selected session |
| `n` | start a **new** session in the directory you launched the picker from |
| `R` or `l` | reload the list |
| `q` or `Esc` | quit |

Only ↑ and ↓ are recognised as arrows; **← and → quit the picker**, so use `j`
and `k` if that bites you.

Opening a session `cd`s into that session's original project directory first (if
it still exists) and runs `claude --resume <id>`, so you land where you left off.
What happens next depends on the mode: hub returns you to the menu when you quit
Claude; tmux hands the screen over to tmux and the picker exits.

The list scrolls. However many sessions you have, only the rows that fit on your
terminal are drawn, the highlighted row is always kept in view, and a
`-- 3/42 --` hint at the bottom shows where you are.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CSP_BACKEND` | *(auto)* | force `hub` or `tmux` |
| `CSP_TMUX_SESSION` | `claude-sessions` | name of the tmux session that holds the windows |
| `CSP_CLAUDE_DIR` | `~/.claude` | where to look for Claude's data (used by the tests) |

## Uninstall

```sh
./uninstall.sh              # or: ./uninstall.sh --prefix DIR
```

Removes the command symlink **only if it still points back into this repo**, so
it can never delete an unrelated file that happens to share the name. It never
touches your Claude data under `~/.claude` — this tool only ever *read* those
files.

## How it works

```
bin/claude-session-picker   The interactive menu: input → logic → drawing. Makes
                            no decisions of its own.
lib/core.sh                 PURE logic. Text in, text out. No disk, no network,
                            no processes. Marker rules, cursor clamping, the
                            scrolling window maths, line formatting, and the
                            backend choice all live here, fully unit-tested.
lib/sessions.sh             The ONLY file that touches the outside world: reads
                            Claude's session files under ~/.claude, pulls each
                            session's title / project / last-active time, and
                            detects which sessions are live.
lib/backend.sh              The two ways to RUN a session: hub (foreground, one
                            at a time) and tmux (a window each, concurrent).
install.sh / uninstall.sh   One-command setup and clean removal.
test/core.bats              Unit tests for the pure logic (no files, no claude).
test/sessions.bats          Tests the reader against a FAKE ~/.claude tree.
test/backend.bats           Tests quoting and that hub returns control, using a
                            fake `claude` on PATH. Never launches the real one.
test/run-all.sh             Runs all three suites (core + sessions + backend).
```

**Where sessions come from.** Claude Code stores each conversation at
`~/.claude/projects/<encoded-project-path>/<session-id>.jsonl` (the encoding is
just the project path with `/` turned into `-`). The picker lists those files
newest-first by modification time — that mtime is the "last active" time you see
— caps the list at 1000, reads a title from each file (Claude's own `aiTitle`,
else your last prompt, else `(untitled)`, truncated to 60 characters), and reads
the project directory from the file's `cwd` field. The project column shows the
last two path components so rows stay readable.

**Live markers.** A `●` means a `claude` process is currently running that
session, detected by scanning process arguments for `--resume <session-id>`.
It's a helpful hint, not a guarantee: a session started *without* `--resume` —
including one you start here with `n` — won't show a marker, and that never
affects anything else.

**Design split.** To change *what the tool decides* (a marker rule, how titles
are shortened, scrolling, which backend wins) edit `lib/core.sh` and its tests.
If Claude changes *how it stores sessions*, edit `lib/sessions.sh`. To change
*how a session is launched*, edit `lib/backend.sh`. Every function carries a
plain-language comment, so the codebase stays approachable even if you don't
write shell scripts.

## Running the tests

```sh
# Uses bats-core if present (brew install bats-core), else any `bats` on PATH.
./test/run-all.sh
```

The tests cover the boundaries that matter for stability: empty session lists,
out-of-range navigation, oversized and multi-byte (e.g. Chinese) titles, the
scrolling window maths, "an empty id is never live", malformed/zero-byte session
files, every branch of the backend choice, and shell-quoting of hostile paths.
Nothing in the suite launches the real `claude` or touches your real `~/.claude`.

## Safety & privacy

- **Nothing leaves your machine.** No conversation text, history, or telemetry is
  sent anywhere. The tool makes no network calls at all.
- **Read-only on your data.** It never writes to or deletes anything under
  `~/.claude`; it only reads. Uninstalling leaves your sessions untouched.
- **Your terminal is always restored** — the cursor and your `stty` settings are
  put back on every exit path (normal quit, `Ctrl-C`, `TERM`, or an unexpected
  error), via a trap installed *before* the terminal is ever put into raw mode.
- **Bounded by design.** Every loop terminates, the session list is capped, and
  every displayed string is length-limited, so hundreds of sessions or one huge
  session file can't exhaust memory.
- **No shell injection.** Paths and ids handed to tmux are single-quoted with
  embedded quotes escaped, which is covered by a test.

## License

MIT — see [LICENSE](LICENSE). This is an unofficial community tool and is **not
affiliated with or endorsed by Anthropic**.
