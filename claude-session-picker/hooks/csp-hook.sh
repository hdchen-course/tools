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

state="${1:-}"
case "$state" in working|waiting) ;; *) exit 0 ;; esac   # only valid states

# Read the hook payload from stdin and pull out the session id. Claude Code
# sends JSON like {"session_id":"...","..."}. We reuse the same jq→python3→grep
# fallback style the tool uses elsewhere, all best-effort.
payload=$(cat 2>/dev/null)
id=""
if command -v jq >/dev/null 2>&1; then
  id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [ -z "$id" ] && command -v python3 >/dev/null 2>&1; then
  id=$(printf '%s' "$payload" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: pass' 2>/dev/null)
fi
if [ -z "$id" ]; then
  # Last-resort: grep the id out of the raw JSON.
  id=$(printf '%s' "$payload" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

[ -n "$id" ] && csp_write_state "$id" "$state"
exit 0
