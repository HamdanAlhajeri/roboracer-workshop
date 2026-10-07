#!/usr/bin/env bash
# Start, pause, restart or stop the standalone macOS simulator workshop.
# macOS counterpart of workshop.ps1; run ./workshop.sh help for usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$ROOT/.runtime"
SESSION="$RUNTIME/session.env"
IMAGE='autodriveecosystem/autodrive_roboracer_api:2026-icra-practice'
SIM_URL='https://github.com/AutoDRIVE-Ecosystem/AutoDRIVE-RoboRacer-Sim-Racing/releases/download/2026-icra/autodrive_simulator_practice_macos.zip'
DEFAULT_APP="$RUNTIME/practice/autodrive_simulator/AutoDRIVE Simulator.app"

usage() {
  cat <<'EOF'
Start Docker Desktop (or let this script open it), then:
  ./workshop.sh start                       Open simulator with your controller.py
  ./workshop.sh start -c example            Run the supplied teaching example
  ./workshop.sh pause                       Stop the controller; leave simulator open
  ./workshop.sh restart -c starter          Reload your code and resume
  ./workshop.sh stop                        Stop workshop containers and its simulator
  ./workshop.sh status                      Inspect containers
  ./workshop.sh logs [-f]                   Show (or follow) controller and bridge logs
  ./workshop.sh test                        Run Python checks in an isolated container
start also accepts -s/--simulator-path '/path/AutoDRIVE Simulator.app'.
Save edits before restart. Without -c, the previous selection is reused.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

action="${1:-start}"
[[ $# -gt 0 ]] && shift
controller_arg='' simulator_path='' follow=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--controller) controller_arg="${2:-}"; shift 2 || die "$1 needs a value" ;;
    -s|--simulator-path) simulator_path="${2:-}"; shift 2 || die "$1 needs a value" ;;
    -f|--follow) follow=1; shift ;;
    *) die "Unknown option: $1 (see ./workshop.sh help)" ;;
  esac
done
case "$action" in start|pause|restart|stop|status|logs|test|help) ;; *) die "Unknown action: $action" ;; esac
[[ -z "$controller_arg" || "$controller_arg" == starter || "$controller_arg" == example ]] \
  || die "Controller must be 'starter' or 'example'."
[[ "$action" == help ]] && { usage; exit 0; }

compose() {
  docker compose --project-name autodrive-workshop --project-directory "$ROOT" \
    -f "$ROOT/compose.yaml" "$@"
}

saved() { [[ -f "$SESSION" ]] && sed -n "s/^$1=//p" "$SESSION" | head -n 1 || true; }

controller="$(saved controller)"
executable="$(saved executable)"
pid="$(saved pid)"
controller="${controller:-starter}"
case "$controller" in starter|example) ;; *) die "Invalid workshop session file." ;; esac
[[ -n "$controller_arg" ]] && controller="$controller_arg"
pid="${pid:-0}"
if [[ "$controller" == example ]]; then
  export WORKSHOP_CONTROLLER=examples.follow_the_gap
else
  export WORKSHOP_CONTROLLER=controller
fi

save_session() {
  mkdir -p "$RUNTIME"
  printf 'controller=%s\nexecutable=%s\npid=%s\n' "$controller" "$executable" "$pid" > "$SESSION"
}

# Our simulator is running only if the saved PID is alive and runs the saved binary.
owned_player() {
  [[ "$pid" != 0 && -n "$executable" ]] || return 1
  [[ "$(ps -p "$pid" -o command= 2>/dev/null)" == "$executable"* ]]
}

ensure_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo 'Starting Docker Desktop...'
    open -a Docker 2>/dev/null || die 'Install and start Docker Desktop, then retry.'
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 3; done
    docker info >/dev/null 2>&1 || die 'Docker did not start in time; open Docker Desktop and retry.'
  fi
  [[ "$(docker info --format '{{.OSType}}')" == linux ]] || die 'Docker must use Linux containers.'
}

case "$action" in
  status) compose ps -a; exit 0 ;;
  logs)
    opts=(--tail 100); [[ $follow == 1 ]] && opts+=(--follow)
    compose logs "${opts[@]}" controller bridge; exit 0 ;;
  pause|stop)
    compose stop controller
    sleep 0.7  # let the bridge send stopped commands, or let them expire
    if [[ "$action" == stop ]]; then
      owned_player && kill "$pid" 2>/dev/null || true
      compose down
      pid=0; save_session
    fi
    echo 'Workshop controller stopped.'
    exit 0 ;;
esac

ensure_docker

if [[ "$action" == test ]]; then
  docker run --rm --network none --env PYTHONDONTWRITEBYTECODE=1 \
    --volume "$ROOT:/workshop:ro" --workdir /workshop --entrypoint python3 \
    "$IMAGE" -m unittest discover -s tests -v || die 'Workshop tests failed.'
  exit 0
fi

if [[ "$action" == restart ]]; then
  [[ -n "$(compose ps --status running -q bridge)" ]] || die 'Start the workshop first: ./workshop.sh start'
  compose stop controller
  sleep 0.7
  compose up -d --no-deps --force-recreate controller
  save_session
  echo "Reloaded $controller. Driving resumes when Autonomous is selected."
  exit 0
fi

# start
own_bridge="$(compose ps --status running -q bridge)"
if lsof -nP -iTCP:4567 -sTCP:LISTEN >/dev/null 2>&1 && [[ -z "$own_bridge" ]]; then
  die 'Port 4567 is in use. Stop the main project or other simulator bridge first.'
fi
others="$(pgrep -x 'AutoDRIVE Simulator' || true)"
if [[ -n "$others" ]] && ! { owned_player && [[ "$others" == "$pid" ]]; }; then
  die 'Close the other AutoDRIVE simulator before starting the workshop.'
fi

if [[ -n "$simulator_path" ]]; then
  [[ -d "$simulator_path" ]] || die "Simulator app not found: $simulator_path"
  app="$(cd "$simulator_path" && pwd)"
elif [[ -n "$executable" ]]; then
  app="${executable%/Contents/MacOS/*}"
  [[ -d "$app" ]] || die 'Saved simulator path is missing. Supply --simulator-path or remove .runtime/session.env.'
else
  app="$DEFAULT_APP"
  if [[ ! -d "$app" ]]; then
    mkdir -p "$RUNTIME"
    echo 'Downloading the practice simulator (about 107 MB)...'
    curl --fail --location --retry 3 --output "$RUNTIME/practice.zip" "$SIM_URL" \
      || die 'Simulator download failed; check the network and retry.'
    unzip -q -o "$RUNTIME/practice.zip" -d "$RUNTIME/practice"
    [[ -d "$app" ]] || die 'Download did not contain the expected simulator. Archive kept for inspection.'
    rm "$RUNTIME/practice.zip"
  fi
fi
# unzip drops the exec bit and downloads may be quarantined; both stop macOS opening the app.
bin="$app/Contents/MacOS/$(basename "$app" .app)"
chmod -R +x "$app/Contents/MacOS"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
[[ -x "$bin" ]] || die "Simulator binary not found: $bin"

if owned_player && [[ "$executable" != "$bin" ]]; then
  die 'Stop the workshop before selecting another simulator.'
fi

compose up -d bridge controller
executable="$bin"
if ! owned_player; then
  mkdir -p "$RUNTIME"
  nohup "$bin" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 \
    -ip 127.0.0.1 -port 4567 -logFile "$RUNTIME/simulator.log" >/dev/null 2>&1 &
  pid=$!
  disown
fi
save_session
echo "Workshop running with $controller. In Unity select Connection (127.0.0.1:4567) and Autonomous."
echo 'The starter stays stopped until you implement controller.py. Pause with ./workshop.sh pause.'
