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

- `mode: hub · one session at a time, quit to return here` — the session opens
  **in this terminal**. Other sessions are stopped (safely saved on disk). When
  you quit Claude you come back to this menu.
- `mode: tmux · Enter opens a session in its own window · switch with Ctrl-b n/p,
  menu = Ctrl-b 0` — the session opens in its **own tmux window** and any sessions
  you already opened keep running in the background. This menu stays open in
  window 0; `Ctrl-b` then `0` brings you back to it. See
  [the tmux walk-through](#walk-through-the-same-three-sessions-in-tmux-mode).

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

- Only ↑ and ↓ are understood as arrows. ← and → do **nothing** — a stray press
  won't quit. Use `j` and `k` to move.
- `n` starts the new session in the directory you were in when you launched the
  picker — not the directory of the highlighted row. If you want a new session in
  a specific project, `cd` there first, then run the picker. (In tmux mode, where
  the picker stays resident, `n` uses the directory of whichever terminal you
  most recently re-attached from.)
- In tmux mode, pressing `Enter` on a session that's **already open** in a window
  switches you to that window instead of starting a second copy.

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

You don't configure anything. Press `t` in the menu to turn tmux mode on (or
start with `CSP_BACKEND=tmux claude-session-picker`).

**The one idea to understand: the menu stays open.** In tmux mode the picker
moves itself *inside* a tmux session named `claude-sessions` and sits there as
window 0 — your home base. Sessions you open become windows 1, 2, 3… and keep
running when you look away. The menu is always one `Ctrl-b 0` away.

1. **Turn on tmux mode.** Press `t`. The screen redraws and a **status bar
   appears along the bottom** — that's how you know you're now inside tmux. The
   menu itself looks the same, but its mode line now mentions `mode: tmux`.
2. **Work on the refactor.** Move to *Refactor the parser*, press `Enter`. It
   opens in a new window and you're in Claude. Give it a long task.
3. **Go back to the menu — press `Ctrl-b` then `0`.** The refactor keeps running;
   you're looking at the menu again. (Window 0 is the menu — that's what the `0`
   means, and the status bar reminds you.)
4. **Open the second session.** Pick *Investigate flaky integration test*,
   `Enter`. Its own window. The refactor is **still running**.
5. **Same for the doc review.** Three sessions alive, plus the menu. The status
   bar at the bottom lists them all, with the one you're in highlighted, and
   spells out the keys on the right:

   ```
    Claude sessions   0 picker   1 tools   2 service   3 docs    Ctrl-b then: n/p=switch  0=menu  w=list  d=detach
   ```

6. **Move between them.** `Ctrl-b` then `n` (next) or `p` (previous) steps
   through the windows; `Ctrl-b w` shows a list you can pick from; `Ctrl-b` then
   a number jumps straight to that window — the numbers are the ones in the
   status bar.
7. **Finish a session for good.** `/exit` inside it. That window closes and tmux
   drops you on a neighbouring one. Press `Ctrl-b 0` to get back to the menu.
8. **Stop for the day, but leave everything running.** `Ctrl-b` then `d`
   (detach). You get your shell back; every Claude keeps working.
9. **Come back.** Run `claude-session-picker` again — it reattaches to the same
   `claude-sessions` with everything as you left it. (`tmux attach -t
   claude-sessions` does the same thing.)

**About `Ctrl-b`: it is a prefix, and that's why it seems to "do nothing".**
Press and release `Ctrl-b`, then press the second key. In between, the screen
looks exactly the same whether or not tmux heard you — there is no flash, no
message. That's normal tmux behaviour, not a fault. The always-visible reminder
on the right of the status bar is there so you never have to guess what the
second key should be.

The picker sets up that status bar on *its own tmux session only* — your
`~/.tmux.conf` is never modified. It deliberately adds **no** prefix-free
shortcuts (like plain `F1`): in tmux those are server-global, so they would steal
that key from Claude Code and any editor running inside every window.

**These keys are tmux's own, not this tool's**, so they work the same in any tmux
you ever use: `Ctrl-b 0` (window 0 = the menu), `Ctrl-b n` / `p`
(next/previous), `Ctrl-b w` (window list), `Ctrl-b d` (detach).

### Quitting everything

| I want to… | Do this |
|---|---|
| leave the menu but keep sessions running | `Ctrl-b n`, or `Ctrl-b` then a number — just switch away |
| get my shell back, everything still running | `Ctrl-b` then `d` |
| close one session | `/exit` inside it |
| shut down absolutely everything | `tmux kill-session -t claude-sessions` |

Pressing `q` in the menu, **while other sessions are still open**, detaches the
whole tmux client instead of closing the menu — everything keeps running in the
background and you get your shell back (the same as `Ctrl-b d`). Run
`claude-session-picker` again to re-attach to the same menu. If the menu is the
*only* window left, `q` just quits normally. (This is decided by whether you're
physically inside the tmux session, so it behaves the same even if you've toggled
back to hub mode with `t` without leaving.)

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

Turning tmux **on** does something visible: the picker immediately re-launches
itself inside the `claude-sessions` tmux session, so the screen redraws and a
status bar appears at the bottom. That's expected — it's what lets the menu stay
open in window 0 while your sessions run in windows 1, 2, 3…. From then on
`Ctrl-b 0` returns to the menu and `Ctrl-b n`/`p` move between sessions. Toggle
back to hub with `t` any time (that leaves the tmux session running; detach or
kill it yourself).

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
Install `tmux`, then press `t` in the menu (or start with
`CSP_BACKEND=tmux claude-session-picker`). Installing tmux alone doesn't change
the default — you opt in. Each session then gets its own tmux window and they all
keep running at once.

**In tmux mode, how do I switch to another session?**
Two ways. Press `Ctrl-b` then `0` to get back to the menu, then `Enter` on the one
you want. Or step straight between already-open sessions with `Ctrl-b n` (next)
and `Ctrl-b p` (previous) — the status bar at the bottom of the screen lists them
all so you can see where you're going. `Ctrl-b w` gives you a pick-from-a-list
view.

**I pressed `Ctrl-b` and nothing happened.**
That's how `Ctrl-b` works, and it's the single most confusing thing about tmux:
it's a *prefix*, not a command. tmux is now waiting for a second key and gives no
visible sign of it — the screen looks identical whether it heard you or not. Press
the second key and it acts: `0` for the menu, `n`/`p` for next/previous session,
`w` for a list, `d` to detach. The reminder on the right of the status bar
(`Ctrl-b then: n/p=switch  0=menu  w=list  d=detach`) is there precisely so you
don't have to remember which second key to press.

**How do I get back to the menu?**
`Ctrl-b` then `0`. The menu never closed — it's running in window 0 the whole
time, which is what the `0` refers to.

**I `/exit`ed a session and now I'm somewhere unexpected.**
When a session's window closes, tmux moves you to a neighbouring window, which
might be another session or the menu. Press `Ctrl-b 0` to go to the menu
deliberately. If you `/exit` your *last* session and the menu is gone too, tmux
ends and you're back at your shell.

**Is any of my data sent anywhere?**
No. The tool makes no network calls whatsoever. It reads files that already exist
on your machine under `~/.claude` and launches the `claude` command you already
have. No conversation text, no titles, no telemetry leaves your computer.

**Does it modify or delete my sessions?**
Only if you ask it to. Listing, filtering, opening, and resuming just *read*
`~/.claude`. The one action that writes is **delete** (`d`/`x`): it permanently
removes the selected session's transcript, but only after you confirm, and never
a session that is currently running. Nothing else under `~/.claude` is ever
touched, and uninstalling removes one symlink and leaves every session intact.

**How do I switch modes?**
Press `t` in the menu — it's remembered next time. Or put `CSP_BACKEND=hub` /
`CSP_BACKEND=tmux` in front of the command for one run. See
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

**`Ctrl-b 0` says "can't find window: 0" and doesn't reach the menu**
You almost certainly have `set -g base-index 1` in your `~/.tmux.conf` (it's a
very common setting). That makes tmux number windows from 1, so the menu is
window **1**, not 0 — but the status bar still says `0=menu`. Use `Ctrl-b 1`
instead, or `Ctrl-b w` and pick `picker` from the list. Whatever the status bar
lists next to `picker` is the right number.

**`Ctrl-b` then a number took me to the wrong session**
Window numbers aren't positions in the menu, and they aren't reused when a session
closes — so after you `/exit` something the numbering can have gaps, and a number
you remember may now point elsewhere. Read the number off the status bar each time
rather than memorising it, or use `Ctrl-b w` to pick by name.

**I have a lot of sessions open and can't keep track**
`Ctrl-b w` gives a scrollable list of every window with names, which works no
matter how many you have. `Ctrl-b 0` (the menu) then `Enter` is always available
too.

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

**The left/right arrow keys don't do anything**
Only ↑ and ↓ move the cursor; ← and → are deliberately ignored so a stray press
can't do anything surprising. Use `j` / `k` or ↑ / ↓.

**Titles with Chinese or other non-Latin characters look misaligned**
Titles are cut by character count, never mid-character, so nothing is corrupted —
but wide characters take two columns in most terminals, so a row can look shorter
than its neighbours. It's cosmetic only.

**Still stuck?** Run the test suite — if it passes, the tool itself is healthy and
the problem is in the environment (`PATH`, `claude`, or the terminal):

```sh
./test/run-all.sh
```
