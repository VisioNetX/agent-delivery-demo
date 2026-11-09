#!/usr/bin/env bash
# Checks the sandbox name each Stage's verification Job applies and runs its
# evals against: the `sandbox` arg in setup/kargo/50_stages.yaml. OpenShell only
# rejects a bad name when it creates the sandbox, during verification.
#
# OpenShell's rules (openshell-server/src/grpc/validation.rs, v0.1.6): at most
# 19 characters, since it builds DNS labels as workspace--sandbox--service;
# lowercase letters, digits and hyphens; no leading, trailing or double hyphen.
#
# Also checks that each Stage gets its own support-<stage> sandbox.
#
# Needs yq v4 (https://github.com/mikefarah/yq).
set -euo pipefail

cd "$(dirname "$0")/.."
stages=setup/kargo/50_stages.yaml
max=19

failed=0
fail() {
  echo "FAIL $1"
  failed=1
  stage_failed=1
}

for stage in $(yq -N 'select(.kind == "Stage") | .metadata.name' "$stages"); do
  stage_failed=0
  name=$(STAGE="$stage" yq -N 'select(.kind == "Stage" and .metadata.name == strenv(STAGE))
    | .spec.verification.args[] | select(.name == "sandbox") | .value' "$stages")
  if [ "${#name}" -gt "$max" ]; then
    fail "$stage: sandbox name $name is ${#name} characters (OpenShell allows $max)"
  fi
  if ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    fail "$stage: sandbox name $name must be lowercase letters, digits and single hyphens"
  fi
  if [ "$name" != "support-$stage" ]; then
    fail "$stage: verification runs against sandbox '$name', expected support-$stage"
  fi
  if [ "$stage_failed" -eq 0 ]; then
    echo "ok   $stage: $name (${#name}/$max)"
  fi
done

exit "$failed"
