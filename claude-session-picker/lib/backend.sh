# shellcheck shell=bash
# =============================================================================
# backend.sh — HOW sessions are actually run. Two interchangeable backends.
#
# WHY THIS FILE EXISTS (for non-coders):
#   There are two ways to "run" a Claude session from the menu, and which one we
#   use depends on whether the `tmux` tool is available:
#
#     • HUB backend (needs nothing installed): runs one session at a time in
#       this terminal. When that session exits you come straight back to the
#       menu to pick another. Nothing is lost between switches because Claude
#       saves everything to disk as you go. Works on any Mac or Linux box,
#       including a bare Linux host.
#
#     • TMUX backend (needs the `tmux` tool): puts each session in its own tmux
#       "window". Switching to another session leaves the others RUNNING in the
#       background, so several agents can make progress at the same time.
#
#   The pure function csp_choose_backend (in core.sh) decides which to use; this
#   file contains the two implementations. Keeping them side by side behind the
#   same small set of function names means the menu code never has to care which
#   one is active.
# =============================================================================

# The name of the single tmux session that holds all our Claude windows. Using
# one well-known name means re-running the picker re-attaches to the same place
# instead of spawning duplicates.
#
# This is an INTERNAL tmux session name; it never needs arbitrary Unicode or
# punctuation. We therefore ALLOWLIST a safe set ([A-Za-z0-9_-]) rather than chase
# an ever-growing denylist. Why an allowlist matters here:
#   • ':' and '.' are tmux target syntax ("session:window.pane") — a name with them
#     mis-parses every `-t "=name:win"` target;
#   • quotes/backslashes/newlines break the quoting of the `if-shell` command
#     STRING the name is interpolated into during atomic setup;
#   • '$', backtick, and — crucially — '#', '{', '}' trigger tmux FORMAT/shell
#     expansion on tmux's second parse (e.g. a name `x#{server_sessions}y` becomes
#     `x0y`), producing a wrong session name and a half-configured server.
# An allowlist forecloses all of these (and any future tmux metachar) at once. Cap
# the length so a pathological value can't bloat command lines; empty → default.
CSP_TMUX_SESSION="${CSP_TMUX_SESSION:-claude-sessions}"
CSP_TMUX_SESSION="$(printf '%s' "$CSP_TMUX_SESSION" | LC_ALL=C tr -cd 'A-Za-z0-9_-')"
CSP_TMUX_SESSION="${CSP_TMUX_SESSION:0:64}"
[ -z "$CSP_TMUX_SESSION" ] && CSP_TMUX_SESSION="claude-sessions"

# We run our tmux on a DEDICATED SOCKET (tmux -L "$CSP_TMUX_SOCKET"), completely
# separate from the user's normal tmux server. This is what lets us:
#   • set the status bar / base-index / renumber-windows GLOBALLY (so every
#     session window inherits them — window-status-format is a per-window option
#     that a session-scoped set can't reach), WITHOUT polluting the user's own
#     tmux config or other sessions;
#   • never touch the shared root key table.
# In short: everything we configure lives and dies with this socket, so the
# "we never touch your tmux" promise is literally true.
#
# We STRIP '/', ',', '.' and control chars from the socket NAME. Reasons:
#   • '/' or '..' would make `tmux -L` create the socket at an arbitrary path,
#     breaking the "lives and dies with our socket" guarantee;
#   • the TMUX env var is "<socket-path>,<pid>,<session>", and csp_inside_tmux
#     recovers our name as the path's basename by cutting at the first ','. A
#     name containing ',' or '/' would make that recovery wrong, so the picker
#     would think it is OUTSIDE tmux and re-exec into a broken nested attach.
# Empty after stripping falls back to the default.
CSP_TMUX_SOCKET="${CSP_TMUX_SOCKET:-claude-sessions}"
CSP_TMUX_SOCKET="$(printf '%s' "$CSP_TMUX_SOCKET" | tr -d '/,.[:cntrl:]')"
[ -z "$CSP_TMUX_SOCKET" ] && CSP_TMUX_SOCKET="claude-sessions"

# csp_tmux — run tmux on our dedicated socket. Every tmux call in this file goes
# through this wrapper so the socket AND the config isolation are applied in one
# place.
#
# `-f /dev/null`: our dedicated-socket server must NOT read the user's
# ~/.tmux.conf. Two reasons:
#   • CORRECTNESS — we rely on tmux's built-in defaults for our provenance check
#     (a freshly-created server has `exit-empty on`; see csp_tmux_atomic_home). If
#     the user's config set `exit-empty off`, our fresh server would inherit it and
#     the guard would wrongly refuse to configure it, breaking the tmux backend on
#     every launch. `-f /dev/null` pins the defaults so our own server is always
#     recognisable regardless of the user's config.
#   • ISOLATION — it makes "we never touch (or inherit) your tmux" literally true:
#     no user keybindings, options, or hooks leak into our server.
# `-f` only affects the invocation that CREATES the server; commands to an already
# running server ignore it, so applying it uniformly here is correct and harmless.
csp_tmux() {
  command tmux -f /dev/null -L "$CSP_TMUX_SOCKET" "$@"
}

# csp_tmux_available — returns 0 if the tmux command exists, else 1.
csp_tmux_available() {
  command -v tmux >/dev/null 2>&1
}

# Minimum tmux the CONCURRENT (tmux) backend needs. The ownership guard in
# csp_tmux_atomic_home is built on features that only landed in tmux 2.4:
# `if-shell -F` (2.0), the `#{==:}` / `#{&&:}` / `#{||:}` / `#{server_sessions}`
# FORMAT CONDITIONALS (2.4), plus `exit-empty` (2.1), `#{pid}` (2.1) and
# `#{socket_path}` (2.2) elsewhere. On anything older (e.g. the tmux 1.8 that
# ships on some Linux hosts) those expand to empty / error out, the server never
# gets stamped with @csp_owner, and every launch silently falls back to hub. So
# we gate tmux mode on this version rather than pretend and fail. Bump this if a
# future change relies on a newer feature.
CSP_TMUX_MIN="2.4"

# csp_tmux_version — print the running tmux's numeric "major.minor" (e.g. "3.4"),
# or nothing if it can't be determined. Strips the "tmux " prefix, any
# "next-"/"openbsd-" build prefix, and a trailing letter/suffix ("3.2a" → "3.2").
csp_tmux_version() {
  local ver
  ver=$(command tmux -V 2>/dev/null) || return 0
  ver=${ver##* }                 # last field: "1.8" | "3.2a" | "next-3.5" | "master"
  ver=${ver#next-}; ver=${ver#openbsd-}
  printf '%s' "$ver"
}

# csp_tmux_supported — 0 iff tmux exists AND is new enough (>= CSP_TMUX_MIN) for
# the concurrent backend. A version we can't parse as digits (e.g. a "master" or
# other dev build) is treated as SUPPORTED: we only refuse versions we can
# positively prove are too old, so we never block a modern build that reports an
# unusual string. Everything downstream (startup backend choice, the 't' toggle,
# the mode line, --doctor) gates on this, not on csp_tmux_available alone.
csp_tmux_supported() {
  csp_tmux_available || return 1
  local ver major minor min_major min_minor
  ver=$(csp_tmux_version)
  [ -n "$ver" ] || return 0                 # can't ask → don't block
  major=${ver%%.*}
  minor=${ver#*.}
  [ "$minor" = "$ver" ] && minor=0          # no dot → minor 0
  major=$(printf '%s' "$major" | tr -cd '0-9')   # "3" / "" for "master"
  minor=$(printf '%s' "$minor" | tr -cd '0-9')   # "2" from "2a"
  [ -n "$major" ] || return 0               # unparseable major → assume supported
  [ -n "$minor" ] || minor=0
  min_major=${CSP_TMUX_MIN%%.*}; min_minor=${CSP_TMUX_MIN#*.}
  if [ "$major" -gt "$min_major" ]; then return 0; fi
  if [ "$major" -lt "$min_major" ]; then return 1; fi
  [ "$minor" -ge "$min_minor" ]
}

# --- tmux server ownership identity ------------------------------------------
# A tmux server is treated as OURS only when its server-global @csp_owner option
# equals a PER-INSTANCE token we generated and persisted for this socket. This
# replaces the old "socket name + a menu window" heuristic, which could neither
# avoid a false positive (a user's tmux that happens to be named the same with a
# window called "menu") nor a false negative (our own server whose menu window
# had crashed). A token is:
#   • unguessable by an unrelated tmux — it's random, so a foreign server never
#     matches and is never configured, claimed, or mutated; and
#   • persistent — stored in an owner file keyed to the socket, so the resident
#     picker, a re-launched picker, and the hook (separate processes) all agree.
# When our token and a live server's @csp_owner don't match (foreign server, or
# a legacy/older-build server that predates per-instance tokens), we treat the
# server as NOT ours and fall back to hub rather than claim it. Data safety does
# NOT depend on this recognition: the delete guard's transcript-mtime backstop
# protects a live session regardless of whether its server is recognised.

# csp_tmux_owner_file — the path holding this socket's ownership token, kept
# under the state dir (next to the ●/✳ state) so it persists across picker
# invocations and is readable by the hook.
#
# Keyed on the RESOLVED SOCKET PATH, not just the socket name. Two live servers
# can share a name under different TMUX_TMPDIRs (distinct socket files); keying on
# the name alone would make them share — and clobber — ONE owner file, so
# whichever launched last would orphan the other's recognition (its resident
# picker + hook would re-read a token that no longer matches its own @csp_owner
# and stop treating their own live server as ours). Keying on the full path gives
# each distinct server its own file. When no server is live yet (or tmux can't
# answer), fall back to the name — the only caller in that state is a reader that
# then finds no token, which is the correct "not ours" answer.
#
# $1 (optional) is a PRE-RESOLVED socket path: a caller that already ran
# `display-message -p '#{socket_path}'` (e.g. csp_inside_tmux) passes it so we
# don't fork tmux again just to rebuild the same key — this matters on the hook's
# per-prompt path. Empty/absent → we resolve it ourselves.
#
# The key is an INJECTIVE hex encoding of the full path, NOT a lossy character
# substitution: `tr -c 'A-Za-z0-9._-' '_'` maps distinct paths to the same key
# (e.g. /tmp/a/b and /tmp/a_b both → _tmp_a_b), which would let two real servers
# share — and clobber — one owner file. Byte-wise hex is one-to-one, so every
# distinct socket path gets its own file.
csp_tmux_owner_file() {
  local key lpath="${1:-}"
  [ -n "$lpath" ] || lpath=$(command tmux -f /dev/null -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}' 2>/dev/null)
  [ -n "$lpath" ] || lpath="$CSP_TMUX_SOCKET"
  key=$(printf '%s' "$lpath" | od -An -tx1 2>/dev/null | tr -d ' \n')
  # Fallback if od is somehow unavailable: lossy but still deterministic (only
  # reached on a machine without od, where a path collision is a non-issue).
  [ -n "$key" ] || key=$(printf '%s' "$lpath" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/tmux-owner.%s' "$CSP_STATE_DIR" "$key"
}

# csp_tmux_read_token_file FILE — read+validate a token from one owner file.
# Prints the token if the file holds our exact shape ("csp-"+[A-Za-z0-9-]), else
# nothing. Symlink-refusing; bounded read; rejects an over-long first line.
csp_tmux_read_token_file() {
  local f="$1" v="" size
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  # BOUNDED by a SIZE CHECK FIRST, before reading any content. `read -r -n 96`
  # alone is NOT a reliable byte bound across our whole support range (Bash 3.2+
  # incl. Linux): Bash 4.3+ SKIPS NUL bytes without counting them toward -n, so a
  # NUL-heavy file could still be scanned to EOF and stall startup. A real token
  # file is ~37 bytes; anything over 96 bytes is definitively not ours, so we stat
  # the size and refuse WITHOUT reading a single byte of content. (Cross-platform:
  # BSD `stat -f %z`, then GNU `stat -c %s`.) A same-user replacement race between
  # the stat and the read is an accepted residual on this single-user local model;
  # our own writes use atomic rename and never grow a file in place.
  size=$(stat -f '%z' "$f" 2>/dev/null) || size=$(stat -c '%s' "$f" 2>/dev/null) || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le 96 ] || return 0
  # Now the file is provably ≤96 bytes, so this read is inherently bounded on ANY
  # bash. `|| true` because read returns non-zero at EOF/cap; LC_ALL=C keeps the
  # cap and the length check below byte-exact.
  { LC_ALL=C IFS= read -r -n 96 v < "$f" || true; } 2>/dev/null
  v="${v%$'\r'}"
  # Reject an over-long line outright (don't truncate — truncating a huge line to
  # N valid chars could forge a plausible token). Our token is "csp-"+32 hex = 36;
  # 96 read minus a possible CR leaves headroom, and >64 is definitively bogus.
  [ "${#v}" -le 64 ] || v=""
  case "$v" in
    csp-*[!A-Za-z0-9-]*) v="" ;;   # disallowed char after the prefix
    csp-?*) ;;                     # csp- + ≥1 valid char → keep
    *) v="" ;;                     # missing prefix / empty
  esac
  printf '%s' "$v"
}

# csp_tmux_owner_token — print the persisted ownership token for this socket, or
# nothing if none has been established yet. Always returns 0.
# $1 (optional) is a pre-resolved socket path, forwarded to csp_tmux_owner_file.
#
# We try the RESOLVED-PATH-keyed file first, then fall back to the NAME-keyed file.
# The fallback matters for RECOVERY: a stale server we owned that is now at 0
# sessions can't report its `socket_path` (display-message returns empty), so
# csp_tmux_owner_file resolves to the NAME key — but the token may have been
# written under the PATH key when the server was live. Trying both lets us still
# recognise (and recover) our own stale server. Both keys are per-user under the
# 0700 state dir, so this widens recognition, not exposure.
csp_tmux_owner_token() {
  local pathkey_file namekey_file v
  pathkey_file=$(csp_tmux_owner_file "${1:-}")
  v=$(csp_tmux_read_token_file "$pathkey_file")
  if [ -z "$v" ]; then
    namekey_file=$(csp_tmux_owner_file_namekey)
    [ "$namekey_file" != "$pathkey_file" ] && v=$(csp_tmux_read_token_file "$namekey_file")
  fi
  printf '%s' "$v"
}

# csp_tmux_gen_owner_token — print a fresh random ownership token ("csp-<hex>")
# WITHOUT touching disk. Random bytes from /dev/urandom; a pid/RANDOM fallback
# keeps it working on a machine without it (uniqueness, not cryptographic secrecy,
# is what the single-user local model needs). Kept to [A-Za-z0-9-] so the
# read-back shape check accepts it.
csp_tmux_gen_owner_token() {
  local tok
  tok=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$tok" ] || tok="$$${RANDOM:-0}${RANDOM:-0}$(date +%s 2>/dev/null || echo 0)"
  tok=$(printf '%s' "$tok" | tr -cd 'A-Za-z0-9')
  printf 'csp-%s' "$tok"
}

# csp_tmux_owner_file_namekey — the NAME-keyed owner file (hex of the socket NAME,
# not the resolved path). This is the key a 0-session server resolves to (its
# socket_path can't be read), so we ALSO write it here for recovery — see
# csp_tmux_owner_token's fallback. On the normal single-socket-name setup the
# name key is stable across a server's whole life, path or not.
csp_tmux_owner_file_namekey() {
  printf '%s/tmux-owner.%s' "$CSP_STATE_DIR" \
    "$(printf '%s' "$CSP_TMUX_SOCKET" | od -An -tx1 2>/dev/null | tr -d ' \n')"
}

# csp_tmux_persist_owner_token TOKEN — persist TOKEN as this socket's owner token.
# HARDENED: dir 0700, file 0600, atomic. The temp is created UNPREDICTABLY with
# mktemp INSIDE the 0700 dir (O_EXCL, so it can't follow a pre-planted symlink),
# then renamed into place (REPLACES, never follows, a symlink at the final path).
# Returns non-zero if the PRIMARY (path-keyed) write fails. Best-effort for the
# caller — a failed persist just means the next reader finds no token.
#
# We write TWO copies: the PATH-keyed file (primary — distinguishes same-named
# servers under different TMUX_TMPDIRs, see csp_tmux_owner_file) AND the NAME-keyed
# file (so a later launch can still read our token when the server is at 0 sessions
# and can't report its socket_path). Both live under the 0700 state dir.
csp_tmux_persist_owner_token() {
  local tok="$1" rv=0
  _csp_persist_one() {   # $1 = target file
    local f="$1" d tmp
    d=$(dirname "$f")
    mkdir -p "$d" 2>/dev/null || return 1
    chmod 700 "$d" 2>/dev/null || true
    tmp=$(mktemp "$d/.owner.XXXXXX" 2>/dev/null) || return 1
    { printf '%s\n' "$tok" > "$tmp"; } 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
    return 0
  }
  _csp_persist_one "$(csp_tmux_owner_file)" || rv=1   # primary (path-keyed)
  # Best-effort secondary (name-keyed); don't fail the caller if only this misses.
  local nk; nk=$(csp_tmux_owner_file_namekey)
  [ "$nk" = "$(csp_tmux_owner_file)" ] || _csp_persist_one "$nk"
  return "$rv"
}

# csp_tmux_new_owner_token — generate a fresh token AND persist it, printing it.
# (Back-compat wrapper: gen + persist in one call. The fresh path uses gen and
# persist separately so it can stamp the token into the atomic create invocation
# before the owner-file path is resolvable.)
csp_tmux_new_owner_token() {
  local tok
  tok=$(csp_tmux_gen_owner_token)
  csp_tmux_persist_owner_token "$tok" 2>/dev/null || true
  printf '%s' "$tok"
}

# csp_inside_tmux — returns 0 if we are currently running inside OUR OWN picker
# tmux (the dedicated server, in our holding session), not just any tmux. All of:
#   1. the $TMUX socket path's BASENAME equals our socket name (cheap; compared
#      EXACTLY so "claude-sessions" != "claude-sessions-extra"); AND
#   2. the CURRENT session is our holding session ($CSP_TMUX_SESSION) — so an
#      environment pointing at a different session/instance on a same-named
#      socket isn't accepted while our csp_tmux ops would target another; AND
#   3. the ambient server's @csp_owner equals OUR persisted per-instance token,
#      proving we created this exact server. An empty token (none established) or
#      a mismatch (a foreign or legacy/markerless server) → not ours. Data safety
#      does NOT rely on this: even when a live bare session sits in a server we no
#      longer recognise, the delete guard's transcript-mtime backstop still
#      protects it (see csp_delete_would_hit_live).
# The socket-path/session queries use the ambient $TMUX (no -L), so they ask the
# very server we're inside; the token comparison binds that server to the exact
# instance we minted. Any tmux error → treated as not-ours (fail closed).
csp_inside_tmux() {
  local t="${TMUX:-}" path lpath tok owner cur
  [ -n "$t" ] || return 1
  path="${t%%,*}"          # the ambient server's socket path (before 1st comma)
  # BIND ambient to -L: the socket the ambient $TMUX names must be the SAME file
  # that our `tmux -L "$CSP_TMUX_SOCKET"` resolves to. Otherwise csp_inside_tmux
  # could say "yes" for one instance while every csp_tmux op (and the delete
  # guard's window lookup) targets another — a same-name socket under a different
  # TMUX_TMPDIR. Comparing the full resolved socket paths keeps identity and
  # routing on the same server.
  lpath=$(command tmux -f /dev/null -L "$CSP_TMUX_SOCKET" display-message -p '#{socket_path}' 2>/dev/null) || return 1
  [ -n "$lpath" ] && [ "$path" = "$lpath" ] || return 1
  # Must be inside our holding session (per-instance identity, not just socket).
  cur=$(command tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
  [ "$cur" = "$CSP_TMUX_SESSION" ] || return 1
  # Ours iff the ambient server's @csp_owner equals OUR persisted token. A
  # non-empty token that matches proves we created this exact server; an empty
  # token (none established) or a mismatch (foreign / legacy) → not ours.
  tok=$(csp_tmux_owner_token "$lpath")   # reuse the path we already resolved
  [ -n "$tok" ] || return 1
  owner=$(command tmux show-options -gv @csp_owner 2>/dev/null) || return 1
  [ "$owner" = "$tok" ]
}

# =============================================================================
# HUB backend — one session at a time, no dependencies.
# =============================================================================

# csp_hub_open ID PROJECT
#
# Run a session in the foreground and WAIT for it to finish, then return so the
# caller can redraw the menu. If ID is the literal string "new", we start a
# fresh Claude instead of resuming.
#
# We run claude in a subshell (parentheses) rather than `exec`, precisely so
# control comes BACK to us when the user exits the session — that "return to the
# menu" behaviour is the whole point of hub mode. cd'ing into the project first
# gives the session its original working directory; a failed cd is non-fatal.
csp_hub_open() {
  local id="$1" project="$2"
  (
    if [ -n "$project" ] && [ -d "$project" ]; then
      cd "$project" 2>/dev/null || true
    fi
    if [ "$id" = "new" ]; then
      claude
    else
      claude --resume "$id"
    fi
  )
}

# =============================================================================
# TMUX backend — many sessions running concurrently in tmux windows.
# =============================================================================

# csp_tmux_sanitize_label LABEL — make a safe, non-empty tmux window name.
# tmux rejects names containing newlines, treats a leading '-' as a flag, and
# SPLITS ITS COMMAND LINE on ';' — a name ending in ';' makes tmux parse the
# window's shell command as a second tmux command, so new-window fails. We drop
# ';' entirely, flatten control chars, but KEEP multi-byte (CJK) characters so a
# 工作/專案 project shows as itself rather than collapsing to "_/_". Then trim
# and cap, falling back to "session" if nothing usable is left.
csp_tmux_sanitize_label() {
  local label="$1" clean
  # Remove semicolons (tmux command separator), flatten control chars to spaces,
  # and squeeze repeats; leave other bytes (incl. UTF-8) intact.
  clean=$(printf '%s' "$label" | tr -d ';' | tr '\000-\037\177' ' ' | tr -s ' ')
  clean="${clean#[-_ ]}"                # never start with '-', '_' or space
  clean="${clean%[ ]}"                  # no trailing space
  clean="${clean:0:32}"
  clean="${clean%[ ]}"                  # cap may re-expose a trailing space
  [ -z "$clean" ] && clean="session"
  printf '%s' "$clean"
}

# csp_tmux_server_is_ours — return 0 if the tmux server on OUR -L socket is one
# the picker owns, and is therefore safe to (re)configure and attach to. This is
# decided ONLY by the ownership token, never the socket name or window shape: a
# user could run their own tmux on the exact same -L socket name (even with a
# session named "claude-sessions" and a window named "menu"), and configuring or
# claiming it would break the "we never touch your tmux" promise. We require the
# server's @csp_owner to equal OUR persisted per-instance token — an unguessable
# value only a server WE created carries. A foreign server (no token, or a
# different one) and a legacy/older-build server (no per-instance token) are both
# correctly judged NOT ours; we fall back to hub rather than claim them. (Data
# safety doesn't hinge on this — the delete guard's mtime backstop is
# ownership-independent.)
csp_tmux_server_is_ours() {
  csp_tmux_available || return 1
  local tok owner
  tok=$(csp_tmux_owner_token)
  [ -n "$tok" ] || return 1                      # no token established → not ours
  owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null) || return 1
  [ "$owner" = "$tok" ]
}

# csp_tmux_configure_home — configure our dedicated-socket tmux server so the
# holding session is easy to navigate, WITHOUT touching the user's config.
# Because we run on our own socket (csp_tmux / -L), we can safely set options
# GLOBALLY (-g): they apply to every window we open — crucial because
# window-status-format is a per-window option a session-scoped set can't reach —
# yet they live only on this socket and vanish when it does. All best-effort.
csp_tmux_configure_home() {
  # Stamp our per-instance ownership token as the server-global @csp_owner option
  # so csp_inside_tmux / csp_tmux_server_is_ours can later prove this exact server
  # is ours (see the ownership-identity section). The token comes from our owner
  # file; the fresh path generates it just before the first configure. Set on our
  # dedicated socket only, so it never leaks to a user's server.
  csp_tmux set-option -g @csp_owner "$(csp_tmux_owner_token)" 2>/dev/null

  # Window numbering: force base 0 and keep it gapless, so "window 0 = menu" and
  # "Ctrl-b <n> = the nth session" are always true regardless of the user's own
  # base-index, and numbers don't go stale after a session is closed.
  csp_tmux set-option -g base-index 0 2>/dev/null
  csp_tmux set-option -g renumber-windows on 2>/dev/null

  # Mouse on: without it tmux (default `mouse off`) translates the scroll wheel
  # into arrow keys sent to the program — so scrolling a resumed Claude/shell
  # just walks its input history instead of scrolling the pane, and native
  # terminal scrollback (Shift-scroll) shows content from OUTSIDE the pane. With
  # mouse on, the wheel scrolls the pane / enters copy-mode as expected, and
  # clicking a window in the status bar selects it. Scoped to our dedicated
  # socket, so the user's own tmux config is untouched.
  csp_tmux set-option -g mouse on 2>/dev/null

  csp_tmux set-option -g status on 2>/dev/null
  csp_tmux set-option -g status-interval 2 2>/dev/null
  csp_tmux set-option -g status-justify left 2>/dev/null
  # Keep status-left tiny so the window list (the map of what's open) has room
  # even at 80 columns.
  csp_tmux set-option -g status-left "" 2>/dev/null
  csp_tmux set-option -g status-left-length 0 2>/dev/null
  # Each window is a session: number + name, name truncated to 9 display cells
  # so several fit at 80 cols. Current window highlighted so you see where you are.
  csp_tmux set-option -g window-status-format " #I #{=9:window_name} " 2>/dev/null
  csp_tmux set-option -g window-status-current-format "#[reverse,bold] #I #{=9:window_name} #[default]" 2>/dev/null
  # Always-visible hint — this is the fix for "Ctrl-b gives no feedback": the
  # keys are on screen at all times. Kept short so it fits beside the window list.
  csp_tmux set-option -g status-right " Ctrl-b 0=menu n/p=switch w=list d=detach " 2>/dev/null
  csp_tmux set-option -g status-right-length 44 2>/dev/null
  csp_tmux set-option -g display-time 1500 2>/dev/null
}

# csp_tmux_configure_home_if_owned TOKEN — the REUSE-path configure. Applies the
# global options ONLY if the server's @csp_owner equals TOKEN, checked and applied
# in ONE tmux invocation (single server connection). This closes the reuse-path
# race where `csp_tmux_server_is_ours` (one invocation) said yes, then a socket
# swap brought in a replacement server that the subsequent separate configure
# would have mutated. Here the ownership check and the mutations are the same
# `if-shell` — a swap can't slip between them. Returns 0 iff the guard fired (the
# server is ours and was configured); non-zero otherwise so the caller falls back
# to hub without having touched a foreign/replacement server.
csp_tmux_configure_home_if_owned() {
  local tok="$1" cfg out
  [ -n "$tok" ] || return 1
  # ONE invocation carries the whole decision AND its result — no cross-call state:
  #   • TRUE branch: apply all options, then `display-message -p 1` (emit the
  #     success marker to OUR captured stdout, from THIS server connection).
  #   • FALSE branch: `display-message -p 0` and WRITE NOTHING — a foreign or
  #     replacement server is never mutated (not even a sentinel option), so the
  #     "we never touch a server we don't own" promise holds even here.
  # We trust ONLY the stdout marker from this invocation, not any server option
  # read back later (which a socket swap could source from a different server
  # generation — the old sentinel bug). No match / empty output → not ours → fail.
  cfg="$(csp_tmux_cfg_body) ; display-message -p 1"
  out=$(csp_tmux if-shell -F "#{==:#{@csp_owner},$tok}" "$cfg" 'display-message -p 0' 2>/dev/null)
  [ "$out" = "1" ]
}

# csp_tmux_atomic_home TOKEN CMD — create the holding server AND fully configure
# AND respawn window 0 as the picker, in ONE tmux invocation (all commands run
# against a SINGLE server connection). This is the structural fix for the
# "configure-time socket swap mutates a replacement server" race: with separate
# `tmux -L` invocations, a server killed between two set-options could be replaced
# and the later options would hit the replacement. In one invocation there is no
# such window — if our server dies mid-queue the connection drops and the rest of
# the queue simply fails; nothing is redirected to another server.
#
# Sequence in the single queue:
#   new-session -d (creates the server if the socket is free; on a live FOREIGN
#     server with our exact session name it FAILS → whole invocation fails → bail;
#     on a foreign server with OTHER names it JOINS, adding our session) →
#   if-shell -F on server_sessions==1: this is the crux. It fires the ENTIRE
#     configure block (stamp @csp_owner=TOKEN + @csp_boot + all global options)
#     ONLY when ours is the sole session — i.e. a genuinely fresh server WE just
#     created. If new-session JOINED a foreign server (≥2 sessions), the count is
#     >1 and NONE of the mutations run: we never touch a foreign server's options
#     or stamp our token on it. All server-side, in one connection, so no swap can
#     slip between the count check and the mutations.
# NOTE: the picker command ($cmd) is deliberately NOT part of this invocation. It
# contains spaces and shell-quoting, and embedding it in the if-shell STRING would
# subject it to a second tmux word-split that mangles any spaced path/env value
# (breaking every fresh launch on a machine whose $HOME has a space). The caller
# does the respawn separately as a DIRECT-ARGV `respawn-window` (no re-parse), after
# re-verifying our token — see csp_tmux_enter. Only the token/config/count logic,
# none of which needs $cmd, lives in the atomic block.
# Returns tmux's exit status. Best-effort options (2>/dev/null on the whole call).
# csp_tmux_cfg_body — the shared set-option list (navigation/status/window-format)
# as a single ';'-joined tmux command string, for use inside an `if-shell` body.
# Excludes @csp_owner/@csp_boot (caller-specific). No $cmd interpolation.
csp_tmux_cfg_body() {
  local cfg
  cfg="set-option -g base-index 0"
  cfg="$cfg ; set-option -g renumber-windows on"
  cfg="$cfg ; set-option -g mouse on"
  cfg="$cfg ; set-option -g status on"
  cfg="$cfg ; set-option -g status-interval 2"
  cfg="$cfg ; set-option -g status-justify left"
  cfg="$cfg ; set-option -g status-left \"\""
  cfg="$cfg ; set-option -g status-left-length 0"
  cfg="$cfg ; set-option -g window-status-format \" #I #{=9:window_name} \""
  cfg="$cfg ; set-option -g window-status-current-format \"#[reverse,bold] #I #{=9:window_name} #[default]\""
  cfg="$cfg ; set-option -g status-right \" Ctrl-b 0=menu n/p=switch w=list d=detach \""
  cfg="$cfg ; set-option -g status-right-length 44"
  cfg="$cfg ; set-option -g display-time 1500"
  printf '%s' "$cfg"
}

csp_tmux_atomic_home() {
  local tok="$1" prior="${2:-}" boot='sh -c "while :; do sleep 2147483647; done"' cfg guard
  # The configure block, run only when the guard fires. Semicolon-separated tmux
  # commands inside a single if-shell command string. No $cmd interpolation.
  # We also NORMALISE exit-empty back to on: when we RECOVER a stale owned server
  # that had exit-empty off (inherited long ago from the user's config, before we
  # switched to -f /dev/null), setting it on makes the server behave like a fresh
  # one and keeps the exit-empty==1 branch of the guard true on the next launch.
  cfg="set-option -g @csp_owner \"$tok\""
  cfg="$cfg ; set-option -g exit-empty on"
  cfg="$cfg ; set-option -w -t \"=$CSP_TMUX_SESSION:menu\" @csp_boot 1"
  cfg="$cfg ; $(csp_tmux_cfg_body)"
  # GUARD (in-queue, so no socket swap can slip between the check and the config):
  #   server_sessions==1  AND  (exit-empty==1  OR  @csp_owner==prior-token)
  #
  #   • server_sessions==1 → ours is the sole session (new-session didn't join a
  #     foreign server that already had other sessions). ALWAYS required.
  #   • exit-empty==1 → a genuinely fresh server WE just created (tmux default on;
  #     we start with -f /dev/null so the user's config can't turn it off on us).
  #   • @csp_owner==prior-token → RECOVERY of a stale server WE previously owned:
  #     a 0-session server can only still be alive with exit-empty off, which an
  #     OLD build inherited from the user's ~/.tmux.conf. Such a server carries our
  #     PERSISTED prior token, so it's provably ours to reconfigure and re-adopt
  #     (we rotate it to the new token in cfg). Without this, an upgraded user with
  #     a surviving 0-session owned server would fail to launch on EVERY attempt
  #     (exit-empty==0, so the old single-condition guard never fired).
  # A FOREIGN 0-session server has neither exit-empty==1 nor our prior token, so it
  # is still correctly rejected and never mutated. The prior token is unguessable,
  # so this cannot be spoofed by an unrelated server.
  if [ -n "$prior" ]; then
    guard="#{&&:#{==:#{server_sessions},1},#{||:#{==:#{exit-empty},1},#{==:#{@csp_owner},$prior}}}"
  else
    guard='#{&&:#{==:#{server_sessions},1},#{==:#{exit-empty},1}}'
  fi
  csp_tmux \
    new-session -d -s "$CSP_TMUX_SESSION" -n menu "$boot" \; \
    if-shell -F "$guard" "$cfg" \
    2>/dev/null
}

# csp_tmux_enter_cleanup EXPECTED_PID [TOKEN] — remove OUR holding session from the
# fresh path, but ONLY when we can prove the server on this socket is still ours
# (never destroy a foreign/replacement session sharing the socket name). We accept
# EITHER proof:
#   • the live server pid equals EXPECTED_PID (the instance we created); OR
#   • the live server's @csp_owner equals TOKEN — the unguessable value only WE
#     set, so a match is definitive even when we couldn't read a pid.
# The token path is what lets us still clean up after a transient `display-message`
# pid-read failure (EXPECTED_PID empty) without orphaning our just-created bootstrap
# session — while a foreign server, which can't carry our token, is still left
# untouched. If NEITHER proof holds (pid mismatch/absent AND no token match), we do
# nothing. Best-effort.
csp_tmux_enter_cleanup() {
  local expected="$1" tok="${2:-}" cur owner
  cur=$(csp_tmux display-message -p '#{pid}' 2>/dev/null)
  if [ -n "$expected" ] && [ "$cur" = "$expected" ]; then
    csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null || true
    return 0
  fi
  if [ -n "$tok" ]; then
    owner=$(csp_tmux show-options -gv @csp_owner 2>/dev/null) || owner=""
    if [ "$owner" = "$tok" ]; then
      csp_tmux kill-session -t "=$CSP_TMUX_SESSION" 2>/dev/null || true
    fi
  fi
  return 0
}

# csp_tmux_enter SELF_PATH — put the picker itself inside the holding tmux
# session (on our dedicated socket) as window 0, so it stays resident as your
# "home base".
#
# The model: tmux mode runs everything inside one tmux session on our own socket.
# The picker lives in window 0 ("menu"); each session you open becomes window
# 1, 2, … You return to the picker with Ctrl-b 0 and switch between running
# sessions with Ctrl-b n/p/w — all of them stay alive in the background. A
# persistent status bar (see csp_tmux_configure_home) lists the windows and
# spells out those keys, so the Ctrl-b prefix is no longer invisible.
#
# Only relevant when we are NOT yet inside OUR tmux. It creates the holding
# session running THIS picker (via SELF_PATH) in window 0 and attaches, then
# never returns (exec replaces us). The re-launched picker comes back here
# already inside our tmux and just runs its menu loop. If a holding session
# already exists, we (re)configure and attach; but if its window 0 is no longer
# a picker (e.g. the user pressed q, killing the menu window), we recreate the
# menu window first so "attach" always lands you on a working menu.
csp_tmux_enter() {
  local self="$1" cmd v val
  csp_inside_tmux && return 0

  # Build the command tmux runs for the picker window, carrying our environment
  # across the re-launch (tmux starts the window with a fresh environment). We
  # prefix with `env VAR=val …` rather than the shell's own `VAR=val cmd` form,
  # because tmux runs the command through the user's DEFAULT-SHELL — which may be
  # csh/tcsh, where `VAR=val cmd` is a syntax error and the window would silently
  # die. `env` is a real program and works under any shell. We forward our CSP_*
  # settings and TMUX_TMPDIR (so `tmux -L` resolves to the SAME socket directory
  # the parent used; otherwise csp_tmux_open could target a different, empty
  # server and every Enter would fall back to hub).
  cmd="env CSP_BACKEND=tmux"
  for v in CSP_CLAUDE_DIR CSP_TMUX_SESSION CSP_TMUX_SOCKET CSP_PREF_FILE CSP_STATE_DIR CSP_NO_COLOR TMUX_TMPDIR; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && cmd="$cmd $v=$(csp_shell_quote "$val")"
  done
  cmd="$cmd $(csp_shell_quote "$self")"

  if csp_tmux has-session -t "=$CSP_TMUX_SESSION" 2>/dev/null; then
    # Before touching ANY global option on this server, make sure it's really
    # ours — a user could have an unrelated tmux on the exact same -L socket name.
    # We check ownership AND apply the config in ONE tmux invocation
    # (csp_tmux_configure_home_if_owned): the @csp_owner==token test and the
    # set-options run on the same server connection, so a socket swap can't slip
    # between "it's ours" and the mutations and cause us to configure a
    # replacement/foreign server. If the guard doesn't fire (not ours, or a swap
    # left a server without our token), nothing was mutated → fall back to hub.
    csp_tmux_configure_home_if_owned "$(csp_tmux_owner_token)" || return 1
    # Guarantee window 0 IS a menu before we attach — otherwise the client lands
    # on an arbitrary Claude window with no resident picker while the status bar
    # still claims window 0 is the menu. We must handle THREE states, not just
    # "no menu at all": (a) no menu window anywhere → create one; (b) a menu
    # window exists but at a NON-ZERO index (e.g. left orphaned by an earlier
    # partial recovery) → swap it to 0; (c) already 0:menu → nothing to do. Every
    # step is checked; if we can't end at 0:menu we return non-zero so the caller
    # falls back to hub rather than attaching into a menu-less, misleading state.
    # We SWAP into index 0 (never move-window -k, which would KILL whatever
    # occupies 0 — destroying a running Claude); swap is non-destructive.
    if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null \
         | grep -qx '0:menu'; then
      # Create a menu window only if none exists at all; otherwise reuse the one
      # that's already there (at whatever index) and just swap it to 0.
      if ! csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_name}' 2>/dev/null \
           | grep -qx menu; then
        csp_tmux new-window -t "=$CSP_TMUX_SESSION" -n menu "$cmd" 2>/dev/null || return 1
      fi
      # Swap the (now-guaranteed-to-exist) menu window into index 0. `:menu`
      # targets it by name regardless of its current index.
      csp_tmux swap-window -s "=$CSP_TMUX_SESSION:menu" -t "=$CSP_TMUX_SESSION:0" 2>/dev/null || return 1
      # Confirm we really ended at 0:menu before committing to attach.
      csp_tmux list-windows -t "=$CSP_TMUX_SESSION" -F '#{window_index}:#{window_name}' 2>/dev/null \
        | grep -qx '0:menu' || return 1
    fi
    # Window 0 is named "menu", but a fresh-path launch that bailed after creating
    # the bootstrap placeholder could have left a SLEEPING shell there (still
    # tagged @csp_boot=1) rather than the running picker. Don't trust the name:
    # if window 0 still carries the bootstrap tag, respawn it into the real picker
    # so we never attach the user to a hung sleeper. Clear the tag on success.
    if [ "$(csp_tmux show-options -wv -t "=$CSP_TMUX_SESSION:0" @csp_boot 2>/dev/null)" = "1" ]; then
      csp_tmux respawn-window -k -t "=$CSP_TMUX_SESSION:0" "$cmd" 2>/dev/null || return 1
      csp_tmux set-option -wu -t "=$CSP_TMUX_SESSION:0" '@csp_boot' 2>/dev/null
    fi
    csp_tmux_record_launch_pwd    # so `n` follows where this client re-attached
    # exec the REAL tmux (a bare `exec csp_tmux` fails — exec can't run a shell
    # function). If exec somehow can't replace us, return non-zero so the caller
    # restores the terminal instead of falling through in a broken state.
    exec command tmux -f /dev/null -L "$CSP_TMUX_SOCKET" attach-session -t "=$CSP_TMUX_SESSION"
    return 1
  fi

  # We reach here because our holding session does NOT exist on this socket. That
  # has two very different causes, and we must tell them apart before creating
  # anything: (1) there is NO tmux server on this -L socket at all → safe to
  # create ours; (2) a server IS already alive here but it's the user's own
  # (a session not named ours) → we must NOT create a session on it, because the
  # very next step (csp_tmux_configure_home) would set GLOBAL options and stamp
  # our marker on THEIR server. `csp_tmux_server_is_ours` can't distinguish these
  # (a truly-empty socket also isn't "ours"), so we check liveness first: if a
  # server responds AND it isn't ours, refuse and fall back to hub.
  if csp_tmux list-sessions >/dev/null 2>&1 && ! csp_tmux_server_is_ours; then
    return 1
  fi

  # Fresh: create the holding session with the picker in window 0 (named "menu"),
  # configure it, then attach. Detached-first so options apply before the client
  # draws.
  #
  # ORDERING MATTERS: we must NOT start the picker child before @csp_owner is set,
  # or that child can run csp_inside_tmux before the marker exists, decide it is
  # "not inside our tmux", and re-enter csp_tmux_enter (a confusing tmux-inside-
  # tmux attempt that then falls back to hub). So we create window 0 running a
  # tiny BOOTSTRAP placeholder (a shell that just waits), mint the token, configure
  # the server (which stamps the token as the marker), and only THEN respawn window
  # 0 with the real picker command. By the time the picker runs, the marker is
  # already set, so its csp_inside_tmux returns true immediately. The placeholder
  # shell is POSIX (`sh -c` + a plain `sleep`) so it works under any default shell;
  # the 2147483647 is INT_MAX seconds (~68y) — a portable "sleep effectively
  # forever" that avoids the non-POSIX `sleep infinity` (unsupported by macOS/BSD).
  #
  # Create the server FIRST, then mint the token. The owner file is keyed on the
  # resolved socket PATH (see csp_tmux_owner_file), which only exists once a server
  # is live — so the order is: start the bootstrap server, mint+persist the token
  # (now the path resolves and the file lands under this exact server's key), then
  # configure_home stamps that token as @csp_owner. Keying per-path means a
  # concurrent instance on a same-named socket at a DIFFERENT path writes a
  # DIFFERENT owner file and can't clobber this server's token.
  local tok prior sessions srv_pid
  # Read any PERSISTED prior token BEFORE minting a new one. If a stale server we
  # previously owned is still alive at 0 sessions (exit-empty off, inherited by an
  # old build from the user's config), it carries this token as @csp_owner — the
  # atomic guard uses it to recognise and RECOVER that server rather than looping
  # on failure forever. Empty for a truly fresh socket, which is fine.
  prior=$(csp_tmux_owner_token)
  # Mint the NEW token VALUE up front (random string; not yet persisted — the owner
  # file is keyed on the resolved socket path, which only exists once the server
  # is live, so we persist it after create). csp_tmux_gen_owner_token just returns
  # a fresh "csp-<hex>" value without touching disk.
  tok=$(csp_tmux_gen_owner_token)
  [ -n "$tok" ] || return 1
  # ATOMIC create + configure: one tmux invocation, so `new-session` and every
  # global option (incl. @csp_owner=tok, @csp_boot) run against a SINGLE server
  # connection, gated on server_sessions==1 AND (fresh OR our prior token). A
  # socket swap can't slip between the check and the mutations; if new-session
  # joined a FOREIGN server nothing is stamped. The picker command is NOT part of
  # this invocation (it has spaces/quoting that a second tmux word-split would
  # mangle) — we respawn window 0 separately below via direct argv.
  csp_tmux_atomic_home "$tok" "$prior" || return 1
  # Bind to THIS instance's pid for all later cleanup.
  srv_pid=$(csp_tmux display-message -p '#{pid}' 2>/dev/null)
  case "$srv_pid" in ''|*[!0-9]*) csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1 ;; esac
  # POSITIVE proof this is a freshly created, ours-only server carrying OUR token:
  #   • our @csp_owner must equal tok (new-session didn't join a foreign server, or
  #     if it did, that server can't already carry our just-minted unguessable tok
  #     — so a mismatch means "not our clean server" → bail); AND
  #   • list-sessions must SUCCEED and be EXACTLY our one session (no foreign
  #     sessions rode along). Either failing → pid-guarded cleanup + hub.
  if [ "$(csp_tmux show-options -gv @csp_owner 2>/dev/null)" != "$tok" ]; then
    csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1
  fi
  if sessions=$(csp_tmux list-sessions -F '#{session_name}' 2>/dev/null); then
    [ "$sessions" = "$CSP_TMUX_SESSION" ] || { csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1; }
  else
    csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1
  fi
  # Persist the token to the owner file (path now resolvable) BEFORE launching the
  # picker child, so the child's csp_inside_tmux — and the hook — see it's ours from
  # the first moment. This is an INVARIANT: if the write fails, the child could not
  # prove ownership (it would re-enter and fall back to hub, leaving an
  # unrecognised server behind), so we must NOT proceed — tear down our own server
  # (pid- or token-guarded) and fall back to hub cleanly instead.
  csp_tmux_persist_owner_token "$tok" || { csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1; }
  # Respawn window 0 into the real picker via DIRECT ARGV (no string re-parse, so a
  # spaced path/env value in $cmd is preserved), then clear the bootstrap tag. We
  # re-verify our token first: only respawn a server we still own (never drive a
  # replacement). A respawn failure → pid-guarded cleanup.
  if [ "$(csp_tmux show-options -gv @csp_owner 2>/dev/null)" != "$tok" ]; then
    csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1
  fi
  csp_tmux respawn-window -k -t "=$CSP_TMUX_SESSION:menu" "$cmd" 2>/dev/null || {
    csp_tmux_enter_cleanup "$srv_pid" "$tok"; return 1
  }
  csp_tmux set-option -wu -t "=$CSP_TMUX_SESSION:menu" '@csp_boot' 2>/dev/null
  csp_tmux_record_launch_pwd    # seed the launch dir for `n` (see helper)
  exec command tmux -f /dev/null -L "$CSP_TMUX_SOCKET" attach-session -t "=$CSP_TMUX_SESSION"
  csp_tmux_enter_cleanup "$srv_pid" "$tok"   # only if exec failed AND still our instance
  return 1
}

# csp_tmux_record_launch_pwd — remember the directory the CURRENT client is
# attaching from, so a new session (`n`) opens there rather than in whatever
# directory the resident picker (window 0) was first launched from. Stored as a
# tmux session env var the running picker reads live at press time (see
# csp_tmux_launch_pwd). Called on every attach — fresh or re-attach — so the
# value always reflects the latest client. Best-effort.
csp_tmux_record_launch_pwd() {
  csp_tmux set-environment -t "=$CSP_TMUX_SESSION" CSP_LAUNCH_PWD "$PWD" 2>/dev/null
}

# csp_tmux_launch_pwd — the directory a NEW session (`n`) should start in when
# the picker is running as the resident tmux menu. tmux window 0 keeps the cwd it
# was first launched from, but a later re-attach from another directory records
# that directory in the CSP_LAUNCH_PWD session env var (see csp_tmux_enter). We
# read it live here so `n` follows where you actually re-attached from. Falls
# back to the picker's own $PWD when unset/unreadable or the dir no longer exists.
csp_tmux_launch_pwd() {
  local d
  # When set, tmux prints "CSP_LAUNCH_PWD=/the/path" on stdout; when unset it
  # prints "unknown variable: …" to stderr and exits non-zero. We send stderr to
  # /dev/null, so an unset var yields an empty $d. Stripping only the "NAME="
  # prefix preserves a path that itself contains '='. Any empty/invalid result,
  # or a directory that no longer exists, falls back to the picker's own $PWD.
  d=$(csp_tmux show-environment -t "=$CSP_TMUX_SESSION" CSP_LAUNCH_PWD 2>/dev/null)
  d="${d#CSP_LAUNCH_PWD=}"
  [ -n "$d" ] && [ -d "$d" ] || d="$PWD"
  printf '%s' "$d"
}

# csp_tmux_window_for_sid ID — print the tmux window id (on OUR holding session)
# whose @csp_sid tag exactly equals ID, or nothing. Each list line is
# "<window_id> <sid>"; awk compares the WHOLE second field ($2 == want) so an id
# can never match a window whose tag merely contains it (e.g. "id-a" won't match
# "id-abc"), and the empty tag on the menu window can't match a real id. awk
# (not a `while read` subshell) keeps the id out of any glob and reads cleanly
# under errexit. Used BOTH to dedup an open (switch instead of a second copy) and
# by the delete guard (a session with a live window must not be deleted, whatever
# its hook state — a bare `n` session that's merely "waiting" is still in use).
csp_tmux_window_for_sid() {
  local id="$1"
  [ -n "$id" ] && [ "$id" != "new" ] || return 0
  csp_tmux_available || return 0
  csp_tmux list-windows -t "=$CSP_TMUX_SESSION" \
    -F '#{window_id} #{@csp_sid}' 2>/dev/null \
    | awk -v want="$id" '$2 == want {print $1; exit}'
}

# csp_tmux_open ID PROJECT LABEL
#
# Open a session in its OWN tmux window and switch to it, WITHOUT killing the
# picker — the picker stays in window 0. Other windows keep running in the
# background; that is the concurrency the tmux backend exists to give.
#
#   ID       session id to resume, or "new" for a fresh session
#   PROJECT  working directory to start in (optional)
#   LABEL    short human name for the tmux window (sanitized here)
#
# Returns 0 on success, NON-ZERO if the window could not be created or focused
# (the caller falls back to hub for that one launch). ID/PROJECT come from our
# own session files and are single-quoted, so there is no room for shell
# injection. This assumes we are already inside the holding tmux session (the
# picker put itself there via csp_tmux_enter at startup).
csp_tmux_open() {
  local id="$1" project="$2" label="$3" cmd win existing

  label=$(csp_tmux_sanitize_label "$label")

  # Don't open a SECOND window for a session already running in this holding
  # session: resuming the same transcript twice means two Claude processes
  # writing the same conversation. Each session window is tagged with a
  # `@csp_sid` window option (set below); if one already carries this id, just
  # switch to it. Only meaningful for a real resume — a brand-new session ("new")
  # has no id yet, so it always opens fresh.
  if [ "$id" != "new" ]; then
    existing=$(csp_tmux_window_for_sid "$id")
    if [ -n "$existing" ]; then
      csp_tmux select-window -t "$existing" 2>/dev/null && return 0
      # If selecting the existing window somehow failed, fall through and open a
      # fresh one rather than leaving the user stuck.
    fi
  fi

  # Compose the shell command the new window will run.
  if [ -n "$project" ] && [ -d "$project" ]; then
    cmd="cd $(csp_shell_quote "$project") && "
  else
    cmd=""
  fi
  if [ "$id" = "new" ]; then
    cmd="${cmd}claude"
  else
    cmd="${cmd}claude --resume $(csp_shell_quote "$id")"
  fi

  # Open the session in a new window on our socket (target the holding session
  # explicitly so it lands there even if the caller's notion of "current" drifts)
  # and select it. -P -F prints the new window id so we select exactly it. The
  # picker's own loop keeps running in window 0 the whole time.
  win=$(csp_tmux new-window -t "=$CSP_TMUX_SESSION" -P -F '#{window_id}' -n "$label" "$cmd" 2>/dev/null) \
    || return 1
  # Tag the window with the session id so a later Enter on the same session finds
  # and reuses it (see the dedup check above). Best-effort: a failed tag only
  # means we might later open a duplicate, never a crash.
  [ "$id" != "new" ] && csp_tmux set-option -w -t "$win" '@csp_sid' "$id" 2>/dev/null
  csp_tmux select-window -t "$win" 2>/dev/null || return 1
  return 0
}

# csp_shell_quote STRING — wrap STRING in single quotes for safe use inside a
# command line we hand to tmux, escaping any embedded single quotes. This is
# what guarantees a path or id can never break out of its argument.
csp_shell_quote() {
  local s="$1"
  # Replace every ' with the standard '\'' sequence, then wrap the whole thing.
  s=$(printf '%s' "$s" | sed "s/'/'\\\\''/g")
  printf "'%s'" "$s"
}
