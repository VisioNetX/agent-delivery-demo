#!/usr/bin/env bash
# Checks the sandbox name each Stage gets, the way the promotion builds it: the
# apply step's `name` (setup/kargo/20_promotion-task.yaml) with the Stage's
# name in place of ${{ ctx.stage }}. OpenShell only rejects a bad name when it
# creates the sandbox, at promotion time.
#
# OpenShell's rules (openshell-server/src/grpc/validation.rs, v0.1.6): at most
# 19 characters, since it builds DNS labels as workspace--sandbox--service;
# lowercase letters, digits and hyphens; no leading, trailing or double hyphen.
#
# Also checks that each Stage's verification runs against that same sandbox.
#
# Needs yq v4 (https://github.com/mikefarah/yq).
set -euo pipefail

cd "$(dirname "$0")/.."
task=setup/kargo/20_promotion-task.yaml
stages=setup/kargo/50_stages.yaml
max=19

template=$(yq '.spec.steps[] | select(.as == "apply") | .config.name' "$task")
failed=0
fail() {
  echo "FAIL $1"
  failed=1
  stage_failed=1
}

for stage in $(yq -N 'select(.kind == "Stage") | .metadata.name' "$stages"); do
  stage_failed=0
  name=${template//'${{ ctx.stage }}'/$stage}
  if [[ "$name" == *'${{'* ]]; then
    fail "$stage: can't resolve the sandbox name $name"
    continue
  fi
  if [ "${#name}" -gt "$max" ]; then
    fail "$stage: sandbox name $name is ${#name} characters (OpenShell allows $max)"
  fi
  if ! [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    fail "$stage: sandbox name $name must be lowercase letters, digits and single hyphens"
  fi
  verify=$(STAGE="$stage" yq -N 'select(.kind == "Stage" and .metadata.name == strenv(STAGE))
    | .spec.verification.args[] | select(.name == "sandbox") | .value' "$stages")
  if [ "$verify" != "$name" ]; then
    fail "$stage: verification runs against sandbox '$verify', but the promotion applies $name"
  fi
  if [ "$stage_failed" -eq 0 ]; then
    echo "ok   $stage: $name (${#name}/$max)"
  fi
done

exit "$failed"
