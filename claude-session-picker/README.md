# Claude Session Picker

A tiny, keyboard-driven menu for jumping back into any of your past **Claude
Code** sessions — from one terminal, with **nothing to install**.

Claude Code already saves every conversation you have. Over time you accumulate
dozens of them across different projects, and the usual way to "not lose" one is
to keep its terminal tab open forever. This tool reads Claude's own session
files and shows them all in one menu — newest first, with a title, the project
it belongs to, and how long ago it was active — so any session is one keypress
away. A `●` marks a session Claude is working in; a `✳` marks one that has
stopped and wants your input (see [Status markers](#status-markers)).

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

## Why not just `claude --resume`?

Claude Code has its own `--resume` picker, and for a quick "reopen the last thing
in *this* folder" it's perfect. This tool is for the other situation — when your
sessions have piled up across many projects and you want one place to see and
manage them all:

| | `claude --resume` | claude-session-picker |
|---|---|---|
| Scope | sessions for the **current directory** | **every** session, **all** projects, in one list |
| Sees at a glance | title + age | title + **project** + age, plus **●/✳ status** (which sessions are working vs waiting for you) |
| Start a new session | separate command | `n`, right from the list |
| Delete an old session | not from the picker | `d` (with confirmation) |
| Run several at once | one at a time | optional **tmux mode** — each session in its own window, all live |
| Jump straight in | pick, then it opens | same — `Enter` resumes into the session's original directory |

If you only ever work in one repo, the built-in picker is enough. If you juggle
many, this gives you the cross-project overview it doesn't.

## Two modes: hub and tmux

The picker can *run* a session in one of two ways. **hub is the default
everywhere**; tmux is an opt-in for people who want several sessions running at
once. The header line always tells you which mode you're in.

| | **hub** (default) | **tmux** (opt-in) |
|---|---|---|
| Needs installed | nothing | the `tmux` command |
| When it is used | **always, unless you ask for tmux** | only when you ask for it (`t` key or `CSP_BACKEND=tmux`) |
| Where a session opens | in your current terminal | in its own tmux *window* |
| Where the menu lives | this terminal; it's hidden while a session runs | **window 0, always running** |
| While you use session A | B, C… are **stopped** (saved on disk) | B, C… keep **running** in the background |
| Quitting the session | **returns you to the picker menu** | the window closes; you land on another window |
| Switching | quit the session → pick the next from the menu | `Ctrl-b 0` back to the menu, `Ctrl-b n`/`p` between sessions |
| Good for | the common case: browse and resume, one at a time | several agents making progress in parallel |

**Why hub is the default even if you have tmux.** Auto-picking tmux just because
it happens to be installed is surprising: it moves your shell into a tmux client
you didn't ask for, and every tmux keybinding it needs is one more thing to know.
Hub gives the same predictable "quit a session → back to the menu → pick the
next" flow on every machine, needs nothing installed, and can't leave your
terminal in a strange state. Nothing is lost when you switch: Claude saves every
session to disk as you go, so reopening picks up exactly where you left off.

**Want true concurrency?** Install `tmux` and opt in — press `t` in the menu, or
start with `CSP_BACKEND=tmux`. See [tmux mode in detail](#tmux-mode-in-detail)
for what changes on screen.

The easiest way to switch is the **`t` key inside the menu** — it flips between
hub and tmux and remembers your choice for next time. You can also force a mode
for a single run with the `CSP_BACKEND` environment variable (it takes
precedence over the remembered choice):

```sh
claude-session-picker                     # your saved choice, or hub by default
CSP_BACKEND=tmux claude-session-picker    # force concurrent tmux windows this run
CSP_BACKEND=hub  claude-session-picker    # force hub this run
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

Installing tmux does **not** change the picker's default — it stays in hub mode
so nothing about your normal flow changes. To actually use concurrent windows,
press `t` in the menu (remembered next time), or opt in per run with
`CSP_BACKEND=tmux claude-session-picker`.

### tmux mode in detail

The important thing to know: in tmux mode **the menu never goes away.** The
picker moves itself inside a tmux session called `claude-sessions` and lives
there as window 0, your home base. Each session you open becomes another window
(1, 2, 3…) and keeps running when you leave it.

```
 Claude sessions   0 picker   1 tools   2 service   Ctrl-b then: n/p=switch  0=menu  w=list  d=detach
 ^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 you're in tmux    every open session, current one  the keys that move you around —
                   highlighted                      always on screen, nothing to memorise
```

That bar along the bottom of the screen is tmux's, not the picker's — it is your
map of what's open **and** your reminder of the keys.

| To do this | Press |
|---|---|
| go back to the menu (window 0) | `Ctrl-b` then `0` |
| next / previous session | `Ctrl-b` then `n` / `p` |
| pick from a list of windows | `Ctrl-b` then `w` |
| jump to a specific window | `Ctrl-b` then its number from the status bar |
| leave everything running and get your shell back | `Ctrl-b` then `d` (detach) |
| come back later | `claude-session-picker` again, or `tmux attach -t claude-sessions` |

The mouse works too: the scroll wheel scrolls the current pane (and clicking a
window in the status bar selects it). This is on because tmux otherwise turns
the wheel into arrow-key presses — which, inside a session, just walks its input
history instead of scrolling. It's set only on the picker's own tmux socket, so
your `~/.tmux.conf` is untouched.

**How `Ctrl-b` works.** It's a *prefix*, not a command: press and release
`Ctrl-b`, then press the second key. Nothing visible happens in between — that's
normal, and it's why the status bar spells out the second key for you.

The picker sets up that status bar on its own tmux session only; your
`~/.tmux.conf` is never modified. It deliberately adds **no** prefix-free key
bindings, because those are server-global in tmux and would steal the key from
Claude Code (and any editor) running inside every window.

The first time you start in tmux mode the screen will flash and you'll notice the
new status bar at the bottom: that's the picker re-launching itself inside tmux.
This is expected and happens once per session.

**Quitting.** `q` in the menu, **while other sessions are still open**, detaches
the whole tmux client — every session keeps running in the background and you get
your shell back (the same as `Ctrl-b d`); run `claude-session-picker` again to
re-attach to the same menu. If the menu is the only window left, `q` just quits.
(This is decided by whether you're physically inside the tmux session, so it's
the same even if you've toggled back to hub with `t` without leaving.) To shut
everything down, quit each Claude, or `tmux kill-session -t claude-sessions`.

## Usage

```sh
claude-session-picker
```

| Key | Action |
|-----|--------|
| `j` / `k`, or ↓ / ↑ | move the cursor (wraps around at both ends) |
| `g` / `G` | jump to the first / last session |
| `/` | **filter** — type a word from a title or project to narrow the list; empty input (just Enter) shows everything again |
| `Enter` | open the selected session |
| `*` | jump to the next session that **needs you** (`✳`), wrapping around |
| `n` | start a **new** session in the directory you launched the picker from (in tmux mode, the directory you last re-attached from) |
| `d` or `x` | **delete** the selected session's history (asks you to confirm first) |
| `t` | **toggle** between hub and tmux mode (see below); the choice is remembered. Turning tmux **on** re-launches the picker inside tmux |
| `R` or `l` | reload the list |
| `q` or `Esc` | quit |

Only ↑ and ↓ are recognised as arrows; ← and → do nothing (a stray press won't
quit). Just `q` or `Esc` quits.

**Filtering a long list.** Press `/`, type any part of a session's title or
project path, and Enter — the list narrows to the matches (case-insensitive;
中文 works too). The status bar shows the active query and how many of the total
are showing (e.g. `/parser  1/2 of 42`). Filter again with a different word, or
press `/` then Enter on an empty line to clear it. The filter never changes your
sessions — it only chooses which rows are on screen.

Press `t` to switch modes right from the menu — no need to remember an
environment variable. If tmux isn't installed it tells you so instead of
switching. Your choice is saved, so next time the picker starts in the same
mode. Note that switching tmux **on** immediately re-launches the picker inside
the `claude-sessions` tmux session (the screen redraws with a status bar along
the bottom); see [tmux mode in detail](#tmux-mode-in-detail).

Opening a session `cd`s into that session's original project directory first (if
it still exists) and runs `claude --resume <id>`, so you land where you left off.
What happens next depends on the mode: hub returns you to the menu when you quit
Claude; tmux opens the session in a new window and switches you to it, while the
menu keeps running in window 0 — press `Ctrl-b` then `0` to come back to it. (If
that session is already open in a tmux window, `Enter` just switches you to it
rather than starting a second copy.)

The list scrolls. However many sessions you have, only the rows that fit on your
terminal are drawn, the highlighted row is always kept in view, and a
`-- 3/42 --` hint at the bottom shows where you are.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CSP_BACKEND` | *(saved choice, else `hub`)* | force `hub` or `tmux` for this run; overrides the remembered `t` choice |
| `CSP_TMUX_SOCKET` | `claude-sessions` | name of the dedicated tmux socket (`tmux -L`) the tool runs on |
| `CSP_TMUX_SESSION` | `claude-sessions` | name of the tmux session that holds the windows |
| `CSP_CLAUDE_DIR` | `~/.claude` | where to look for Claude's data (used by the tests) |
| `CSP_PREF_FILE` | `~/.config/claude-session-picker/backend` | where the `t` toggle saves your mode choice |
| `CSP_STATE_DIR` | `~/.local/state/claude-session-picker/state` | where the hooks record each session's ●/✳ state |
| `CSP_META_HEAD_LINES` | `64` | how many lines from the top of each session file are scanned for its title/project (positive decimal, capped at 100000; raise it if a future Claude format hides the title lower down) |

tmux mode runs on its own tmux socket named `claude-sessions` (via `tmux -L`), so
it never touches your normal tmux server or `~/.tmux.conf`. In the unlikely event
another tool already uses a socket by that name, set `CSP_TMUX_SOCKET` to
something else.

## Status markers

Next to each session:

| Marker | Meaning |
|:------:|---------|
| `●` (green) | Claude is **working** in this session |
| `✳` (yellow) | Claude has **stopped and wants your input** — and you haven't opened it yet |
| *(blank)* | idle and already seen, or no live Claude |

Opening a session clears its `✳` (you've now looked at it).

**Without any setup**, `●` simply means "a Claude process is running this
session" and there's no `✳` — it still works, just with less detail. To get the
full ●/✳ distinction, register two tiny **hooks** in your Claude Code
`settings.json` (the installer prints the exact snippet with your paths):

```json
"hooks": {
  "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh working" } ] } ],
  "Stop":             [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh waiting" } ] } ],
  "Notification":     [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh waiting" } ] } ]
}
```

The hooks write a tiny local state file per session — **nothing is sent
anywhere**. And because hooks don't always fire (a crashed or killed Claude
never sends "Stop"), the picker includes a **reconciler**: if a session was last
marked "working" but no Claude process is running it any more, it's shown as `✳`
(needs attention) instead of a stuck `●`. That's what keeps the markers honest
even when Claude dies unexpectedly.

## Uninstall

```sh
./uninstall.sh              # or: ./uninstall.sh --prefix DIR
```

Removes the command symlink **only if it still points back into this repo**, so
it can never delete an unrelated file that happens to share the name.
Uninstalling never touches your Claude data under `~/.claude`.

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
                            detects which sessions are live. It also owns the one
                            write path — deleting a session's transcript (the `d`
                            action), guarded to stay within the projects dir.
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
- **Read-only while browsing.** Listing, filtering, opening, and resuming only
  *read* `~/.claude` — none of them writes or deletes anything there. The one
  exception is the explicit **delete** action (`d`/`x`), which permanently
  removes the selected session's transcript **after you confirm**; it never
  touches anything else, and never a session that is currently running.
  Uninstalling leaves all your sessions untouched.
- **Your terminal is always restored** — the cursor and your `stty` settings are
  put back on every exit path (normal quit, `Ctrl-C`, `TERM`, or an unexpected
  error), via a trap installed *before* the terminal is ever put into raw mode.
- **Bounded by design.** Every loop terminates, the session list is capped, and
  every displayed string is length-limited, so hundreds of sessions or one huge
  session file can't exhaust memory.
- **No shell injection.** Paths and ids handed to tmux are single-quoted with
  embedded quotes escaped, which is covered by a test.

## Version & changes

Check your installed build with `claude-session-picker --version`. Because the
install is a symlink updated in place by `git pull`, that number (and
[CHANGELOG.md](CHANGELOG.md)) is how you tell what you're running.

## License

MIT — see [LICENSE](LICENSE). This is an unofficial community tool and is **not
affiliated with or endorsed by Anthropic**.
