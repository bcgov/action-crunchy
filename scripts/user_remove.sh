#!/bin/bash

set -euo pipefail
set -x

# Input validation
if [ -z "${1:-}" ]; then
    echo "Remove a PR-appropriate user from the Crunchy DB"
    echo "Usage: $0 <github_pr_no> <repo_name>"
    exit 1
fi

# Inputs and variables
PR_NO="${1}"
CLUSTER_NAME="${2}"

# Check if postgres-crunchy exists or else exit
if ! oc get PostgresCluster/"${CLUSTER_NAME}"; then
    echo "Cluster ${CLUSTER_NAME} does not exist. Exiting."
    exit 0
fi

# Remove the user from the crunchy cluster yaml and apply the changes
USER_TO_REMOVE="{\"databases\":[\"app-${PR_NO}\"],\"name\":\"app-${PR_NO}\"}"

echo 'getting current users from crunchy'
CURRENT_USERS=$(oc get PostgresCluster/"${CLUSTER_NAME}" -o json | jq '.spec.users')
echo "${CURRENT_USERS}"

# Remove the user from the list, 
UPDATED_USERS=$(echo "${CURRENT_USERS}" | jq --argjson user "${USER_TO_REMOVE}" 'map(select(. != $user))')
PATCH_JSON=$(jq -n --argjson users "${UPDATED_USERS}" '{"spec": {"users": $users}}')
oc patch PostgresCluster/"${CLUSTER_NAME}" --type=merge -p "${PATCH_JSON}"

# get primary crunchy pod and remove the role and db
CRUNCHY_PG_PRIMARY_POD_NAME=$(oc get pods -l postgres-operator.crunchydata.com/cluster="${CLUSTER_NAME}",postgres-operator.crunchydata.com/role=master -o json | jq -r '.items[0].metadata.name')
echo "${CRUNCHY_PG_PRIMARY_POD_NAME}"

# Terminate all connections to the database before trying terminate and Drop the databse and role right after
oc exec -it "${CRUNCHY_PG_PRIMARY_POD_NAME}" -- bash -c "psql -U postgres -d postgres -c \"SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = 'app-${PR_NO}' AND pid <> pg_backend_pid();\" && \psql -U postgres -d postgres -c \"DROP DATABASE \\\"app-${PR_NO}\\\";\" && \psql -U postgres -d postgres -c \"DROP ROLE \\\"app-${PR_NO}\\\";\""
echo 'database and role deleted'
