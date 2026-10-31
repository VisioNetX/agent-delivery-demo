#!/usr/bin/env bash
# Runs an openshell CLI command against the demo's gateway, for example:
#
#   hack/openshell.sh policy get support-prod-eu --base   # the policy Kargo applied
#   hack/openshell.sh policy get support-prod-eu --full   # plus the provider's rules
#   hack/openshell.sh policy list support-prod-us         # its versions
#   hack/openshell.sh sandbox list
#
# The gateway is only reachable inside the cluster and needs a client
# certificate, so the CLI runs in a one-off pod in the openshell namespace,
# with the chart's openshell-client-tls Secret mounted. The key never leaves
# the cluster. The pod uses the openshell-tools image the Custom Steps pin.
# Local files and stdin aren't passed to the pod.
#
# Usage: hack/openshell.sh [--context <kube-context>] <openshell arguments...>
#
# Needs kubectl, jq and yq v4.
set -euo pipefail

cd "$(dirname "$0")/.."

kubectl_args=(-n openshell)
case "${1:-}" in
  --context) kubectl_args=(--context "$2" "${kubectl_args[@]}"); shift 2 ;;
  --context=*) kubectl_args=(--context "${1#*=}" "${kubectl_args[@]}"); shift ;;
  ""|-h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

image=$(yq -N 'select(.metadata.name == "openshell-sandbox-apply") | .spec.image' setup/kargo/10_custom-steps.yaml)
cmd='mkdir -p "$XDG_CONFIG_HOME/openshell/gateways/openshell" &&
  cp -r /tls "$XDG_CONFIG_HOME/openshell/gateways/openshell/mtls" &&
  openshell "$@"'
args=$(printf '%s\n' "$@" | jq -R . | jq -s .)
overrides=$(jq -n --arg image "$image" --arg cmd "$cmd" --argjson args "$args" '{spec: {containers: [{
    name: "openshell-cli",
    image: $image,
    command: (["sh", "-c", $cmd, "openshell"] + $args),
    volumeMounts: [{name: "tls", mountPath: "/tls", readOnly: true}]
  }],
  volumes: [{name: "tls", secret: {secretName: "openshell-client-tls"}}]}}')

# --rm needs -i, but the pod never reads stdin, so don't let it take the
# caller's.
exec kubectl "${kubectl_args[@]}" run "openshell-cli-$$-$RANDOM" --rm -i --quiet --restart=Never \
  --image="$image" --overrides="$overrides" </dev/null
