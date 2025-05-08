#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Deploy Database
echo 'Deploying crunchy helm chart'
cd "$1"

# Download values.yml file
curl -o ./values.yml "$2"
echo "Downloaded values.yml (current directory: charts/crunchy)"

# Set Helm app name
sed -i "s/^name:.*/name: $3/" Chart.yaml

# Package, update and deploy the chart
helm package -u .
if [ "$4" == "true" ]; then
  helm upgrade --install --wait --set crunchy.pgBackRest.s3.enabled=true \
    --set-string crunchy.pgBackRest.s3.accessKey="$5" \
    --set-string crunchy.pgBackRest.s3.secretKey="$6" \
    --set-string crunchy.pgBackRest.s3.bucket="$7" \
    --set-string crunchy.pgBackRest.s3.endpoint="$8" \
    "$9" --values ./values.yml \
    ./$3-5.5.1.tgz
else
  helm upgrade --install --wait "$9" --values ./values.yml \
    ./$3-5.5.1.tgz
fi

# Verify successful db deployment; wait retry 10 times with 60 seconds interval
READY=false
for i in {1..10}; do
  # Check if the 'db' instance has at least 1 ready replica
  if oc get PostgresCluster/"$9" -o json | jq -e '.status.instances[] | select(.name=="db") | .readyReplicas > 0' > /dev/null 2>&1; then
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

