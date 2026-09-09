#!/usr/bin/env bash
#
# End-to-end check of the chart's headline feature, against a real cluster:
# a simulation posted to the admin API is still being *served* after the Pod is
# replaced. `helm template` cannot see any of this, and `ct install` only proves
# the Pod starts -- it never restarts anything.
#
# Three scenarios, because the chart has two independent ways of getting the
# simulation onto the volume and one of them runs under -auth:
#
#   prestop   persistence only, graceful `rollout restart`
#             -> the preStop hook is the only thing that can have written the file
#   snapshot  persistence + sidecar, Pod force-deleted with grace period 0
#             -> preStop is skipped, exactly as in an OOMKill, so a survival here
#                can only come from the sidecar
#   auth      same as snapshot, but the admin API is behind -auth
#             -> also covers the sidecar's /api/token-auth exchange, the most
#                fragile part of it
#
# Each scenario asserts two things: the exported simulation is byte-identical
# across the restart, and the simulated endpoint still answers. The second matters
# on its own -- a state file that exists but was never imported would pass the
# first check on a chart that silently dropped the -import flag.
set -euo pipefail

CHART_DIR=${CHART_DIR:-charts/hoverfly}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SIM_FILE=${SIM_FILE:-$SCRIPT_DIR/e2e-simulation.json}
RELEASE=hoverfly
ADMIN_LOCAL=18888
PROXY_LOCAL=18500
MARKER=hello-from-e2e

AUTH_USER=ci
AUTH_PASS=ci-not-a-secret

TMP=$(mktemp -d)
NS=""
PF_PID=""
TOKEN=""
AUTH=false
FAILED=0

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m    ok: %s\033[0m\n' "$*"; }
fail() { printf '\033[0;31m    FAIL: %s\033[0m\n' "$*"; FAILED=1; }

# ---------------------------------------------------------------------------

stop_pf() {
  [ -n "$PF_PID" ] || return 0
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  PF_PID=""
}

cleanup() {
  stop_pf
  rm -rf "$TMP"
}
trap cleanup EXIT

# Forward both ports at once: the admin API for the simulation, the webserver
# port to prove the simulation is actually being served.
start_pf() {
  stop_pf
  kubectl -n "$NS" port-forward "svc/$RELEASE" \
    "${ADMIN_LOCAL}:8888" "${PROXY_LOCAL}:8500" >"$TMP/pf.log" 2>&1 &
  PF_PID=$!
  local i
  for i in $(seq 1 60); do
    if curl -sf -m 2 "http://127.0.0.1:${ADMIN_LOCAL}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "port-forward exited early:"; cat "$TMP/pf.log"; return 1
    fi
    sleep 1
  done
  echo "admin API never answered through the port-forward:"; cat "$TMP/pf.log"
  return 1
}

# /api/health is public even under -auth, so it is reachable before a token
# exists -- which is what makes the probes work and what start_pf relies on.
mint_token() {
  TOKEN=""
  [ "$AUTH" = "true" ] || return 0
  TOKEN=$(curl -sf -m 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"username\":\"${AUTH_USER}\",\"password\":\"${AUTH_PASS}\"}" \
    "http://127.0.0.1:${ADMIN_LOCAL}/api/token-auth" | jq -r '.token // empty')
  [ -n "$TOKEN" ] || { echo "could not obtain an admin token"; return 1; }
}

admin() {
  if [ -n "$TOKEN" ]; then
    curl -sf -m 20 -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -sf -m 20 "$@"
  fi
}

current_pod() {
  kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}'
}

# Waits for a Ready Pod that is not $1 and is not being deleted. Used for both
# kill modes, so the "did the replacement come up" logic exists in one place.
wait_ready_pod() {
  local exclude=$1 i pod
  for i in $(seq 1 150); do
    pod=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=${RELEASE}" -o json 2>/dev/null |
      jq -r --arg ex "$exclude" '
        .items[]
        | select(.metadata.name != $ex)
        | select(.metadata.deletionTimestamp == null)
        | select([.status.conditions[]? | select(.type == "Ready") | .status] == ["True"])
        | .metadata.name' | head -1)
    if [ -n "$pod" ]; then
      echo "$pod"
      return 0
    fi
    sleep 2
  done
  return 1
}

# The sidecar writes on its own schedule, so wait for the marker to reach the
# volume rather than sleeping for a guessed interval.
wait_for_snapshot() {
  local pod=$1 i
  for i in $(seq 1 60); do
    if kubectl -n "$NS" exec "$pod" -c snapshotter -- \
        grep -q "$MARKER" /data/simulation.json 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "the sidecar never wrote the simulation to the volume"
  kubectl -n "$NS" logs "$pod" -c snapshotter --tail=50 || true
  return 1
}

dump_diagnostics() {
  echo "--- pods ---";        kubectl -n "$NS" get pod -o wide || true
  echo "--- describe ---";    kubectl -n "$NS" describe pod -l "app.kubernetes.io/instance=${RELEASE}" || true
  echo "--- hoverfly ---";    kubectl -n "$NS" logs -l "app.kubernetes.io/instance=${RELEASE}" -c hoverfly --tail=100 || true
  echo "--- snapshotter ---"; kubectl -n "$NS" logs -l "app.kubernetes.io/instance=${RELEASE}" -c snapshotter --tail=50 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# run_scenario <name> <values file> <prestop|force> <auth true|false>

run_scenario() {
  local name=$1 values=$2 kill_mode=$3
  AUTH=$4
  NS="hoverfly-e2e-${name}"
  TOKEN=""

  log "scenario '${name}': ${values}, restart via ${kill_mode}, auth=${AUTH}"

  kubectl create namespace "$NS"
  # shellcheck disable=SC2064
  trap "kubectl delete namespace '$NS' --wait=false >/dev/null 2>&1 || true; cleanup" EXIT

  if ! helm install "$RELEASE" "$CHART_DIR" \
      --namespace "$NS" \
      --values "$CHART_DIR/ci/${values}" \
      --set fullnameOverride="$RELEASE" \
      --wait --timeout 5m; then
    dump_diagnostics
    fail "${name}: the release never became ready"
    kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
    return 0
  fi

  start_pf
  mint_token

  log "${name}: posting the simulation"
  admin -X PUT -H 'Content-Type: application/json' \
    --data-binary "@${SIM_FILE}" \
    "http://127.0.0.1:${ADMIN_LOCAL}/api/v2/simulation" >/dev/null

  # The baseline is what the server exports, not what we sent: both sides of the
  # comparison then go through the same normalisation. meta carries a timestamp
  # and the Hoverfly version, so only data is compared.
  admin "http://127.0.0.1:${ADMIN_LOCAL}/api/v2/simulation" | jq -S '.data' >"$TMP/before.json"

  local body
  body=$(curl -sf -m 10 "http://127.0.0.1:${PROXY_LOCAL}/e2e/greeting" || true)
  if [ "$body" != "$MARKER" ]; then
    fail "${name}: the simulation is not served before the restart (got '${body}')"
    dump_diagnostics
    kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
    return 0
  fi

  local old
  old=$(current_pod)

  if [ "$kill_mode" = "force" ]; then
    wait_for_snapshot "$old" || { fail "${name}: no snapshot on the volume"; kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true; return 0; }
  fi

  stop_pf

  case "$kill_mode" in
    prestop)
      log "${name}: graceful restart of ${old} (preStop runs)"
      kubectl -n "$NS" rollout restart "deployment/${RELEASE}"
      ;;
    force)
      log "${name}: force-deleting ${old} with grace period 0 (preStop is skipped)"
      kubectl -n "$NS" delete pod "$old" --force --grace-period=0 --wait=false
      ;;
  esac

  local new
  if ! new=$(wait_ready_pod "$old"); then
    fail "${name}: the replacement Pod never became ready"
    dump_diagnostics
    kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
    return 0
  fi
  ok "${name}: replacement Pod ${new} is ready"

  start_pf
  mint_token
  admin "http://127.0.0.1:${ADMIN_LOCAL}/api/v2/simulation" | jq -S '.data' >"$TMP/after.json"

  if diff -u "$TMP/before.json" "$TMP/after.json" >"$TMP/diff.txt"; then
    ok "${name}: the exported simulation is unchanged across the restart"
  else
    fail "${name}: the simulation changed across the restart"
    cat "$TMP/diff.txt"
    dump_diagnostics
  fi

  body=$(curl -sf -m 10 "http://127.0.0.1:${PROXY_LOCAL}/e2e/greeting" || true)
  if [ "$body" = "$MARKER" ]; then
    ok "${name}: the simulated endpoint still answers after the restart"
  else
    fail "${name}: the simulation was not served after the restart (got '${body}')"
    dump_diagnostics
  fi

  stop_pf
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  trap cleanup EXIT
}

# ---------------------------------------------------------------------------

run_scenario prestop  persistence-values.yaml prestop false
run_scenario snapshot snapshot-values.yaml    force   false
run_scenario auth     auth-values.yaml        force   true

if [ "$FAILED" -ne 0 ]; then
  log "e2e persistence: FAILED"
  exit 1
fi
log "e2e persistence: all scenarios passed"
