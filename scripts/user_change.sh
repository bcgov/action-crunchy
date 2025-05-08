#!/bin/bash

# Catch errors and unset variables
set -euo pipefail

# Input validation
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <add|remove> <github_pr_no> <cluster_name>"
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

# Set target database and user
TARGET_USER="{\"databases\":[\"app-${PR_NO}\"], \"name\":\"app-${PR_NO}\"}"

# Check if the user already exists
CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER_NAME}" -o json | jq '.spec.users')
echo "${CURRENT_USERS}"

# Function to check if a user exists in the current users list
user_exists() {
    local user_name="$1"
    local current_users="$2"
    echo "${current_users}" | jq -e ".[] | select(.name == \"${user_name}\")" > /dev/null && echo 1 || echo 0
}

# Function to patch PostgresCluster with updated users
patch_postgres_cluster() {
    local cluster_name="$1"
    local updated_users="$2"
    local patch_json
    patch_json=$(jq -n --argjson users "${updated_users}" '{"spec": {"users": $users}}')
    oc patch PostgresCluster/"${cluster_name}" --type=merge -p "${patch_json}"
}

# Function to wait for a secret to be created
wait_for_secret() {
    local secret_name="$1"
    for i in {1..5}; do
        if oc get secret "${secret_name}" -o jsonpath='{.metadata.name}' > /dev/null 2>&1; then
            echo "Secret created"
            return 0
        else
            echo "Attempt $i: Secret not created, waiting for 60 seconds"
            sleep 60
        fi
    done
    echo "Error: Secret ${secret_name} was not created after 5 attempts."
    return 1
}

USER_EXISTS=$(user_exists "app-${PR_NO}" "${CURRENT_USERS}")

# Perform add or remove
if [ "$ACTION" == "add" ]; then
    # Add PR specific user to Crunchy DB
    echo "Adding PR specific user to Crunchy DB"

    if [ "$USER_EXISTS" -eq 1 ]; then
      echo "User already exists. Exiting."
      exit 0
    fi

    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson TARGET_USER "${TARGET_USER}" '. + [$TARGET_USER]')
    patch_postgres_cluster "${CLUSTER_NAME}" "${UPDATED_USERS}"

    # Wait for the secret to be created
    wait_for_secret "${CLUSTER_NAME}-pguser-app-${PR_NO}" || exit 1

elif [ "$ACTION" == "remove" ]; then
    # Remove the user from the crunchy cluster yaml and apply the changes
    echo "Removing PR specific user from Crunchy DB"

    if [ "$USER_EXISTS" -eq 0 ]; then
      echo "User does not exist to remove. Exiting."
      exit 0
    fi

    # Remove the user from the list
    UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson user "${TARGET_USER}" 'map(select(. != $user))')
    patch_postgres_cluster "${CLUSTER_NAME}" "${UPDATED_USERS}"

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
