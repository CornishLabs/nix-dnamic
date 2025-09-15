set -euo pipefail

# Where device_db.py & your repo live (override with REPO_ROOT=...).
REPO_ROOT="${REPO_ROOT:-$PWD}"

# Make ARTIQ processes see both scratch + repo on sys.path.
export PYTHONPATH="${SCRATCH_DIR:-}:$REPO_ROOT:${PYTHONPATH:-}"

# Always use a private tmux socket and UTF-8/256-color.
TMUX_BASE=(tmux -L artiq -u -2)
SESSION="artiq"

# Commands for each window (easy to read/modify)
CMD_MASTER='python -m artiq.frontend.artiq_master'
CMD_JANITOR='ndscan_dataset_janitor'
CMD_CTLMGR='python -m artiq_comtools.artiq_ctlmgr'
CMD_DASH='python -m artiq.frontend.artiq_dashboard -p ndscan.dashboard_plugin'

# Create the session if it doesn't exist (this also starts the server)
if ! "${TMUX_BASE[@]}" has-session -t "$SESSION" 2>/dev/null; then
  "${TMUX_BASE[@]}" new-session -d -s "$SESSION" -n master -c "$REPO_ROOT"

  # Push env BEFORE launching long processes so panes inherit it
  for VAR in PYTHONPATH SCRATCH_DIR QT_PLUGIN_PATH QML2_IMPORT_PATH VIRTUAL_ENV PATH; do
    if [ -n "${!VAR-}" ]; then
      "${TMUX_BASE[@]}" set-environment -g "$VAR" "${!VAR}"
    fi
  done

  # Helper to spawn a window/pane that prints its command, then execs it
  run_cmd() {
    local target="$1" title="$2" workdir="$3" cmd="$4"
    "${TMUX_BASE[@]}" "$target" -n "$title" -c "$workdir" \
      "bash -lc 'printf \"\\n=== [%s] ===\\n%s\\n\\n\" \"$title\" \"$cmd\"; echo \"PYTHONPATH=\$PYTHONPATH\"; exec $cmd'"
  }

  # Master (respawn into the first window)
  "${TMUX_BASE[@]}" respawn-pane -k -t "$SESSION":master \
    "bash -lc 'printf \"\\n=== [%s] ===\\n%s\\n\\n\" master \"$CMD_MASTER\"; echo \"PYTHONPATH=\$PYTHONPATH\"; exec $CMD_MASTER'"
  sleep 1

  # Others
  run_cmd new-window janitor   "$REPO_ROOT" "$CMD_JANITOR"
  sleep 1
  run_cmd new-window ctlmgr    "$REPO_ROOT" "$CMD_CTLMGR"
  sleep 1
  run_cmd new-window dashboard "$REPO_ROOT" "$CMD_DASH"
  sleep 1
fi

"${TMUX_BASE[@]}" select-window -t "$SESSION":master
exec "${TMUX_BASE[@]}" attach -t "$SESSION"
