#!/bin/bash
set -x
# Add PR specific user to Crunchy DB
NEW_USER='{"databases":["app-$1"],"name":"app-$1"}'
CURRENT_USERS=$(oc get PostgresCluster/"$2" -o json | jq '.spec.users')
echo "${CURRENT_USERS}"

# Check if current_users already contains the new_user
if echo "${CURRENT_USERS}" | jq -e ".[] | select(.name == \"app-$1\")" > /dev/null; then
  echo "User already exists"
  exit 0
fi

UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson NEW_USER "${NEW_USER}" '. + [$NEW_USER]')
PATCH_JSON=$(jq -n --argjson users "${UPDATED_USERS}" '{"spec": {"users": $users}}')
oc patch PostgresCluster/"$2" --type=merge -p "${PATCH_JSON}"

# Build the CLUSTER_NAME variable based on the repository name
CLUSTER_NAME=pg-$(echo -n "$3" | md5sum | cut -c 1-8)-crunchy

# Wait for the secret to be created
SECRET_FOUND=false
for i in {1..5}; do
  if oc get secret "$2-pguser-app-$1" -o jsonpath='{.metadata.name}' > /dev/null 2>&1; then
    echo "Secret created"
    SECRET_FOUND=true
    break
  else
    echo "Attempt $i: Secret not created, waiting for 60 seconds"
    sleep 60
  fi
done

if [ "$SECRET_FOUND" = false ]; then
  echo "Error: Secret $2-pguser-app-$1 was not created after 5 attempts."
  exit 1
fi
