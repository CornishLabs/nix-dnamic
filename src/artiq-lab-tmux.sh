#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Error: ${BASH_SOURCE[0]}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

read -r -d '' ABOUT <<'EOF' || true
artiq-lab-tmux.sh — ARTIQ “lab” launcher via tmux (Option A: Nix dev shell owns env)

Principle:
  - You run this from inside `nix develop` (your shellHook activates the venv and sets PATH/PYTHONPATH).
  - This script does NOT try to “re-create” that environment; it just:
      * reuses it,
      * pushes it into tmux so new panes inherit it,
      * runs ARTIQ with the venv python explicitly.

What it does:
  1) Uses a dedicated tmux socket (not /tmp) to avoid stale tmp sockets:
       ${XDG_RUNTIME_DIR:-$SCRATCH_DIR/.run}/tmux-${SESSION}.sock

  2) Deletes a stale socket if it exists but no tmux server responds.

  3) Creates/attaches to tmux session $SESSION and ensures windows:
       - master, ctlmgr, janitor, dashboard, shell

  4) Prints a debug banner at the top of each program pane (env + python info).

  5) Starts in order when the session is first created (or a window was missing):
       master -> wait for readiness line (or timeout) -> ctlmgr -> wait -> janitor -> wait -> dashboard

  6) Enables `remain-on-exit on` so crashed panes stay visible.

Usage:
  artiq-lab-tmux.sh [--help]

Controls:
  SESSION, REPO_ROOT, SCRATCH_DIR, WAIT, MASTER_READY_TIMEOUT
  VENV_NAME (default: artiq-master-dev)
  VENV_PATH (override full venv path; default: $SCRATCH_DIR/nix-artiq-venvs/$VENV_NAME)

Notes:
  - If session already exists, it will NOT restart running programs.
  - If you close a window, rerun the script to recreate/start it.
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

# Make Python flush promptly (helps readiness + logs)
: "${PYTHONUNBUFFERED:=1}"
export PYTHONUNBUFFERED

# Do NOT modify PATH/PYTHONPATH in ways that duplicate shellHook work.
# We only ensure the repo is on PYTHONPATH (shellHook already puts SCRATCH_DIR there).
prepend_unique() {
  local dir="$1" var="$2"
  local cur="${!var-}"
  [[ -z "$dir" ]] && return 0
  case ":$cur:" in
    *":$dir:"*) ;;  # already present
    *) printf -v "$var" '%s' "$dir${cur:+:$cur}" ;;
  esac
}

prepend_unique "$REPO_ROOT" PYTHONPATH
export PYTHONPATH

# --- Venv resolution (robust: use absolute venv python for ARTIQ processes) ---
VENV_NAME="${VENV_NAME:-artiq-master-dev}"
VENV_PATH="${VENV_PATH:-$SCRATCH_DIR/nix-artiq-venvs/$VENV_NAME}"
export VENV_PATH

# Prefer the active venv if present (best signal that you're in nix develop + shellHook)
if [[ -n "${VIRTUAL_ENV-}" ]]; then
  VENV_PATH="$VIRTUAL_ENV"
  export VENV_PATH
fi

if [[ ! -x "$VENV_PATH/bin/python" ]]; then
  echo "Error: expected venv python at: $VENV_PATH/bin/python" >&2
  echo "Run this inside 'nix develop' (so the shellHook creates/activates the venv), or set VENV_PATH." >&2
  exit 1
fi

PY="$VENV_PATH/bin/python"
export ARTIQ_PY="$PY"

# Refuse to touch non-sockets
if [[ -e "$SOCK" && ! -S "$SOCK" ]]; then
  echo "Error: $SOCK exists but is not a socket (won't touch it)." >&2
  ls -l "$SOCK" >&2 || true
  exit 1
fi

# Remove stale socket
if [[ -S "$SOCK" ]] && ! "${TMUX[@]}" -q list-sessions >/dev/null 2>&1; then
  echo "Found stale tmux socket at $SOCK; removing it."
  rm -f "$SOCK"
fi

# Commands (use venv python explicitly)
CMD_MASTER=( "$PY" -u -m artiq.frontend.artiq_master )
CMD_CTLMGR=( "$PY"    -m artiq_comtools.artiq_ctlmgr )
CMD_DASH=(   "$PY"    -m artiq.frontend.artiq_dashboard -p ndscan.dashboard_plugin )

# Prefer janitor entrypoint from venv if it exists
if [[ -x "$VENV_PATH/bin/ndscan_dataset_janitor" ]]; then
  CMD_JANITOR=( "$VENV_PATH/bin/ndscan_dataset_janitor" )
else
  CMD_JANITOR=( ndscan_dataset_janitor )
fi

push_env() {
  # Push “what nix develop gave us” into tmux, so new panes inherit it.
  for VAR in PYTHONPATH SCRATCH_DIR QT_PLUGIN_PATH QML2_IMPORT_PATH \
             VIRTUAL_ENV PATH PYTHONUNBUFFERED IN_NIX_SHELL \
             VENV_PATH ARTIQ_PY; do
    [[ -n "${!VAR-}" ]] && "${TMUX[@]}" setenv -g "$VAR" "${!VAR}"
  done
}

window_exists() {
  local name="$1"
  [[ -n "$("${TMUX[@]}" list-windows -t "$SESSION" -F '#{window_name}' \
      -f "#{==:#{window_name},$name}" 2>/dev/null)" ]]
}

ensure_window() {
  local name="$1"
  if window_exists "$name"; then
    return 1
  fi
  "${TMUX[@]}" new-window -d -t "$SESSION" -n "$name" -c "$REPO_ROOT"
  return 0
}

# Runner prints debug then execs the command.
read -r -d '' RUNNER <<'BASH' || true
set -euo pipefail
win="$1"; shift

printf "\n=== [%s] ===\n" "$win"
printf -- "----- DEBUG -----\n"
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
printf "python(ARTIQ_PY)=%s\n" "${ARTIQ_PY-}"

python -c 'import sys; print("sys.executable:", sys.executable); print("sys.prefix:", sys.prefix); print("sys.base_prefix:", getattr(sys,"base_prefix",""))' 2>/dev/null || true
"${ARTIQ_PY:-python}" -c 'import artiq; print("artiq.__version__:", getattr(artiq,"__version__","?"))' 2>/dev/null || true

printf "cmd: "; printf "%q " "$@"; printf "\n"
printf -- "-----------------\n\n"

exec "$@"
BASH

start_in_window() {
  local name="$1"; shift
  "${TMUX[@]}" respawn-pane -k -t "$SESSION:$name" -c "$REPO_ROOT" \
    bash -c "$RUNNER" _ "$name" "$@"
}

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

# Interactive shell window: source ~/.bashrc and (optionally) activate venv for prompt.
SHELL_RC="$SOCK_DIR/${SESSION}-shellrc"
cat >"$SHELL_RC" <<EOF
[ -f "\$HOME/.bashrc" ] && source "\$HOME/.bashrc"
# Cosmetic activation for prompt/functions only (avoid re-activating if already active)
if [ -n "${VENV_PATH}" ] && [ "\${VIRTUAL_ENV-}" != "${VENV_PATH}" ] && [ -f "${VENV_PATH}/bin/activate" ]; then
  source "${VENV_PATH}/bin/activate"
fi
printf "\n=== [shell] ===\n"
printf -- "----- DEBUG -----\n"
printf "IN_NIX_SHELL=%s\n" "\${IN_NIX_SHELL-}"
printf "VIRTUAL_ENV=%s\n" "\${VIRTUAL_ENV-}"
printf "PYTHONPATH=%s\n" "\${PYTHONPATH-}"
printf "python(PATH)="; command -v python 2>/dev/null || echo "not-found"
python -c 'import sys; print("sys.executable:", sys.executable)' 2>/dev/null || true
printf -- "-----------------\n\n"
EOF

created_session=0
if ! "${TMUX[@]}" -q has-session -t "$SESSION" >/dev/null 2>&1; then
  "${TMUX[@]}" new-session -d -s "$SESSION" -n master -c "$REPO_ROOT"
  created_session=1
fi

push_env

# Session options
"${TMUX[@]}" set-option -t "$SESSION" -g remain-on-exit on >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g allow-rename off >/dev/null
"${TMUX[@]}" set-option -t "$SESSION" -g history-limit 20000 >/dev/null
# Avoid login shells (they often reset PATH via /etc/profile, ~/.profile, etc.)
"${TMUX[@]}" set-option -t "$SESSION" -g default-command "${SHELL:-/bin/bash}" >/dev/null

# Ensure windows exist (track which were created)
ensure_window master     || true; created_master=$?
ensure_window ctlmgr     || true; created_ctlmgr=$?
ensure_window janitor    || true; created_janitor=$?
ensure_window dashboard  || true; created_dash=$?
ensure_window shell      || true; created_shell=$?

should_start() {
  local created_rc="$1"
  [[ "$created_session" -eq 1 || "$created_rc" -eq 0 ]]
}

# Start in order
if should_start "$created_master"; then
  start_in_window master "${CMD_MASTER[@]}"
fi

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

if should_start "$created_shell"; then
  "${TMUX[@]}" respawn-pane -k -t "$SESSION:shell" -c "$REPO_ROOT" \
    bash --rcfile "$SHELL_RC" -i
fi

# Attach / switch
if [[ -n "${TMUX-}" && "${TMUX%%,*}" == "$SOCK" ]]; then
  exec "${TMUX[@]}" switch-client -t "$SESSION"
else
  exec "${TMUX[@]}" attach -t "$SESSION"
fi
