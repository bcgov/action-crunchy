#!/bin/bash
#
# Pure helper: resolves Helm --set arguments for the crunchy chart from
# environment variables. Performs validation and emits the assembled string
# to stdout. Has no side effects (no cd, no helm, no curl), which makes it
# trivially unit-testable from bats.
#
# Inputs (env vars):
#   VALUES_URL          Non-empty when caller supplied a values_file. When set,
#                       any sizing/version override env vars trigger a fail-fast
#                       guardrail (mutually exclusive with file-based config).
#   PVC_SIZE            Default: 150Mi
#   STORAGE_CLASS       Default: netapp-block-standard
#   POSTGRES_VERSION    Default: 18. Must be 15/16/17/18 (operator 5.8.5).
#   REPLICAS            Default: 2
#   CPU_REQUEST         Default: 50m
#   MEMORY_REQUEST      Default: 128Mi
#   ROUTE_ENABLED       'true' to emit --set route.enabled=true
#   ROUTE_HOST          Optional route hostname
#   S3_ACCESS_KEY       All four S3_* vars must be set together to enable
#   S3_SECRET_KEY       pgBackRest S3 backups.
#   S3_BUCKET
#   S3_ENDPOINT
#
# Output: assembled SET_STRINGS on stdout; diagnostics on stderr.
# Exit:   0 on success, 1 on validation failure.

set -euo pipefail

VALUES_URL="${VALUES_URL:-}"

# Conflict check: custom values_file is mutually exclusive with sizing/version
# overrides because we can't reliably merge a user-authored file with --set
# flags without surprising precedence behavior.
if [ -n "${VALUES_URL}" ]; then
  if [ -n "${PVC_SIZE:-}" ] || [ -n "${STORAGE_CLASS:-}" ] || \
     [ -n "${POSTGRES_VERSION:-}" ] || [ -n "${REPLICAS:-}" ] || \
     [ -n "${CPU_REQUEST:-}" ] || [ -n "${MEMORY_REQUEST:-}" ]; then
    {
      echo "=========================================================================="
      echo "CONFIGURATION CONFLICT DETECTED"
      echo "=========================================================================="
      echo "You provided a custom 'values_file' (${VALUES_URL}) but also specified"
      echo "one or more database sizing/resource override inputs:"
      echo "  - pvc_size: '${PVC_SIZE:-}'"
      echo "  - storage_class: '${STORAGE_CLASS:-}'"
      echo "  - postgres_version: '${POSTGRES_VERSION:-}'"
      echo "  - replicas: '${REPLICAS:-}'"
      echo "  - cpu_request: '${CPU_REQUEST:-}'"
      echo "  - memory_request: '${MEMORY_REQUEST:-}'"
      echo ""
      echo "Move all sizing/resource settings into your custom values file, OR"
      echo "drop the values_file input and configure exclusively via workflow inputs."
      echo "=========================================================================="
    } >&2
    exit 1
  fi
fi

SET_STRINGS=""

# Sizing/version overrides only apply when no values_file is supplied.
if [ -z "${VALUES_URL}" ]; then
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
  # PostgreSQL major version. Crunchy Operator 5.8.5 only ships defaults for
  # specific PG/PostGIS combos, so an empty image field is unreliable.
  case "${POSTGRES_VERSION}" in
    15) CRUNCHY_IMAGE_TAG="ubi9-15.15-3.3-2547"; CRUNCHY_POSTGIS_VERSION="3.3" ;;
    16) CRUNCHY_IMAGE_TAG="ubi9-16.11-3.4-2547"; CRUNCHY_POSTGIS_VERSION="3.4" ;;
    17) CRUNCHY_IMAGE_TAG="ubi9-17.7-3.6-2547";  CRUNCHY_POSTGIS_VERSION="3.6" ;;
    18) CRUNCHY_IMAGE_TAG="ubi9-18.1-3.6-2547";  CRUNCHY_POSTGIS_VERSION="3.6" ;;
    *)
      {
        echo "Error: Unsupported postgres_version '${POSTGRES_VERSION}'."
        echo "Supported values (Crunchy Operator 5.8.5): 15, 16, 17, 18."
        echo "For combinations outside this list, supply a custom values_file"
        echo "with crunchy.image and crunchy.postGISVersion set explicitly."
      } >&2
      exit 1
      ;;
  esac
  SET_STRINGS+=" --set-string crunchy.image=artifacts.developer.gov.bc.ca/bcgov-docker-local/crunchy-postgres-gis:${CRUNCHY_IMAGE_TAG}"
  SET_STRINGS+=" --set-string crunchy.postGISVersion=${CRUNCHY_POSTGIS_VERSION}"

  SET_STRINGS+=" --set crunchy.instances.replicas=${REPLICAS}"
  SET_STRINGS+=" --set-string crunchy.instances.requests.cpu=${CPU_REQUEST}"
  SET_STRINGS+=" --set-string crunchy.instances.requests.memory=${MEMORY_REQUEST}"
fi

if [ "${ROUTE_ENABLED:-false}" = "true" ]; then
  SET_STRINGS+=" --set route.enabled=true"
fi

if [ -n "${ROUTE_HOST:-}" ]; then
  SET_STRINGS+=" --set-string route.host=${ROUTE_HOST}"
fi

if [ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ] && \
   [ -n "${S3_BUCKET:-}" ] && [ -n "${S3_ENDPOINT:-}" ]; then
  SET_STRINGS+=" --set crunchy.pgBackRest.s3.enabled=true"
  SET_STRINGS+=" --set-string crunchy.pgBackRest.s3.accessKey=${S3_ACCESS_KEY}"
  SET_STRINGS+=" --set-string crunchy.pgBackRest.s3.secretKey=${S3_SECRET_KEY}"
  SET_STRINGS+=" --set-string crunchy.pgBackRest.s3.bucket=${S3_BUCKET}"
  SET_STRINGS+=" --set-string crunchy.pgBackRest.s3.endpoint=${S3_ENDPOINT}"
fi

# Trim leading space for cleaner output
echo "${SET_STRINGS# }"
