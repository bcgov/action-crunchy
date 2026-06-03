#!/usr/bin/env bats
#
# Unit tests for scripts/resolve_helm_args.sh
#
# These run offline in ~seconds and cover the script's full surface:
#   - sizing defaults
#   - postgres_version -> (image, postGISVersion) lookup
#   - unsupported version rejection
#   - guardrail conflict (values_file + overrides)
#   - route_enabled toggle behavior
#   - route_host pass-through
#   - S3 args (all-or-nothing)
#
# Run locally: bats tests/

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/resolve_helm_args.sh"
  # Strip every env var the script reads so prior runs don't bleed in.
  unset VALUES_URL PVC_SIZE STORAGE_CLASS POSTGRES_VERSION REPLICAS \
        CPU_REQUEST MEMORY_REQUEST ROUTE_ENABLED ROUTE_HOST \
        S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_ENDPOINT
}

# ---- defaults --------------------------------------------------------------

@test "defaults: applies documented values for zero-config" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"storage=150Mi"* ]]
  [[ "$output" == *"storageClassName=netapp-block-standard"* ]]
  [[ "$output" == *"crunchy.postgresVersion=18"* ]]
  [[ "$output" == *"crunchy.instances.replicas=2"* ]]
  [[ "$output" == *"requests.cpu=50m"* ]]
  [[ "$output" == *"requests.memory=128Mi"* ]]
}

@test "defaults: emits PG18 image and GIS 3.6 by default" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crunchy-postgres-gis:ubi9-18.1-3.6-2547"* ]]
  [[ "$output" == *"crunchy.postGISVersion=3.6"* ]]
}

@test "defaults: does not emit route.enabled when unset" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"route.enabled"* ]]
}

@test "defaults: does not emit S3 args when unset" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pgBackRest.s3"* ]]
}

# ---- postgres_version lookup ----------------------------------------------

@test "version lookup: PG15 -> ubi9-15.15-3.3-2547, GIS 3.3" {
  POSTGRES_VERSION=15 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crunchy-postgres-gis:ubi9-15.15-3.3-2547"* ]]
  [[ "$output" == *"crunchy.postGISVersion=3.3"* ]]
}

@test "version lookup: PG16 -> ubi9-16.11-3.4-2547, GIS 3.4" {
  POSTGRES_VERSION=16 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crunchy-postgres-gis:ubi9-16.11-3.4-2547"* ]]
  [[ "$output" == *"crunchy.postGISVersion=3.4"* ]]
}

@test "version lookup: PG17 -> ubi9-17.7-3.6-2547, GIS 3.6" {
  POSTGRES_VERSION=17 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crunchy-postgres-gis:ubi9-17.7-3.6-2547"* ]]
  [[ "$output" == *"crunchy.postGISVersion=3.6"* ]]
}

@test "version lookup: PG18 -> ubi9-18.1-3.6-2547, GIS 3.6" {
  POSTGRES_VERSION=18 run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crunchy-postgres-gis:ubi9-18.1-3.6-2547"* ]]
  [[ "$output" == *"crunchy.postGISVersion=3.6"* ]]
}

@test "version lookup: unsupported version exits 1" {
  POSTGRES_VERSION=14 run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported postgres_version"* ]]
}

@test "version lookup: garbage version exits 1" {
  POSTGRES_VERSION=banana run "${SCRIPT}"
  [ "$status" -eq 1 ]
}

# ---- sizing overrides ------------------------------------------------------

@test "overrides: custom pvc_size and storage_class propagate" {
  PVC_SIZE=500Mi STORAGE_CLASS=netapp-file-standard run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"storage=500Mi"* ]]
  [[ "$output" == *"storageClassName=netapp-file-standard"* ]]
}

@test "overrides: custom replicas, cpu, memory propagate" {
  REPLICAS=3 CPU_REQUEST=100m MEMORY_REQUEST=256Mi run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replicas=3"* ]]
  [[ "$output" == *"requests.cpu=100m"* ]]
  [[ "$output" == *"requests.memory=256Mi"* ]]
}

# ---- guardrail -------------------------------------------------------------

@test "guardrail: values_file + pvc_size exits 1" {
  VALUES_URL=file:///tmp/x.yml PVC_SIZE=200Mi run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIGURATION CONFLICT DETECTED"* ]]
}

@test "guardrail: values_file + postgres_version exits 1" {
  VALUES_URL=file:///tmp/x.yml POSTGRES_VERSION=17 run "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "guardrail: values_file + replicas exits 1" {
  VALUES_URL=file:///tmp/x.yml REPLICAS=3 run "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "guardrail: values_file alone is allowed" {
  VALUES_URL=file:///tmp/x.yml run "${SCRIPT}"
  [ "$status" -eq 0 ]
  # No sizing args should be emitted; chart values file owns those.
  [[ "$output" != *"dataVolumeClaimSpec"* ]]
  [[ "$output" != *"postgresVersion"* ]]
}

@test "guardrail: values_file allows route_enabled (route is orthogonal)" {
  VALUES_URL=file:///tmp/x.yml ROUTE_ENABLED=true run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"route.enabled=true"* ]]
}

# ---- route flags -----------------------------------------------------------

@test "route: enabled=true emits --set route.enabled=true" {
  ROUTE_ENABLED=true run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"route.enabled=true"* ]]
}

@test "route: enabled=false emits nothing (chart default is off)" {
  ROUTE_ENABLED=false run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"route.enabled"* ]]
}

@test "route: host without enabled still propagates host" {
  # Edge case: if someone passes a host but not enabled=true, we still emit
  # the host (chart will ignore it). Documents current behavior.
  ROUTE_HOST=db.example.com run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"route.host=db.example.com"* ]]
}

@test "route: enabled + host both propagate" {
  ROUTE_ENABLED=true ROUTE_HOST=db.example.com run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"route.enabled=true"* ]]
  [[ "$output" == *"route.host=db.example.com"* ]]
}

# ---- S3 (all-or-nothing) ---------------------------------------------------

@test "s3: all four vars set -> emits pgBackRest.s3 args" {
  S3_ACCESS_KEY=ak S3_SECRET_KEY=sk S3_BUCKET=b S3_ENDPOINT=https://s3 \
    run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pgBackRest.s3.enabled=true"* ]]
  [[ "$output" == *"pgBackRest.s3.accessKey=ak"* ]]
  [[ "$output" == *"pgBackRest.s3.secretKey=sk"* ]]
  [[ "$output" == *"pgBackRest.s3.bucket=b"* ]]
  [[ "$output" == *"pgBackRest.s3.endpoint=https://s3"* ]]
}

@test "s3: missing one var -> no s3 args emitted" {
  S3_ACCESS_KEY=ak S3_SECRET_KEY=sk S3_BUCKET=b run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pgBackRest.s3"* ]]
}

@test "s3: empty string treated as unset" {
  S3_ACCESS_KEY="" S3_SECRET_KEY=sk S3_BUCKET=b S3_ENDPOINT=https://s3 \
    run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pgBackRest.s3"* ]]
}
