# Claude Session Picker — User Manual

A friendly, step-by-step guide. You do not need to know any shell scripting to
follow this. If you can open a terminal and type a command, you can use this tool.

- [Quick start](#quick-start)
- [Reading the screen](#reading-the-screen)
- [The keys](#the-keys)
- [Walk-through: juggling three sessions in hub mode](#walk-through-juggling-three-sessions-in-hub-mode)
- [Walk-through: the same three sessions in tmux mode](#walk-through-the-same-three-sessions-in-tmux-mode)
- [Switching modes](#switching-modes)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)

---

## Quick start

**1. Get the tool onto your machine and install it.**

```sh
git clone <this-repo-url> claude-session-picker
cd claude-session-picker
./install.sh
```

The installer creates a single shortcut (a symlink) at
`~/.local/bin/claude-session-picker`. It does not copy anything, does not install
other software, and does not touch your Claude data. If `~/.local/bin` isn't on
your `PATH`, the installer prints the exact line to paste into `~/.zshrc` or
`~/.bashrc` — do that, then open a new terminal window.

**2. Run it.**

```sh
claude-session-picker
```

**3. Pick a session.** Press `j` and `k` (or ↓ and ↑) to move, then `Enter`.
Claude opens in that session's original project folder, right where you left off.

**4. Get out.** Press `q` in the menu to return to your shell.

That's the whole tool. Everything below is detail.

> Tip: add `bindkey -s '^S' 'claude-session-picker\n'` to `~/.zshrc` and then
> `Ctrl-S` opens the picker from anywhere.

---

## Reading the screen

```
Claude Session Picker   ● = running    mode: hub (one at a time)
(j/k move   Enter open   n new session   R reload   q quit)
>   Refactor the parser                        EnglishTraining/tools   just now
  ● Investigate flaky integration test         workplace/service       25m ago
    Review onboarding requirement doc          workplace/docs          2h ago
    Clean up disk space                        workplace/analysis      3d ago
-- 1/42 --
```

**Line 1 — the header, including the mode.** This is the most useful line on the
screen, because it tells you what `Enter` is about to do:

- `mode: hub (one at a time)` — the session opens **in this terminal**. Other
  sessions are stopped (safely saved on disk). When you quit Claude you come back
  to this menu.
- `mode: tmux (others keep running)` — the session opens in its **own tmux
  window**, and any sessions you already opened keep running in the background.

**Line 2** is a reminder of the main keys.

**The rows** are your sessions, newest activity first. Each row has four parts:

| Part | Meaning |
|---|---|
| `›` at the start | the cursor — this is the row `Enter` will open |
| `●` (green) | Claude is **working** in this session right now |
| `✳` (yellow) | Claude **stopped and wants your input**, and you haven't opened it yet |
| a blank where a marker would be | idle and already seen, or nothing is running it — a saved session you can resume |
| the title | Claude's own summary of the conversation, or your last prompt if it hasn't made one yet |
| the project | the last two folders of the directory the session belongs to |
| the age | how long since that session last did anything (`just now`, `25m ago`, `2h ago`, `3d ago`) |

The `✳` marker only appears if you set up the optional hooks (see
[Status markers](#status-markers) below); without them you just get `●` for a
running session. Opening a session clears its `✳`.

**The last line**, `-- 1/42 --`, appears only when you have more sessions than
fit on screen. It means "the cursor is on session 1 of 42". The list scrolls by
itself and always keeps the cursor visible.

---

## The keys

| Key | What it does |
|-----|--------------|
| `j` or ↓ | move down one (from the bottom it wraps to the top) |
| `k` or ↑ | move up one (from the top it wraps to the bottom) |
| `g` | jump to the first (most recent) session |
| `G` | jump to the last (oldest) session |
| `Enter` | open the selected session |
| `n` | start a brand-new session, in the folder you ran the picker from |
| `d` or `x` | delete the selected session's transcript — asks you to confirm, and won't delete a session that's currently running |
| `t` | toggle between hub and tmux mode (concurrency on/off); your choice is remembered next time |
| `R` or `l` | reload the list (picks up new sessions and refreshes the `●` markers) |
| `q` or `Esc` | quit back to your shell |

Two small things worth knowing:

- Only ↑ and ↓ are understood as arrows. **← and → quit the picker.** If you
  reach for them out of habit, use `j` and `k` instead.
- `n` always starts the new session in the directory you were in when you
  launched the picker — not the directory of the highlighted row. If you want a
  new session in a specific project, `cd` there first, then run the picker.

---

## Walk-through: juggling three sessions in hub mode

This is what you get with no extra software installed. Say you have a refactor
in progress, a flaky test to investigate, and a doc to review.

1. **Open the picker.** `claude-session-picker`. The header says
   `mode: hub (one at a time)`.
2. **Work on the refactor.** Move to *Refactor the parser*, press `Enter`. The
   menu disappears and you are in Claude, in that project's folder, with the
   whole conversation intact.
3. **Park it.** Quit Claude the way you normally would (`/exit`, or `Ctrl-C`
   twice). You do **not** lose anything — Claude wrote the conversation to disk as
   you went. You land back in the picker menu, and the list has already been
   refreshed.
4. **Switch to the flaky test.** Move to it, press `Enter`. Same story: you're
   straight back into that conversation.
5. **Park it, switch to the doc review.** Repeat.
6. **Finish for the day.** From the menu, press `q`. You're back at your shell.

The rhythm is: *open → work → quit → menu → open something else*. One Claude is
alive at a time. That is the trade you're making for a tool that needs nothing
installed and can't wedge your terminal.

**What if you want the refactor to keep churning while you look at the test?**
Hub mode can't do that. Install `tmux` — see the next section.

---

## Walk-through: the same three sessions in tmux mode

First, install tmux once:

```sh
brew install tmux            # macOS
sudo apt install tmux        # Debian/Ubuntu
sudo yum install tmux        # RHEL / CentOS / Fedora
```

You don't configure anything. The next time you run `claude-session-picker` the
header will read `mode: tmux (others keep running)`.

1. **Open the picker.** Move to *Refactor the parser*, press `Enter`.
   The picker creates a tmux session called `claude-sessions`, opens a **window**
   inside it running your resumed conversation, and puts you in it. The picker
   itself exits — from here on, tmux owns the screen.
2. **Give Claude a long task** and let it work.
3. **Leave that window without stopping it.** Press `Ctrl-B` then `d` to detach
   from tmux entirely (Claude keeps running), or `Ctrl-B` then `n` / `p` to move
   between windows you've already opened.
4. **Open the second session.** Run `claude-session-picker` again. Pick
   *Investigate flaky integration test*, `Enter`. That gets its own window. The
   refactor is **still running** in its window.
5. **Same for the doc review.** Now you have three windows in `claude-sessions`,
   all alive.
6. **Move between them.** `Ctrl-B` then `w` shows a picker of tmux windows;
   `Ctrl-B` then a number (`0`, `1`, `2`…) jumps straight to one.
7. **Come back tomorrow.** `tmux attach -t claude-sessions` puts you back with
   everything as you left it — or just run `claude-session-picker` again and open
   anything; it reattaches to the same tmux session rather than making a new one.

The tmux keys above (`Ctrl-B` then something) are tmux's own, not this tool's.
`Ctrl-B d` (detach), `Ctrl-B w` (window list) and `Ctrl-B n`/`p` (next/previous)
are all you really need.

---

## Switching modes

The picker defaults to **hub mode everywhere** — even if you have `tmux`
installed. tmux mode is an opt-in for when you specifically want several sessions
running at once.

**The easy way — the `t` key.** While the menu is open, press `t` to flip
between hub and tmux. The top line updates to show which mode you're in, and
your choice is **saved**, so the next time you start the picker it opens in the
same mode. If `tmux` isn't installed, pressing `t` tells you so and stays in hub
rather than switching to a mode it can't run.

Once you've toggled tmux **on**, opening a session puts it in its own tmux
window; the ones you've already opened keep running in the background, and you
move between them with tmux's own keys — `Ctrl-b n` (next), `Ctrl-b p`
(previous), `Ctrl-b w` (list and pick). Toggle back to hub with `t` any time.

**The manual way — `CSP_BACKEND`.** You can also force a mode for a single run,
which overrides the remembered choice:

```sh
CSP_BACKEND=hub  claude-session-picker    # force one-at-a-time this run
CSP_BACKEND=tmux claude-session-picker    # force windows that keep running
```

To make a mode your permanent default without using `t`, put it in your shell rc:

```sh
export CSP_BACKEND=tmux      # in ~/.zshrc or ~/.bashrc
```

Asking for `tmux` on a machine that doesn't have `tmux` installed quietly gives
you `hub` instead — the tool never claims a mode it can't actually deliver, so
check the header line if you're unsure which one you got.

---

## Status markers

Each session shows one marker:

- **`●` green** — Claude is working there.
- **`✳` yellow** — Claude stopped and is waiting for you, and you haven't opened
  it since. Opening it clears the `✳`.
- **blank** — idle and already seen, or nothing running it.

**Out of the box**, you get `●` for any running session and no `✳`. To unlock
the full "who's waiting for me?" view, add three little hooks to Claude Code's
`settings.json` (usually `~/.claude/settings.json`) — the installer prints this
snippet with the real paths filled in:

```json
"hooks": {
  "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh working" } ] } ],
  "Stop":             [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh waiting" } ] } ],
  "Notification":     [ { "hooks": [ { "type": "command", "command": ".../hooks/csp-hook.sh waiting" } ] } ]
}
```

- **`UserPromptSubmit`** fires when you send a prompt → the session is marked
  working (`●`).
- **`Stop`** / **`Notification`** fire when Claude finishes or pings you → the
  session is marked waiting (`✳`).

These hooks only write a tiny file on your machine (under `CSP_STATE_DIR`);
nothing is sent anywhere.

**The reconciler (why the markers survive crashes).** Hooks don't always fire —
if Claude crashes or is killed, the "Stop" hook never runs, so a naive marker
would be stuck on `●` forever. The picker guards against this: when it sees a
session last marked "working" but no Claude process is actually running it any
more, it shows `✳` (needs attention) instead. So a died-mid-task session shows
up as "come look at me", which is exactly what you want on a machine where the
CLI sometimes crashes.

---

## FAQ

**Why is only one session running at a time?**
Because you're in hub mode, which is the no-dependencies default. Hub mode hands
your whole terminal to one Claude and takes it back when that Claude exits. That
single-tenancy is exactly why it needs nothing installed and can't leave your
terminal in a broken state. It's a deliberate trade for reliability, not a bug.

**Do I lose work when I switch sessions in hub mode?**
No. Claude Code writes every conversation to disk as it goes. Quitting a session
and reopening it later resumes the same conversation with the same history. What
you *don't* get is a task continuing to run while you're away — for that you need
tmux.

**How do I get real concurrency?**
Install `tmux`, then start the picker with `CSP_BACKEND=tmux claude-session-picker`
(installing tmux alone doesn't change the default — you opt in with that variable).
Each session then gets its own tmux window and they all keep running at once.

**Is any of my data sent anywhere?**
No. The tool makes no network calls whatsoever. It reads files that already exist
on your machine under `~/.claude` and launches the `claude` command you already
have. No conversation text, no titles, no telemetry leaves your computer.

**Does it modify or delete my sessions?**
No. It only ever *reads* `~/.claude`. Uninstalling removes one symlink and leaves
every session intact.

**How do I switch modes?**
`CSP_BACKEND=hub` or `CSP_BACKEND=tmux` in front of the command. See
[Switching modes](#switching-modes).

**Why does a session I know is open have no `●`?**
The marker is found by looking for a running process with `--resume <id>` in its
arguments. A session started *without* `--resume` — including a brand-new one you
started with `n`, or one you started by typing `claude` yourself — won't show a
marker until it's resumed later. It's a hint, not a guarantee, and its absence
never changes what the tool does.

**Why is a session titled `(untitled)`?**
Claude hadn't generated a title yet and there was no prompt to fall back on —
usually a session that was opened and closed immediately.

**Can I see more than the last two folders of a project path?**
Not in the list; it's shortened to keep rows readable. Once you open the session
you're `cd`'d into the full original path, so `pwd` will show you everything.

**Does it work on a remote Linux host / plain Linux box?**
Yes — that's a large part of why hub mode exists. bash 3.2+, the `claude` command,
and nothing else.

**What are `jq` and `python3` for?**
Reading the small pieces of JSON in each session file. If you have either, it's
used because it's faster; if you have neither, a built-in bash reader takes over
and everything still works.

**Is this an official Anthropic tool?**
No. It's an unofficial community tool, MIT licensed, not affiliated with or
endorsed by Anthropic.

---

## Troubleshooting

**`claude-session-picker: command not found`**
The install directory isn't on your `PATH`. Add this to `~/.zshrc` (zsh, the
macOS default) or `~/.bashrc`, then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Check it worked with `command -v claude-session-picker` — it should print the
symlink path.

**"The `claude` command was not found on your PATH."**
The picker won't start without Claude Code, since it has nothing to resume into.
Install Claude Code from <https://claude.com/claude-code>, then try again.

**"(no Claude sessions found under ~/.claude/projects)"**
There is nothing to list yet. Either you haven't used Claude Code on this machine,
or its data lives elsewhere. Have a conversation with `claude` first, then press
`R` in the picker to reload. (`ls ~/.claude/projects` will show you whether any
sessions exist.)

**"Already exists (use --force to overwrite)"**
Something is already at `~/.local/bin/claude-session-picker` — most likely an
older install of this same tool. Re-run `./install.sh --force` to replace it, or
`./install.sh --prefix ~/some/other/bin` to put it somewhere else.

**I installed tmux but the header still says `mode: hub`**
That's expected — hub is the default even with tmux installed. Just press `t`
in the menu to switch to tmux mode (it's remembered afterwards). If pressing `t`
says tmux isn't available, check it's really on your `PATH` with
`command -v tmux`. You can also force it with `CSP_BACKEND=tmux`; forcing tmux
without the command installed falls back to hub.

**tmux mode opened a window but Claude isn't there**
The window runs `claude --resume <id>` in the session's project folder. If that
command fails, the window closes. Try running it by hand in a normal terminal to
see the error. Also make sure `claude` is on the `PATH` your login shell uses, not
just the current terminal.

**The screen looks garbled, or rows are cut off**
Press `R` to redraw. The picker sizes itself to the terminal each time it draws,
so resizing the window and pressing `R` fixes almost everything. A very short
window shows fewer rows by design — the `-- 3/42 --` line tells you where you are.

**My terminal looks broken after a crash (no cursor, typing doesn't echo)**
This shouldn't happen: the picker restores the cursor and your terminal settings
on every exit path, including `Ctrl-C` and being killed. If some other program
left things odd, `reset` (or `stty sane` then `printf '\033[?25h'`) puts a
terminal back in order.

**The arrow keys quit the picker**
← and → aren't bound and are treated as quit. Use `j` / `k`, or ↑ / ↓, to move.

**Titles with Chinese or other non-Latin characters look misaligned**
Titles are cut by character count, never mid-character, so nothing is corrupted —
but wide characters take two columns in most terminals, so a row can look shorter
than its neighbours. It's cosmetic only.

**Still stuck?** Run the test suite — if it passes, the tool itself is healthy and
the problem is in the environment (`PATH`, `claude`, or the terminal):

```sh
./test/run-all.sh
```
