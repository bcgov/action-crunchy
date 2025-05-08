#!/bin/bash

set -euo pipefail
set -x

# Input validation
if [ -z "${1:-}" ]; then
    echo "Create a PR-appropriate user in the Crunchy DB"s
    echo "Usage: $0 <github_pr_no> <repo_name>"
    exit 1
fi

# Inputs and variables
PR_NO="${1}"
CLUSTER_NAME="${2}"

# Add PR specific user to Crunchy DB
echo "Adding PR specific user to Crunchy DB"
NEW_USER="{\"databases\":[\"app-${PR_NO}\"], \"name\":\"app-${PR_NO}\"}"
CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER_NAME}" -o json | jq '.spec.users')
echo "${CURRENT_USERS}"

# check if current_users already contains the new_user
if echo "${CURRENT_USERS}" | jq -e ".[] | select(.name == \"app-${PR_NO}\")" > /dev/null; then
  echo "User already exists"
  exit 0
fi

UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson NEW_USER "${NEW_USER}" '. + [$NEW_USER]')
PATCH_JSON=$(jq -n --argjson users "${UPDATED_USERS}" '{"spec": {"users": $users}}')
oc patch PostgresCluster/"${CLUSTER_NAME}" --type=merge -p "${PATCH_JSON}"
# wait for sometime as it takes time to create the user, query the secret and check if it is created, otherwise wait in a loop for 5 rounds
SECRET_FOUND=false
for i in {1..5}; do
  if oc get secret "${CLUSTER_NAME}-pguser-app-${PR_NO}" -o jsonpath='{.metadata.name}' > /dev/null 2>&1; then
    echo "Secret created"
    SECRET_FOUND=true
    break
  else
    echo "Attempt $i: Secret not created, waiting for 60 seconds"
    sleep 60
  fi
done

if [ "$SECRET_FOUND" = false ]; then
  echo "Error: Secret ${CLUSTER_NAME}-pguser-app-${PR_NO} was not created after 5 attempts."
  exit 1
fi
