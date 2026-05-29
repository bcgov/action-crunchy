#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <directory> <values_url> <app_name> <release_name> [s3_access_key] [s3_secret_key] [s3_bucket] [s3_endpoint]"
  exit 1
fi

DIRECTORY="$1"
VALUES_URL="$2"
APP_NAME="$3"
RELEASE_NAME="$4"
TRIGGERED="$5"
export S3_ACCESS_KEY="${6:-}"
export S3_SECRET_KEY="${7:-}"
export S3_BUCKET="${8:-}"
export S3_ENDPOINT="${9:-}"
MAX_DB_READY_RETRIES=90
DB_READY_SLEEP_SECONDS=10

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve and validate Helm args BEFORE any side effects (cd, packaging, etc).
# resolve_helm_args.sh exits non-zero on guardrail/version validation failures,
# so the conflict check fires up-front without touching the cluster.
export VALUES_URL
SET_STRINGS="$("${SCRIPT_DIR}/resolve_helm_args.sh")"

# Deploy Database
echo 'Deploying crunchy helm chart'
cd "$DIRECTORY"

# Download or copy values.yml file
if [ -n "${VALUES_URL:-}" ]; then
  CURL_AUTH_OPTS=()
  if [[ "${VALUES_URL}" =~ ^https?:// ]]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      CURL_AUTH_OPTS=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    CURL_AUTH_OPTS+=(-H "Accept: application/vnd.github.v3.raw")
  fi
  curl --fail --location --silent --show-error "${CURL_AUTH_OPTS[@]}" -o ./values.yml "$VALUES_URL"
  echo "Downloaded values.yml (current directory: charts/crunchy)"
else
  # Copy default values.yml from action root relative to the script location
  cp "${SCRIPT_DIR}/../values.yml" ./values.yml
  echo "Copied default values.yml from action root"
fi

# Set Helm app name
sed -i "s/^name:.*/name: $APP_NAME/" Chart.yaml
CHART_VERSION=$(yq -r .version Chart.yaml)
# Package, update and deploy the chart
helm package -u .

# if it is not triggered TRIGGERED value is false, check if the chart is already deployed, if not deployed, deploy it else exit 0.
if [ "${TRIGGERED:-false}" != "true" ]; then
  if ! helm status "$RELEASE_NAME" > /dev/null 2>&1; then
    echo "Chart DB $RELEASE_NAME not deployed, deploying now, ignoring triggers."
  else
    echo "Crunchy DB $RELEASE_NAME is already deployed, triggers did not fire, so not upgrading."
    exit 0
  fi
fi

# Self-heal a release that was left in a non-deployed state by a previous
# timed-out run. `helm upgrade --install` refuses to operate when the most
# recent release is in pending-install / pending-upgrade / failed, so we
# uninstall it (PostgresCluster CR + helm secret) and let this run start
# fresh. The PostgresCluster's PVCs persist independently and the operator
# will rebind them on the next install.
HELM_RELEASE_STATUS="$(helm status "$RELEASE_NAME" -o json 2>/dev/null | jq -r '.info.status // empty' 2>/dev/null || true)"
echo "Helm release '${RELEASE_NAME}' current status: '${HELM_RELEASE_STATUS:-<none>}'"
case "${HELM_RELEASE_STATUS}" in
  deployed|"")
    : # nothing to do; clean start or healthy upgrade
    ;;
  *)
    # Any non-deployed status (pending-*, failed, uninstalling, unknown)
    # blocks `helm upgrade --install`. Purge the helm storage secrets for
    # this release so we can install fresh. The underlying PostgresCluster
    # PVCs are owned by the operator independently and will be rebound.
    echo "Release in '${HELM_RELEASE_STATUS}' state; purging helm history before reinstall."
    helm uninstall "$RELEASE_NAME" --wait --timeout 2m 2>/dev/null || true
    # If helm uninstall couldn't clear it (e.g. release stuck 'uninstalling'),
    # delete the storage secrets directly. Pattern: sh.helm.release.v1.<name>.v<n>
    oc delete secret -l "owner=helm,name=${RELEASE_NAME}" --ignore-not-found=true || true
    ;;
esac

# Execute the Helm command
if [ "${DEBUG_MODE:-false}" = "true" ]; then
  helm upgrade --debug --dry-run --install --wait "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
else
  helm upgrade --install --wait "$RELEASE_NAME" --values ./values.yml ./$APP_NAME-$CHART_VERSION.tgz $SET_STRINGS
fi
# Verify successful db deployment; wait retry 10 times with 60 seconds interval
for i in $(seq 1 "$MAX_DB_READY_RETRIES"); do
  # Check if the 'db' instance has at least 1 ready replica
  if oc get PostgresCluster/"$RELEASE_NAME"-crunchy -o json | jq -e '.status.instances[] | select(.name=="db") | .readyReplicas > 0' > /dev/null 2>&1; then
    echo "Crunchy DB instance 'db' is ready."
    READY=true
    exit 0
  else
    echo "Attempt $i: Crunchy DB is not ready, waiting for $DB_READY_SLEEP_SECONDS seconds"
    sleep $DB_READY_SLEEP_SECONDS
  fi
done

# Landing here means there's a problem
echo "Crunchy DB did not become ready after $MAX_DB_READY_RETRIES attempts."
exit 1
