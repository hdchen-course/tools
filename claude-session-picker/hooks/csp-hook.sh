#!/usr/bin/env bash
# =============================================================================
# csp-hook.sh — records a session's state so the picker can show ● vs ✳.
#
# WHAT THIS IS (plain language):
#   Claude Code can run a small script ("hook") at certain moments — when you
#   submit a prompt, and when Claude stops. This script is that hook. Its only
#   job is to write one tiny file saying whether the session is "working" or
#   "waiting" for you, which the picker reads to choose the marker next to each
#   session (● working, ✳ waiting for you).
#
# HOW IT'S CALLED:
#   Claude Code invokes it with a STATE argument and feeds the hook a JSON blob
#   on stdin that contains the session id. So it's wired up as, e.g.:
#       UserPromptSubmit → csp-hook.sh working
#       Stop            → csp-hook.sh waiting
#       Notification    → csp-hook.sh waiting
#
# SAFETY:
#   It is best-effort and must NEVER interfere with your Claude session: every
#   step is guarded, it always exits 0, and it writes nothing but its own tiny
#   state file. If it can't figure out the session id, it just does nothing.
# =============================================================================

# Resolve our own location (following symlinks) to source the shared library
# that knows where/how to write state — the SAME code the picker reads.
csp_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$csp_self" ]; do
  t=$(readlink "$csp_self")
  case "$t" in /*) csp_self="$t" ;; *) csp_self="$(dirname "$csp_self")/$t" ;; esac
done
CSP_ROOT="$(cd "$(dirname "$csp_self")/.." && pwd)"

# Source only what we need. If it's missing for any reason, bail quietly.
# shellcheck source=../lib/core.sh
. "$CSP_ROOT/lib/core.sh" 2>/dev/null || exit 0
# shellcheck source=../lib/sessions.sh
. "$CSP_ROOT/lib/sessions.sh" 2>/dev/null || exit 0
# backend.sh gives us csp_inside_tmux (to tag ONLY our own tmux window below) and
# the CSP_TMUX_SOCKET it keys off. Best-effort: if it can't load we simply skip
# the tagging step later.
# shellcheck source=../lib/backend.sh
. "$CSP_ROOT/lib/backend.sh" 2>/dev/null || true

state="${1:-}"
case "$state" in working|waiting) ;; *) exit 0 ;; esac   # only valid states

# Read the hook payload from stdin and pull out the session id. Claude Code
# sends JSON like {"session_id":"...","..."}. We reuse the same jq→python3→grep
# fallback style the tool uses elsewhere, all best-effort.
#
# We read only the first 64KB of stdin: the session id is always near the front,
# and slurping a huge pasted-prompt payload into a shell variable would add real
# latency to every turn (the hook blocks the prompt while it runs). A truncated
# object just makes jq/python fail and fall through to the grep, which is fine.
payload=$(head -c 65536 2>/dev/null)
id=""
if command -v jq >/dev/null 2>&1; then
  # `strings` guards against a non-string session_id (null/number/object): only
  # a real string value is emitted, so we never turn `null` into the text "null".
  id=$(printf '%s' "$payload" | jq -r '.session_id | strings // empty' 2>/dev/null)
fi
if [ -z "$id" ] && command -v python3 >/dev/null 2>&1; then
  id=$(printf '%s' "$payload" | python3 -c 'import sys,json
try:
    v = json.load(sys.stdin).get("session_id")
    print(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null)
fi
if [ -z "$id" ]; then
  # Last-resort: grep the id out of the raw JSON.
  id=$(printf '%s' "$payload" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

# Final guard: accept only a plain identifier — letters, digits, dash,
# underscore. Real Claude session ids (hex + dashes) pass; anything with a
# slash, dot, space, quote or shell metacharacter (a stray object rendered to
# text, a mangled payload, a path-traversal attempt) is rejected, so we never
# create a bogus or unsafe state file. csp_state_file also sanitises, but a
# clean id means the file is named exactly after the session.
case "$id" in
  ''|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

csp_write_state "$id" "$state"

# If this Claude is running inside the PICKER'S OWN tmux (its dedicated socket),
# tag the current window with its session id. That lets the picker dedup a
# session started with `n` — a bare `claude` with no `--resume <id>` to
# recognise — so a later Enter switches to this window instead of opening a
# second copy, and lets the delete guard treat it as in-use.
#
# We gate on csp_inside_tmux (true only when $TMUX's socket is OUR CSP_TMUX_SOCKET)
# so we NEVER touch a window in the user's own, unrelated tmux — writing a
# @csp_sid option there would pollute their session and could clobber a same-named
# user option. Inside our socket the ambient $TMUX targets exactly this window, so
# no -t guessing is needed. Fully best-effort and silent.
if command -v tmux >/dev/null 2>&1 \
   && command -v csp_inside_tmux >/dev/null 2>&1 && csp_inside_tmux; then
  tmux set-option -w '@csp_sid' "$id" >/dev/null 2>&1 || true
fi
exit 0
