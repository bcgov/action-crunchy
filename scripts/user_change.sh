#!/bin/bash

set -euo pipefail
set -x

# Input validation
if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "Usage: $0 <add|remove> <github_pr_no> <repo_name>"
    exit 1
fi

# Inputs and variables
ACTION="${1}"
PR_NO="${2}"
CLUSTER_NAME="${3}"

# Check if postgres-crunchy exists or else exit
if ! oc get PostgresCluster/"${CLUSTER_NAME}"; then
    echo "Cluster ${CLUSTER_NAME} does not exist. Exiting."
    exit 0
fi

if [ "$ACTION" == "add" ]; then
    # Add PR specific user to Crunchy DB
    echo "Adding PR specific user to Crunchy DB"
    NEW_USER="{\"databases\":[\"app-${PR_NO}\"], \"name\":\"app-${PR_NO}\"}"
    CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER_NAME}" -o json | jq '.spec.users')
    echo "${CURRENT_USERS}"

    # Check if current_users already contains the new_user
    if echo "${CURRENT_USERS}" | jq -e ".[] | select(.name == \"app-${PR_NO}\")" > /dev/null; then
      echo "User already exists"
      exit 0
    fi

    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson NEW_USER "${NEW_USER}" '. + [$NEW_USER]')
    PATCH_JSON=$(jq -n --argjson users "${UPDATED_USERS}" '{"spec": {"users": $users}}')
    oc patch PostgresCluster/"${CLUSTER_NAME}" --type=merge -p "${PATCH_JSON}"

    # Wait for the secret to be created
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

elif [ "$ACTION" == "remove" ]; then
    # Remove the user from the crunchy cluster yaml and apply the changes
    echo "Removing PR specific user from Crunchy DB"
    USER_TO_REMOVE="{\"databases\":[\"app-${PR_NO}\"], \"name\":\"app-${PR_NO}\"}"

    echo 'Getting current users from Crunchy DB'
    CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER_NAME}" -o json | jq '.spec.users')
    echo "${CURRENT_USERS}"

    # Remove the user from the list
    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson user "${USER_TO_REMOVE}" 'map(select(. != $user))')
    PATCH_JSON=$(jq -n --argjson users "${UPDATED_USERS}" '{"spec": {"users": $users}}')
    oc patch PostgresCluster/"${CLUSTER_NAME}" --type=merge -p "${PATCH_JSON}"

    # Get primary crunchy pod and remove the role and database
    CRUNCHY_PG_PRIMARY_POD_NAME=$(oc get pods -l postgres-operator.crunchydata.com/cluster="${CLUSTER_NAME}",postgres-operator.crunchydata.com/role=master -o json | jq -r '.items[0].metadata.name')
    echo "${CRUNCHY_PG_PRIMARY_POD_NAME}"

    # Terminate all connections to the database and drop the database and role
    oc exec -it "${CRUNCHY_PG_PRIMARY_POD_NAME}" -- bash -c "psql -U postgres -d postgres -c \"SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = 'app-${PR_NO}' AND pid <> pg_backend_pid();\" && \
    psql -U postgres -d postgres -c \"DROP DATABASE \\\"app-${PR_NO}\\\";\" && \
    psql -U postgres -d postgres -c \"DROP ROLE \\\"app-${PR_NO}\\\";\""
    echo 'Database and role deleted'

else
    echo "Invalid action: $ACTION. Use 'add' or 'remove'."
    exit 1
fi
