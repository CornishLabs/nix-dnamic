#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Error: ${BASH_SOURCE[0]}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

read -r -d '' ABOUT <<'EOF' || true
artiq-lab-tmux.sh — ARTIQ “lab” launcher via tmux

This script creates/attaches to a tmux session (on a dedicated tmux socket) and
starts ARTIQ-related processes in separate windows. Each window prints a small
debug banner at the top showing key environment details (Nix dev-shell markers,
PATH, VIRTUAL_ENV, PYTHONPATH, and what Python resolves to) before running the
actual program.

Windows created:
  - master     : ARTIQ master
  - ctlmgr     : ARTIQ controller manager
  - janitor    : ndscan dataset janitor
  - dashboard  : ARTIQ dashboard
  - shell      : interactive bash with venv activated + debug banner

Startup order (only when the session is newly created, or when a window was missing):
  1) master (wait until "ARTIQ master is now ready." or timeout)
  2) ctlmgr (then wait WAIT seconds)
  3) janitor (then wait WAIT seconds)
  4) dashboard

Output on crash:
  - The session enables `remain-on-exit on` so panes stay visible after exit.

Usage:
  artiq-lab-tmux.sh [--help]

Controls (env vars):
  SESSION               Session name (default: artiq)
  REPO_ROOT             Working directory for windows (default: current directory)
  SCRATCH_DIR           Scratch path (default: ~/scratch)
  VENV_NAME             Venv name under $SCRATCH_DIR/nix-artiq-venvs (default: artiq-master-dev)
  VENV_PATH             Override full venv path (default derived from SCRATCH_DIR+VENV_NAME)
  WAIT                  Seconds between ctlmgr/janitor/dashboard startups (default: 5)
  MASTER_READY_TIMEOUT  Seconds to wait for readiness line (default: 60)

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

# Stable tmux socket path (avoid /tmp staleness)
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
export VENV_PATH

if [[ ! -x "$VENV_PATH/bin/python" ]]; then
  echo "Error: expected venv python at: $VENV_PATH/bin/python" >&2
  echo "Are you inside 'nix develop' (so the shellHook creates/activates the venv)?" >&2
  exit 1
fi

export VIRTUAL_ENV="$VENV_PATH"
export PATH="$VENV_PATH/bin${PATH:+:$PATH}"

PY="$VENV_PATH/bin/python"
export ARTIQ_PY="$PY"

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

if [[ -x "$VENV_PATH/bin/ndscan_dataset_janitor" ]]; then
  CMD_JANITOR=( "$VENV_PATH/bin/ndscan_dataset_janitor" )
else
  CMD_JANITOR=( ndscan_dataset_janitor )
fi

push_env() {
  for VAR in PYTHONPATH SCRATCH_DIR QT_PLUGIN_PATH QML2_IMPORT_PATH \
             VIRTUAL_ENV VENV_PATH PATH PYTHONUNBUFFERED ARTIQ_PY IN_NIX_SHELL; do
    [[ -n "${!VAR-}" ]] && "${TMUX[@]}" setenv -g "$VAR" "${!VAR}"
  done
}

window_exists() {
  local name="$1"
  [[ -n "$("${TMUX[@]}" list-windows -t "$SESSION" -F '#{window_name}' \
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

# This runs inside each pane before the real command.
read -r -d '' RUNNER <<'BASH' || true
set -euo pipefail
win="$1"; shift

printf "\n=== [%s] ===\n" "$win"
printf "----- DEBUG -----\n"
printf "pwd=%s\n" "$PWD"
printf "user=%s uid=%s\n" "${USER-}" "$(id -u 2>/dev/null || echo '?')"
printf "IN_NIX_SHELL=%s\n" "${IN_NIX_SHELL-}"
printf "SCRATCH_DIR=%s\n" "${SCRATCH_DIR-}"
printf "VENV_PATH=%s\n" "${VENV_PATH-}"
printf "VIRTUAL_ENV=%s\n" "${VIRTUAL_ENV-}"
printf "ARTIQ_PY=%s\n" "${ARTIQ_PY-}"
printf "PYTHONPATH=%s\n" "${PYTHONPATH-}"
printf "PATH=%s\n" "${PATH-}"
printf "python(PATH)="; command -v python 2>/dev/null || echo "not-found"
printf "python(VENV)=";  [[ -n "${ARTIQ_PY-}" ]] && echo "$ARTIQ_PY" || echo "not-set"

# Python details (best-effort; don't fail the pane if these error)
python -c 'import sys; print("sys.executable:", sys.executable); print("sys.prefix:", sys.prefix); print("sys.base_prefix:", getattr(sys,"base_prefix",""))' 2>/dev/null || true
"${ARTIQ_PY:-python}" -c 'import sys; print("venv sys.executable:", sys.executable)' 2>/dev/null || true
"${ARTIQ_PY:-python}" -c 'import artiq; print("artiq.__version__:", getattr(artiq,"__version__", "?"))' 2>/dev/null || true

printf "cmd: "; printf "%q " "$@"; printf "\n"
printf "-----------------\n\n"

exec "$@"
BASH

# Respawn pane to run a command (argv) without a login shell (avoids PATH resets)
start_in_window() {
  local name="$1"; shift
  "${TMUX[@]}" respawn-pane -k -t "$SESSION:$name" -c "$REPO_ROOT" \
    bash -c "$RUNNER" _ "$name" "$@"
}

# Wait until master prints readiness line (only used right after we start master)
wait_for_master_ready() {
  local timeout="${MASTER_READY_TIMEOUT:-60}"
  local needle='ARTIQ master is now ready.'
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if "${TMUX[@]}" capture-pane -pt "$SESSION:master" -S -4000 2>/dev/null | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.2
  done
  echo "Warning: did not see master readiness line within ${timeout}s; continuing." >&2
  return 1
}

# Create a rcfile for the interactive "shell" window: source ~/.bashrc, activate venv, print debug.
SHELL_RC="$SOCK_DIR/${SESSION}-shellrc"
cat >"$SHELL_RC" <<EOF
# Generated by artiq-lab-tmux.sh for tmux window: shell
# Keep user's usual interactive settings:
[ -f "\$HOME/.bashrc" ] && source "\$HOME/.bashrc"

# Activate venv for prompt + functions:
if [ -f "$VENV_PATH/bin/activate" ]; then
  source "$VENV_PATH/bin/activate"
fi

# Debug banner (runs once at shell startup):
printf "\n=== [shell] ===\n"
printf "----- DEBUG -----\n"
printf "pwd=%s\n" "\$PWD"
printf "user=%s uid=%s\n" "\${USER-}" "\$(id -u 2>/dev/null || echo '?')"
printf "IN_NIX_SHELL=%s\n" "\${IN_NIX_SHELL-}"
printf "SCRATCH_DIR=%s\n" "\${SCRATCH_DIR-}"
printf "VENV_PATH=%s\n" "\${VENV_PATH-}"
printf "VIRTUAL_ENV=%s\n" "\${VIRTUAL_ENV-}"
printf "ARTIQ_PY=%s\n" "\${ARTIQ_PY-}"
printf "PYTHONPATH=%s\n" "\${PYTHONPATH-}"
printf "PATH=%s\n" "\${PATH-}"
printf "python(PATH)="; command -v python 2>/dev/null || echo "not-found"
python -c 'import sys; print("sys.executable:", sys.executable); print("sys.prefix:", sys.prefix); print("sys.base_prefix:", getattr(sys,"base_prefix",""))' 2>/dev/null || true
python -c 'import artiq; print("artiq.__version__:", getattr(artiq,"__version__", "?"))' 2>/dev/null || true
printf "-----------------\n\n"
EOF

created_session=0
if ! "${TMUX[@]}" -q has-session -t "$SESSION" >/dev/null 2>&1; then
  "${TMUX[@]}" new-session -d -s "$SESSION" -n master -c "$REPO_ROOT"
  created_session=1
fi

push_env

# Session options: keep output after exit; stable names; lots of scrollback; avoid login shells.
"${TMUX[@]}" set-option -t "$SESSION" -g remain-on-exit on >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g allow-rename off >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g history-limit 20000 >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g default-command "${SHELL:-/bin/bash}" >/dev/null

# Ensure windows exist up-front (and track which ones were newly created)
ensure_window master     || true; created_master=$?
ensure_window ctlmgr     || true; created_ctlmgr=$?
ensure_window janitor    || true; created_janitor=$?
ensure_window dashboard  || true; created_dash=$?
ensure_window shell      || true; created_shell=$?

should_start() {
  local created_rc="$1"
  [[ "$created_session" -eq 1 || "$created_rc" -eq 0 ]]
}

# Start in order (master readiness gating helps when only ctlmgr/janitor/dashboard were missing too)
if should_start "$created_master"; then
  start_in_window master "${CMD_MASTER[@]}"
fi

# Ensure master is ready (or at least had a chance) before ctlmgr
wait_for_master_ready || sleep "$WAIT"

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

# Interactive dev shell window (only if it was missing/new)
if should_start "$created_shell"; then
  "${TMUX[@]}" respawn-pane -k -t "$SESSION:shell" -c "$REPO_ROOT" \
    bash --rcfile "$SHELL_RC" -i
fi

# Attach (or switch) robustly:
if [[ -n "${TMUX-}" && "${TMUX%%,*}" == "$SOCK" ]]; then
  exec "${TMUX[@]}" switch-client -t "$SESSION"
else
  exec "${TMUX[@]}" attach -t "$SESSION"
fi
