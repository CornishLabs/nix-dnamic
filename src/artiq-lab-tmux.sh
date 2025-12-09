#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Error: ${BASH_SOURCE[0]}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

read -r -d '' ABOUT <<'EOF' || true
artiq-lab-tmux.sh — ARTIQ “lab” launcher via tmux

What it does:
  1) Chooses a dedicated tmux server socket (not /tmp) so the tmux server is
     stable across crashes/reboots/tmp cleaners. The socket lives at:
         ${XDG_RUNTIME_DIR:-$SCRATCH_DIR/.run}/tmux-${SESSION}.sock

  2) Detects and removes a *stale* tmux socket:
       - If the socket file exists but no tmux server responds, tmux will print
         “no server running on ...”.
       - This script treats that as a stale socket and deletes it.

  3) Creates (if needed) a tmux session called $SESSION with four windows:
       - master     (artiq_master)
       - ctlmgr     (artiq_ctlmgr)
       - janitor    (ndscan_dataset_janitor)
       - dashboard  (artiq_dashboard ...)

  4) Copies important environment variables from your current shell into the tmux
     server (PYTHONPATH, SCRATCH_DIR, QT paths, VIRTUAL_ENV, PATH). This is
     important when you're inside `nix develop` + an activated venv.

  5) Starts the commands in order with a delay between each, but only when the
     session is first created (or when a specific window is missing):
       master -> wait -> ctlmgr -> wait -> janitor -> wait -> dashboard

  6) Ensures output remains visible if a program crashes/exits:
       - It enables tmux option `remain-on-exit on`, so the pane stays showing
         the last output instead of disappearing.

Usage:
  artiq-lab-tmux.sh [--help]

Controls (env vars):
  SESSION      Session name (default: artiq)
  REPO_ROOT    Working directory for windows (default: current directory)
  SCRATCH_DIR  Scratch path (default: ~/scratch)
  WAIT         Seconds between startups (default: 5)

Notes:
  - If the session already exists, this script will NOT restart running programs.
  - If you delete/close a window, re-running the script will recreate that window
    and start its program.
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
WAIT="${WAIT:-5}"

# Stable tmux socket path (avoid /tmp staleness)
SOCK_DIR="${XDG_RUNTIME_DIR:-$SCRATCH_DIR/.run}"
mkdir -p "$SOCK_DIR"
SOCK="$SOCK_DIR/tmux-${SESSION}.sock"

TMUX=(tmux -S "$SOCK" -u -2)

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

# Commands
CMD_MASTER='python -m artiq.frontend.artiq_master'
CMD_CTLMGR='python -m artiq_comtools.artiq_ctlmgr'
CMD_JANITOR='ndscan_dataset_janitor'
CMD_DASH='python -m artiq.frontend.artiq_dashboard -p ndscan.dashboard_plugin'

push_env() {
  for VAR in PYTHONPATH SCRATCH_DIR QT_PLUGIN_PATH QML2_IMPORT_PATH VIRTUAL_ENV PATH; do
    [[ -n "${!VAR-}" ]] && "${TMUX[@]}" setenv -g "$VAR" "${!VAR}"
  done
}

window_exists() {
  local name="$1"
  [[ -n "$("${TMUX[@]}" list-windows -t "$SESSION" -F '#W' \
      -f "#{==:#{window_name},$name}" 2>/dev/null)" ]]
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

start_in_window() {
  local name="$1" cmd="$2"
  "${TMUX[@]}" respawn-pane -k -t "$SESSION:$name" -c "$REPO_ROOT" \
    "bash -lc 'printf \"\n=== [%s] ===\n%s\n\n\" \"$name\" \"$cmd\"; exec $cmd'"
}

created_session=0
if ! "${TMUX[@]}" -q has-session -t "$SESSION" >/dev/null 2>&1; then
  "${TMUX[@]}" new-session -d -s "$SESSION" -n master -c "$REPO_ROOT"
  created_session=1
fi

push_env

# Keep panes visible if the command exits/crashes; keep names stable
"${TMUX[@]}" set-option -t "$SESSION" -g remain-on-exit on >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g allow-rename off >/dev/null

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
  start_in_window master "$CMD_MASTER"
  sleep "$WAIT"
fi
if should_start "$created_ctlmgr"; then
  start_in_window ctlmgr "$CMD_CTLMGR"
  sleep "$WAIT"
fi
if should_start "$created_janitor"; then
  start_in_window janitor "$CMD_JANITOR"
  sleep "$WAIT"
fi
if should_start "$created_dash"; then
  start_in_window dashboard "$CMD_DASH"
fi

# Attach (or switch) robustly:
# - switch-client only if we're already inside *this* tmux server (same socket)
# - otherwise attach (may create a nested tmux if you're inside a different one)
if [[ -n "${TMUX-}" && "${TMUX%%,*}" == "$SOCK" ]]; then
  exec "${TMUX[@]}" switch-client -t "$SESSION"
else
  exec "${TMUX[@]}" attach -t "$SESSION"
fi
