#!/usr/bin/env bash
# golden_path.sh - run the project end to end from the repo root, one stage at a time.
# The stages follow docs/SETUP.md in dependency order.
#
# Console shows one PASS/FAIL line per stage; full output goes to logs/golden_path_<time>.log.
# Stops at the first failing stage, because later stages depend on earlier ones.
#
# MODE=clean  (use in a FRESH CLONE with its own .venv; matches SETUP.md from scratch)
#   - downloads the raw data, trains BOTH problems with registration (1 trial each),
#   - starts the local API and dashboard, checks both, then stops them.
# MODE=quick  (default; for the working repo, never registers or overwrites models)
#   - reuses cached data, trains fare only with --no-register, no local servers.
#
# Usage:
#   PYTHON=.venv/bin/python MODE=clean ./scripts/golden_path.sh
#   ./scripts/golden_path.sh                      (quick mode)
#
# Optional settings:
#   PIPELINE_ARGS, TRAIN_ARGS   override the pipeline / training arguments
#   LOCAL_API=1  LOCAL_DASH=1   force the local API / dashboard stages on (or 0 for off)
#   API_URL=http://...          also smoke-test a deployed API at the end

set -o pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1
mkdir -p logs

PYTHON="${PYTHON:-python}"
MODE="${MODE:-quick}"
API_URL="${API_URL:-}"

if [ "$MODE" = "clean" ]; then
  PIPELINE_ARGS="${PIPELINE_ARGS-}"
  TRAIN_ARGS="${TRAIN_ARGS---n-trials 1}"
  LOCAL_API="${LOCAL_API-1}"
  LOCAL_DASH="${LOCAL_DASH-1}"
elif [ "$MODE" = "quick" ]; then
  PIPELINE_ARGS="${PIPELINE_ARGS---skip-download}"
  TRAIN_ARGS="${TRAIN_ARGS---problem fare --n-trials 1 --no-register}"
  LOCAL_API="${LOCAL_API-0}"
  LOCAL_DASH="${LOCAL_DASH-0}"
else
  echo "MODE must be 'clean' or 'quick' (got '$MODE')"; exit 2
fi

TS="$(date +%Y%m%d-%H%M%S)"
LOG="logs/golden_path_$TS.log"
HEALTH_FILE="$(mktemp)"
SUMMARY=""
FAILED=0
PIDS=""
LOCAL_URL="http://127.0.0.1:8000"

cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  rm -f "$HEALTH_FILE"
}
trap cleanup EXIT

{
  echo "Golden path run : $TS"
  echo "Mode            : $MODE"
  echo "Commit          : $(git rev-parse HEAD)"
  echo "Branch          : $(git branch --show-current)"
  echo "Remote          : $(git remote get-url origin 2>/dev/null)"
  echo "Python          : $($PYTHON --version 2>&1)"
  echo "Platform        : $(uname -sm)"
} | tee "$LOG"

stage() {
  local name="$1"; shift
  local start rc dur
  printf '\n\033[36m=== %s ===\033[0m\n' "$name"
  { echo; echo "=== STAGE: $name ==="; echo "cmd: $*"; } >> "$LOG"
  start=$(date +%s)
  "$@" >> "$LOG" 2>&1
  rc=$?
  dur=$(( $(date +%s) - start ))
  if [ $rc -eq 0 ]; then
    printf '\033[32mPASS: %s (%ss)\033[0m\n' "$name" "$dur"
    SUMMARY="$SUMMARY
PASS  ${dur}s  $name"
  else
    printf '\033[31mFAIL: %s (exit %s, %ss)\033[0m\n' "$name" "$rc" "$dur"
    echo "Last lines of the log:"
    tail -n 15 "$LOG"
    SUMMARY="$SUMMARY
FAIL  ${dur}s  $name"
    FAILED=1
  fi
  echo "RESULT: $name rc=$rc duration=${dur}s" >> "$LOG"
  return $rc
}

port_free() {
  command -v lsof >/dev/null 2>&1 || return 0
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# Strict API readiness: HTTP 200 alone is not enough.
health_ok() {
  curl -fsS --max-time 5 "$1/health" -o "$HEALTH_FILE" 2>/dev/null && \
  "$PYTHON" -c 'import json, sys
h = json.load(open(sys.argv[1]))
good = (h.get("status") == "ok" and h.get("demand_model_loaded") and h.get("fare_model_loaded")
        and h.get("history_hours", 0) > 0 and h.get("zones", 0) > 0)
sys.exit(0 if good else 1)' "$HEALTH_FILE"
}

api_up() {
  local pid i=0
  port_free 8000 || { echo "Port 8000 is already in use; stop the other process first."; return 1; }
  "$PYTHON" -m uvicorn src.serving.api:app --host 127.0.0.1 --port 8000 >> "$LOG" 2>&1 &
  pid=$!
  PIDS="$PIDS $pid"
  while [ $i -lt 60 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "API process exited early"; return 1; }
    if health_ok "$LOCAL_URL"; then cat "$HEALTH_FILE"; echo; return 0; fi
    i=$((i+1)); sleep 2
  done
  echo "API did not become healthy within 120s"; return 1
}

dashboard_up() {
  local pid i=0 base="${API_URL:-$LOCAL_URL}"
  port_free 8501 || { echo "Port 8501 is already in use; stop the other process first."; return 1; }
  API_BASE_URL="$base" "$PYTHON" -m streamlit run dashboard/app.py \
    --server.address 127.0.0.1 --server.port 8501 \
    --server.headless true --browser.gatherUsageStats false >> "$LOG" 2>&1 &
  pid=$!
  PIDS="$PIDS $pid"
  while [ $i -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "Dashboard process exited early"; return 1; }
    if curl -fsS --max-time 5 http://127.0.0.1:8501/_stcore/health 2>/dev/null | grep -q ok; then
      echo "dashboard health: ok (API_BASE_URL=$base)"; return 0
    fi
    i=$((i+1)); sleep 2
  done
  echo "Dashboard did not become healthy within 60s"; return 1
}

registry_check() {
  "$PYTHON" -W ignore -c "import mlflow
from mlflow.tracking import MlflowClient
mlflow.set_tracking_uri('sqlite:///mlflow.db')
names = sorted(m.name for m in MlflowClient().search_registered_models())
print('registered models:', names)
need = {'taxi-demand-forecaster', 'taxi-fare-predictor'}
assert need <= set(names), 'missing: %s' % sorted(need - set(names))"
}

run_all() {
  stage "Environment (python, mlflow, sqlalchemy)" \
    "$PYTHON" -c "import sys, mlflow, sqlalchemy; print(sys.version.split()[0], mlflow.__version__, sqlalchemy.__version__)" || return 1
  stage "Lint (ruff)" "$PYTHON" -m ruff check . || return 1
  stage "Tests + coverage" "$PYTHON" -m pytest --cov=src --cov-report=term-missing -q || return 1
  # shellcheck disable=SC2086
  stage "Phase 1: data pipeline" "$PYTHON" -m scripts.run_pipeline $PIPELINE_ARGS || return 1
  # shellcheck disable=SC2086
  stage "Phase 2: training ($TRAIN_ARGS)" "$PYTHON" -m scripts.train_models $TRAIN_ARGS || return 1
  stage "Phase 2: both models registered" registry_check || return 1
  stage "Phase 3: batch forecast (3 hours)" "$PYTHON" -m scripts.batch_forecast --horizon 3 || return 1
  stage "Phase 6: responsible-AI artifacts" "$PYTHON" -m scripts.responsible.run_analysis || return 1
  stage "Phase 5: drift report (synthetic, seed 42)" \
    "$PYTHON" -m scripts.monitoring.demo_drift_report --problem all --mode drift --seed 42 || return 1
  if [ "$LOCAL_API" = "1" ]; then
    stage "Phase 3: local API start + strict health" api_up || return 1
    stage "Phase 3: local API smoke test (verify_staging)" \
      "$PYTHON" scripts/aws/verify_staging.py --api-url "$LOCAL_URL" --timeout 60 || return 1
  fi
  if [ "$LOCAL_DASH" = "1" ]; then
    stage "Phase 7: dashboard requirements" "$PYTHON" -m pip install -r requirements-dashboard.txt || return 1
    stage "Phase 7: dashboard start + health" dashboard_up || return 1
  fi
  if [ -n "$API_URL" ]; then
    stage "Phase 3/4: deployed API smoke test" \
      "$PYTHON" scripts/aws/verify_staging.py --api-url "$API_URL" --timeout 60 || return 1
  fi
  return 0
}

run_all

printf '\n=== SUMMARY (%s mode) ===%s\n' "$MODE" "$SUMMARY" | tee -a "$LOG"
echo "Log file: $LOG"
if [ $FAILED -ne 0 ]; then
  printf '\033[31mGOLDEN PATH FAILED\033[0m\n'
  exit 1
fi
printf '\033[32mGOLDEN PATH PASSED\033[0m\n'
exit 0
