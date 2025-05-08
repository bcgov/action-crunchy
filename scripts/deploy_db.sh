#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Reorder inputs to make S3 inputs optional and place them last
if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <directory> <values_url> <app_name> <release_name> [s3_enabled] [s3_access_key] [s3_secret_key] [s3_bucket] [s3_endpoint]"
  exit 1
fi

DIRECTORY="$1"
VALUES_URL="$2"
APP_NAME="$3"
RELEASE_NAME="$4"
S3_ENABLED="${5:-false}"
S3_ACCESS_KEY="${6:-}"
S3_SECRET_KEY="${7:-}"
S3_BUCKET="${8:-}"
S3_ENDPOINT="${9:-}"

# Deploy Database
echo 'Deploying crunchy helm chart'
cd "$DIRECTORY"

# Download values.yml file
curl -o ./values.yml "$VALUES_URL"
echo "Downloaded values.yml (current directory: charts/crunchy)"

# Set Helm app name
sed -i "s/^name:.*/name: $APP_NAME/" Chart.yaml

# Package, update and deploy the chart
helm package -u .
if [ "$S3_ENABLED" == "true" ]; then
  helm upgrade --install --wait --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.accessKey="$S3_ACCESS_KEY" \
    --set-string crunchy.pgBackRest.s3.secretKey="$S3_SECRET_KEY" \
    --set-string crunchy.pgBackRest.s3.bucket="$S3_BUCKET" \
    --set-string crunchy.pgBackRest.s3.endpoint="$S3_ENDPOINT" \
    "$RELEASE_NAME" --values ./values.yml \
    ./$APP_NAME-5.5.1.tgz
else
  helm upgrade --install --wait "$RELEASE_NAME" --values ./values.yml \
    ./$APP_NAME-5.5.1.tgz
fi

# Verify successful db deployment; wait retry 10 times with 60 seconds interval
READY=false
for i in {1..10}; do
  # Check if the 'db' instance has at least 1 ready replica
  if oc get PostgresCluster/"$RELEASE_NAME" -o json | jq -e '.status.instances[] | select(.name=="db") | .readyReplicas > 0' > /dev/null 2>&1; then
    echo "Crunchy DB instance 'db' is ready "
    READY=true
    break
  else
    echo "Attempt $i: Crunchy DB is not ready, waiting for 60 seconds"
    sleep 60
  fi
done

if [ "$READY" = false ]; then
  echo "Crunchy DB did not become ready after 10 attempts."
  exit 1
fi

