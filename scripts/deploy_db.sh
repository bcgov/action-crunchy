#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Remove S3_ENABLED and adjust logic to use S3 inputs if provided
if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <directory> <values_url> <app_name> <release_name> [s3_access_key] [s3_secret_key] [s3_bucket] [s3_endpoint]"
  exit 1
fi

DIRECTORY="$1"
VALUES_URL="$2"
APP_NAME="$3"
RELEASE_NAME="$4"
TRIGGERED="$5"
S3_ACCESS_KEY="${6:-}"
S3_SECRET_KEY="${7:-}"
S3_BUCKET="${8:-}"
S3_ENDPOINT="${9:-}"
MAX_DB_READY_RETRIES=90
DB_READY_SLEEP_SECONDS=10
# Deploy Database
echo 'Deploying crunchy helm chart'
cd $DIRECTORY

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
  cp "$(dirname "$0")/../values.yml" ./values.yml
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

# Conflict check & Fail-fast Guardrail
if [ -n "${VALUES_URL:-}" ]; then
  if [ -n "${PVC_SIZE:-}" ] || [ -n "${STORAGE_CLASS:-}" ] || [ -n "${POSTGRES_VERSION:-}" ] || [ -n "${REPLICAS:-}" ] || [ -n "${CPU_REQUEST:-}" ] || [ -n "${MEMORY_REQUEST:-}" ]; then
    echo "=========================================================================="
    echo "❌ CONFIGURATION CONFLICT DETECTED!"
    echo "=========================================================================="
    echo "You provided a custom 'values_file' (${VALUES_URL}) but also specified one"
    echo "or more database sizing/resource override inputs in your workflow:"
    echo "  - pvc_size: '${PVC_SIZE:-}'"
    echo "  - storage_class: '${STORAGE_CLASS:-}'"
    echo "  - postgres_version: '${POSTGRES_VERSION:-}'"
    echo "  - replicas: '${REPLICAS:-}'"
    echo "  - cpu_request: '${CPU_REQUEST:-}'"
    echo "  - memory_request: '${MEMORY_REQUEST:-}'"
    echo ""
    echo "👉 TO FIX THIS:"
    echo "Since you have a custom values file, you must specify all database sizes"
    echo "and resource requests directly inside your custom file."
    echo "Please remove the conflicting sizing inputs from your GitHub workflow file."
    echo "=========================================================================="
    exit 1
  fi
fi

# Build Helm set strings; add non-S3 options first if needed
SET_STRINGS=""

# If no custom values file is supplied, populate default sizing values and build set strings
if [ -z "${VALUES_URL:-}" ]; then
  PVC_SIZE="${PVC_SIZE:-150Mi}"
  STORAGE_CLASS="${STORAGE_CLASS:-netapp-block-standard}"
  POSTGRES_VERSION="${POSTGRES_VERSION:-18}"
  REPLICAS="${REPLICAS:-2}"
  CPU_REQUEST="${CPU_REQUEST:-50m}"
  MEMORY_REQUEST="${MEMORY_REQUEST:-128Mi}"

  SET_STRINGS+=" --set-string crunchy.instances.dataVolumeClaimSpec.storage=${PVC_SIZE}"
  SET_STRINGS+=" --set-string crunchy.instances.dataVolumeClaimSpec.storageClassName=${STORAGE_CLASS}"
  SET_STRINGS+=" --set crunchy.postgresVersion=${POSTGRES_VERSION}"

  # Resolve a known-good (image, postGISVersion) pair for the requested
  # PostgreSQL major version. The Crunchy Operator (chart appVersion 5.8.5)
  # only ships defaults for specific PG/PostGIS combinations, so we cannot
  # simply null the image and hope it picks correctly. The list below is the
  # ubi9 + GIS variant from:
  # https://github.com/bcgov/crunchy-postgres#current-compatible-images
  case "${POSTGRES_VERSION}" in
    15) CRUNCHY_IMAGE_TAG="ubi9-15.15-3.3-2547"; CRUNCHY_POSTGIS_VERSION="3.3" ;;
    16) CRUNCHY_IMAGE_TAG="ubi9-16.11-3.4-2547"; CRUNCHY_POSTGIS_VERSION="3.4" ;;
    17) CRUNCHY_IMAGE_TAG="ubi9-17.7-3.6-2547";  CRUNCHY_POSTGIS_VERSION="3.6" ;;
    18) CRUNCHY_IMAGE_TAG="ubi9-18.1-3.6-2547";  CRUNCHY_POSTGIS_VERSION="3.6" ;;
    *)
      echo "Error: Unsupported postgres_version '${POSTGRES_VERSION}'."
      echo "Supported values (Crunchy Operator 5.8.5): 15, 16, 17, 18."
      echo "If you need a combination outside this list, supply your own values_file"
      echo "and set crunchy.image and crunchy.postGISVersion explicitly."
      exit 1
      ;;
  esac
  SET_STRINGS+=" --set-string crunchy.image=artifacts.developer.gov.bc.ca/bcgov-docker-local/crunchy-postgres-gis:${CRUNCHY_IMAGE_TAG}"
  SET_STRINGS+=" --set-string crunchy.postGISVersion=${CRUNCHY_POSTGIS_VERSION}"

  SET_STRINGS+=" --set crunchy.instances.replicas=${REPLICAS}"
  SET_STRINGS+=" --set-string crunchy.instances.requests.cpu=${CPU_REQUEST}"
  SET_STRINGS+=" --set-string crunchy.instances.requests.memory=${MEMORY_REQUEST}"
fi

if [ -n "${ROUTE_ENABLED:-}" ]; then
  SET_STRINGS+=" --set route.enabled=${ROUTE_ENABLED}"
fi

if [ -n "${ROUTE_HOST:-}" ]; then
  SET_STRINGS+=" --set-string route.host=${ROUTE_HOST}"
fi

if [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] && [ -n "$S3_BUCKET" ] && [ -n "$S3_ENDPOINT" ]; then
  SET_STRINGS+=" --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.accessKey=$S3_ACCESS_KEY \
    --set-string crunchy.pgBackRest.s3.secretKey=$S3_SECRET_KEY \
    --set-string crunchy.pgBackRest.s3.bucket=$S3_BUCKET \
    --set-string crunchy.pgBackRest.s3.endpoint=$S3_ENDPOINT"
fi

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
