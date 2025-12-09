#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Error: ${BASH_SOURCE[0]}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

read -r -d '' ABOUT <<'EOF' || true
artiq-lab-tmux.sh — ARTIQ “lab” launcher via tmux

What it does:
  1) Uses a dedicated tmux server socket (not /tmp) to avoid stale /tmp sockets and
     to isolate this ARTIQ session from your “normal” tmux.
     Socket path:
         ${XDG_RUNTIME_DIR:-$SCRATCH_DIR/.run}/tmux-${SESSION}.sock

  2) Detects and removes a *stale* tmux socket:
       - If the socket file exists but no tmux server responds, tmux prints
         “no server running on ...”.
       - This script treats that as a stale socket and deletes it.

  3) Creates (if needed) a tmux session called $SESSION with four windows:
       - master     (artiq_master)
       - ctlmgr     (artiq_ctlmgr)
       - janitor    (ndscan_dataset_janitor)
       - dashboard  (artiq_dashboard ...)

  4) Makes command execution robust with respect to your nested venv:
       - It finds your nested venv under:
           $SCRATCH_DIR/nix-artiq-venvs/$VENV_NAME
       - It runs *that venv’s* python explicitly (absolute path), rather than relying on PATH.
       - It also prepends $VENV_PATH/bin to PATH and pushes env vars into tmux.

  5) Starts the commands in order, but only when the session is first created or
     when a specific window is missing and had to be recreated:
       - start master
       - wait until master prints "ARTIQ master is now ready." (or timeout, then fallback sleep)
       - start ctlmgr
       - wait WAIT seconds
       - start janitor
       - wait WAIT seconds
       - start dashboard

  6) Keeps output visible if a program crashes/exits:
       - Enables tmux option `remain-on-exit on`.

Usage:
  artiq-lab-tmux.sh [--help]

Controls (env vars):
  SESSION               Session name (default: artiq)
  REPO_ROOT             Working directory for windows (default: current directory)
  SCRATCH_DIR           Scratch path (default: ~/scratch)
  VENV_NAME             Venv name under $SCRATCH_DIR/nix-artiq-venvs (default: artiq-master-dev)
  VENV_PATH             Override full venv path (default derived from SCRATCH_DIR+VENV_NAME)
  WAIT                  Seconds between startups (default: 5)
  MASTER_READY_TIMEOUT  Seconds to wait for "master ready" line (default: 60)

Notes:
  - If the session already exists, this script will NOT restart running programs.
  - If you delete/close a window, re-running the script recreates that window and starts it.
EOF

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "$ABOUT"
  exit 0
elif [[ "${1:-}" != "" ]]; then
  echo "Unknown argument: $1" >&2
  echo "Try: --help" >&2
  exit 2
fi

SESSION="${SESSION:-artiq}"
REPO_ROOT="${REPO_ROOT:-$PWD}"
: "${SCRATCH_DIR:=$HOME/scratch}"
: "${WAIT:=5}"

# Prefer stable socket location (avoid /tmp staleness)
SOCK_DIR="${XDG_RUNTIME_DIR:-$SCRATCH_DIR/.run}"
mkdir -p "$SOCK_DIR"
SOCK="$SOCK_DIR/tmux-${SESSION}.sock"

TMUX=(tmux -S "$SOCK" -u -2)

# Ensure Python flushes output promptly (helps readiness + logs)
: "${PYTHONUNBUFFERED:=1}"
export PYTHONUNBUFFERED

# --- Venv resolution (robust: use absolute venv python) ---
VENV_NAME="${VENV_NAME:-artiq-master-dev}"
VENV_PATH="${VENV_PATH:-$SCRATCH_DIR/nix-artiq-venvs/$VENV_NAME}"

if [[ ! -x "$VENV_PATH/bin/python" ]]; then
  echo "Error: expected venv python at: $VENV_PATH/bin/python" >&2
  echo "Are you inside 'nix develop' (so the shellHook creates/activates the venv)?" >&2
  exit 1
fi

export VENV_PATH
export VIRTUAL_ENV="$VENV_PATH"
export PATH="$VENV_PATH/bin${PATH:+:$PATH}"

PY="$VENV_PATH/bin/python"

# Make ARTIQ processes see scratch + repo on sys.path.
export PYTHONPATH="${SCRATCH_DIR}:$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}"

# Refuse to touch non-sockets
if [[ -e "$SOCK" && ! -S "$SOCK" ]]; then
  echo "Error: $SOCK exists but is not a socket (won't touch it)." >&2
  ls -l "$SOCK" >&2 || true
  exit 1
fi

# Remove stale socket (socket exists, but no server responds)
if [[ -S "$SOCK" ]] && ! "${TMUX[@]}" -q list-sessions >/dev/null 2>&1; then
  echo "Found stale tmux socket at $SOCK; removing it."
  rm -f "$SOCK"
fi

# Commands (use venv python explicitly)
CMD_MASTER=( "$PY" -u -m artiq.frontend.artiq_master )
CMD_CTLMGR=( "$PY"    -m artiq_comtools.artiq_ctlmgr )
CMD_DASH=(   "$PY"    -m artiq.frontend.artiq_dashboard -p ndscan.dashboard_plugin )

# Prefer janitor entrypoint from venv if it exists, else fall back to PATH
if [[ -x "$VENV_PATH/bin/ndscan_dataset_janitor" ]]; then
  CMD_JANITOR=( "$VENV_PATH/bin/ndscan_dataset_janitor" )
else
  CMD_JANITOR=( ndscan_dataset_janitor )
fi

push_env() {
  for VAR in PYTHONPATH SCRATCH_DIR QT_PLUGIN_PATH QML2_IMPORT_PATH VIRTUAL_ENV VENV_PATH PATH PYTHONUNBUFFERED; do
    [[ -n "${!VAR-}" ]] && "${TMUX[@]}" setenv -g "$VAR" "${!VAR}"
  done
}

window_exists() {
  local name="$1"
  "${TMUX[@]}" list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$name"
}

# Ensure window exists; return 0 if created, 1 if already existed
ensure_window() {
  local name="$1"
  if window_exists "$name"; then
    return 1
  fi
  "${TMUX[@]}" new-window -d -t "$SESSION" -n "$name" -c "$REPO_ROOT"
  return 0
}

# Respawn pane to run a command (argv) without a login shell (avoids PATH resets)
start_in_window() {
  local name="$1"; shift

  # Double quotes + \$… means $1/$@ are expanded by the *inner* bash, not this script.
  local inner
  inner="printf \"\n=== [%s] ===\n\" \"\$1\"; shift; \
printf \"cmd: \"; printf \"%q \" \"\$@\"; printf \"\n\n\"; \
exec \"\$@\""

  local -a bash_argv=(
    bash -c "$inner"
    _ "$name" "$@"
  )

  local cmdline
  cmdline="$(printf '%q ' "${bash_argv[@]}")"

  "${TMUX[@]}" respawn-pane -k -t "$SESSION:$name" -c "$REPO_ROOT" "$cmdline"
}


# Wait until master prints readiness line (only used right after we start master)
wait_for_master_ready() {
  local timeout="${MASTER_READY_TIMEOUT:-60}"  # seconds
  local needle='ARTIQ master is now ready.'
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if "${TMUX[@]}" capture-pane -pt "$SESSION:master" -S -2000 2>/dev/null | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.2
  done
  echo "Warning: did not see master readiness line within ${timeout}s; continuing." >&2
  return 1
}

created_session=0
if ! "${TMUX[@]}" -q has-session -t "$SESSION" >/dev/null 2>&1; then
  "${TMUX[@]}" new-session -d -s "$SESSION" -n master -c "$REPO_ROOT"
  created_session=1
fi

push_env

# Keep panes visible if the command exits/crashes; keep names stable; keep more scrollback
"${TMUX[@]}" set-option -t "$SESSION" -g remain-on-exit on >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g allow-rename off >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g history-limit 20000 >/dev/null

# Ensure windows exist up-front (and track which ones were newly created)
ensure_window master     || true; created_master=$?
ensure_window ctlmgr     || true; created_ctlmgr=$?
ensure_window janitor    || true; created_janitor=$?
ensure_window dashboard  || true; created_dash=$?

# Start only on fresh session, or for windows that were missing and had to be created.
should_start() {
  local created_rc="$1"
  [[ "$created_session" -eq 1 || "$created_rc" -eq 0 ]]
}

if should_start "$created_master"; then
  start_in_window master "${CMD_MASTER[@]}"
  wait_for_master_ready || sleep "$WAIT"
fi
if should_start "$created_ctlmgr"; then
  start_in_window ctlmgr "${CMD_CTLMGR[@]}"
  sleep "$WAIT"
fi
if should_start "$created_janitor"; then
  start_in_window janitor "${CMD_JANITOR[@]}"
  sleep "$WAIT"
fi
if should_start "$created_dash"; then
  start_in_window dashboard "${CMD_DASH[@]}"
fi

# Attach (or switch) robustly:
# - switch-client only if we're already inside *this* tmux server (same socket)
# - otherwise attach (may create a nested tmux if you're inside a different one)
if [[ -n "${TMUX-}" && "${TMUX%%,*}" == "$SOCK" ]]; then
  exec "${TMUX[@]}" switch-client -t "$SESSION"
else
  exec "${TMUX[@]}" attach -t "$SESSION"
fi
