#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

MOCK_LOG=$(mktemp)
export MOCK_LOG
trap 'rm -f "$MOCK_LOG"' EXIT

git() {
  case "$1" in
    rev-parse) echo 'test-commit' ;;
    status) if [ "${MOCK_DIRTY:-0}" = 1 ]; then echo ' M infra/deploy.sh'; fi ;;
    *) echo "Unexpected git command: $*" >&2; return 1 ;;
  esac
}

az() {
  local query="" file="" i
  for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "--query" ]; then i=$((i + 1)); query="${!i}"; fi
    if [ "${!i}" = "--file" ]; then i=$((i + 1)); file="${!i}"; fi
  done
  case "$1 ${2:-} ${3:-}" in
    "account show "*) case "$query" in name) echo Test ;; tenantId) echo tenant ;; id) echo subscription ;; esac ;;
    "provider register"*) ;;
    "group exists "*) if [ "${MOCK_EXISTING:-0}" = 1 ]; then echo true; else echo false; fi ;;
    "group create "*) ;;
    "deployment group list"*) if [ "${MOCK_EXISTING:-0}" = 1 ]; then echo test-functions; fi ;;
    "deployment group create"*) echo "bicep:$*" >> "$MOCK_LOG" ;;
    "deployment group show"*)
      case "$query" in
        *acrName*) echo testacr ;; *acrLoginServer*) echo testacr.azurecr.io ;;
        *aksName*) echo testaks ;; *cosmosName*) echo testcosmos ;;
        *functionsName*) echo test-functions ;; *statisticsUrl*) echo https://functions.example.test ;;
        *githubClientId*) echo test-client ;;
        *) echo "Unexpected deployment output: $query" >&2; return 1 ;;
      esac ;;
    "functionapp cors show"*) echo http://old.example.test:3000 ;;
    "functionapp cors add"*|"functionapp cors remove"*) echo "cors:$*" >> "$MOCK_LOG" ;;
    "cosmosdb list "*)
      if [ "${MOCK_COSMOS_ERROR:-0}" = 1 ]; then echo "Cosmos lookup failed" >&2; return 1; fi
      if [ "${MOCK_EXISTING:-0}" = 1 ] && [[ " $* " == *" -g "* ]]; then echo testcosmos; fi ;;
    "cosmosdb show "*) if [ "$query" = enableFreeTier ]; then echo true; else echo false; fi ;;
    "cosmosdb keys list"*) echo 'mongodb://test:10255/?option=true' ;;
    "acr credential show"*) if [ "$query" = username ]; then echo testuser; else echo testpassword; fi ;;
    "aks get-credentials"*) printf 'mock kubeconfig\n' > "$file" ;;
    *) echo "Unexpected az command: $*" >&2; return 1 ;;
  esac
}

kubectl() {
  case "$1 $2" in
    "create secret"*) echo 'mock secret' ;;
    "apply -f"*) if [ "$3" = "-" ]; then while IFS= read -r line; do echo "apply:$line" >> "$MOCK_LOG"; done; fi ;;
    "get deployment")
      if [ "${MOCK_EXISTING:-0}" = 1 ]; then echo "testacr.azurecr.io/$3:existing"; fi ;;
    "get service")
      if [ "${MOCK_MISSING_IP:-0}" != 1 ]; then
        if [ "$3" = todo-api ]; then echo 203.0.113.1; else echo 203.0.113.2; fi
      fi ;;
    *) echo "Unexpected kubectl command: $*" >&2; return 1 ;;
  esac
}

gh() {
  case "$1 $2" in
    "auth status") ;;
    "repo view") echo example/demo ;;
    "secret set") ;;
    "variable set") echo "variable:$3:$*" >> "$MOCK_LOG" ;;
    "api "*)
      if [[ " $* " == *"/git/ref/heads/main "* ]]; then
        if [ "${MOCK_BAD_BRANCH:-0}" = 1 ]; then echo different-commit; else echo test-commit; fi
      elif [[ " $* " == *"/dispatches "* ]]; then
        case "$*" in
          *todo-functions.yml*) echo "dispatch:functions" >> "$MOCK_LOG"; if [ "${MOCK_NO_RUN_ID:-0}" != 1 ]; then echo 101; fi ;;
          *todo-api.yml*) echo "dispatch:api" >> "$MOCK_LOG"; echo 102 ;;
          *todo-app.yml*) echo "dispatch:app" >> "$MOCK_LOG"; echo 103 ;;
          *) return 1 ;;
        esac
      elif [[ " $* " == *"owner.id"* ]]; then
        printf '111\n222\n'
      else
        echo "Unexpected GitHub API command: $*" >&2; return 1
      fi ;;
    "run view")
      if [ "${MOCK_FAIL_API:-0}" = 1 ] && [ "$3" = 102 ]; then
        echo completed:failure
      else
        echo completed:success
      fi ;;
    *) echo "Unexpected gh command: $*" >&2; return 1 ;;
  esac
}

curl() {
  local header="" origin="" url="" i
  for ((i=1; i<=$#; i++)); do
    case "${!i}" in
      -D) i=$((i + 1)); header="${!i}" ;;
      -H) i=$((i + 1)); origin="${!i}"; origin="${origin#Origin: }" ;;
      http*) url="${!i}" ;;
    esac
  done
  if [ -n "$header" ]; then
    if [ "${MOCK_BAD_CORS:-0}" = 1 ]; then origin=http://wrong.example.test; fi
    printf 'Access-Control-Allow-Origin: %s\r\n' "$origin" > "$header"
  fi
  case "$url" in
    */todos) if [ "${MOCK_BAD_API:-0}" = 1 ]; then echo '{"message":"database failed"}'; else echo '[]'; fi ;;
    */api/statistics)
      if [ "${MOCK_BAD_STATS:-0}" = 1 ]; then echo '{"total":1,"completed":1,"pending":1}'; else echo '{"total":0,"completed":0,"pending":0}'; fi ;;
    *) ;;
  esac
}

sleep() { :; }
export -f git az kubectl gh curl sleep

run_deploy() {
  GITHUB_REPO=example/demo bash infra/deploy.sh
}

output=$(run_deploy 2>&1) || { echo "$output" >&2; exit 1; }
grep -q 'variable:VITE_API_URL:.*http://203.0.113.1:5000' "$MOCK_LOG"
grep -q 'cors:.*--allowed-origins http://203.0.113.2:3000' "$MOCK_LOG"
grep -q 'apply:.*image: testacr.azurecr.io/todo-app:latest' "$MOCK_LOG"
grep -q 'dispatch:functions' "$MOCK_LOG"
grep -q 'dispatch:api' "$MOCK_LOG"
grep -q 'dispatch:app' "$MOCK_LOG"
grep -q 'bicep:.*githubSubjectImmutable=repo:example@111/demo@222:ref:refs/heads/main' "$MOCK_LOG"
echo "Fresh deployment: passed"

: > "$MOCK_LOG"
export MOCK_EXISTING=1
output=$(run_deploy 2>&1) || { echo "$output" >&2; exit 1; }
grep -q 'bicep:.*frontendOrigin=http://old.example.test:3000' "$MOCK_LOG"
grep -q 'apply:.*image: testacr.azurecr.io/todo-app:existing' "$MOCK_LOG"
grep -q 'cors:.*cors remove.*http://old.example.test:3000' "$MOCK_LOG"
echo "Repeat deployment: passed"

: > "$MOCK_LOG"
export MOCK_FAIL_API=1
if output=$(run_deploy 2>&1); then echo "Expected failed workflow to stop deployment" >&2; exit 1; fi
[[ "$output" == *"todo-api.yml run 102 failed"* ]]
if grep -q 'dispatch:app' "$MOCK_LOG"; then echo "Frontend started after API failure" >&2; exit 1; fi
echo "Workflow failure: passed"

: > "$MOCK_LOG"
export MOCK_DIRTY=1
if output=$(run_deploy 2>&1); then echo "Expected dirty configuration to stop deployment" >&2; exit 1; fi
if grep -q '^bicep:' "$MOCK_LOG"; then echo "Dirty configuration reached deployment" >&2; exit 1; fi
echo "Uncommitted configuration: passed"

unset MOCK_DIRTY MOCK_FAIL_API
export MOCK_BAD_API=1
if output=$(run_deploy 2>&1); then echo "Expected database failure to stop verification" >&2; exit 1; fi
[[ "$output" == *"API did not return a todo list"* ]]
unset MOCK_BAD_API
export MOCK_BAD_STATS=1
if output=$(run_deploy 2>&1); then echo "Expected invalid statistics to stop verification" >&2; exit 1; fi
[[ "$output" == *"Function returned invalid statistics"* ]]
unset MOCK_BAD_STATS
export MOCK_BAD_CORS=1
if output=$(run_deploy 2>&1); then echo "Expected invalid CORS to stop verification" >&2; exit 1; fi
[[ "$output" == *"Function did not allow the configured frontend origin"* ]]
echo "Endpoint and CORS failures: passed"

unset MOCK_BAD_CORS
export MOCK_MISSING_IP=1
if output=$(run_deploy 2>&1); then echo "Expected missing public IP to stop deployment" >&2; exit 1; fi
[[ "$output" == *"Timed out waiting for todo-api public address"* ]]
unset MOCK_MISSING_IP
export MOCK_NO_RUN_ID=1
if output=$(run_deploy 2>&1); then echo "Expected missing workflow run ID to stop deployment" >&2; exit 1; fi
[[ "$output" == *"GitHub did not return a workflow run ID"* ]]
unset MOCK_NO_RUN_ID
export MOCK_BAD_BRANCH=1
if output=$(run_deploy 2>&1); then echo "Expected unmatched main commit to stop deployment" >&2; exit 1; fi
[[ "$output" == *"local commit must match"* ]]
unset MOCK_BAD_BRANCH
export MOCK_COSMOS_ERROR=1
if output=$(run_deploy 2>&1); then echo "Expected Cosmos lookup failure to stop deployment" >&2; exit 1; fi
[[ "$output" == *"Cosmos lookup failed"* ]]
echo "Timeout and preflight failures: passed"
