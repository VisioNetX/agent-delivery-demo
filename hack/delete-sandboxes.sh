#!/usr/bin/env bash
# Deletes the demo's agent sandboxes from the OpenShell gateway: the ones the
# promotion creates (support-<stage>), and acme-support-<stage> from before
# they were renamed. Pass names to delete only those. The next promotion to a
# stage creates its sandbox again.
#
# The gateway is only reachable inside the cluster and needs a client
# certificate, so the openshell CLI runs in a one-off pod in the openshell
# namespace, with the chart's openshell-client-tls Secret mounted. The key
# never leaves the cluster. The pod uses the openshell-tools image the Custom
# Steps pin.
#
# Usage: hack/delete-sandboxes.sh [--context <kube-context>] [--yes] [NAME...]
#
# Needs kubectl, jq and yq v4.
set -euo pipefail

cd "$(dirname "$0")/.."

context=""
yes=false
names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --context=*) context="${1#*=}"; shift ;;
    -y|--yes) yes=true; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done

image=$(yq -N 'select(.metadata.name == "openshell-sandbox-apply") | .spec.image' setup/kargo/10_custom-steps.yaml)
kubectl_args=(-n openshell)
if [ -n "$context" ]; then
  kubectl_args=(--context "$context" "${kubectl_args[@]}")
fi

# Runs `openshell <args>` in a one-off pod and prints its output.
openshell_in_cluster() {
  local cmd
  cmd='mkdir -p "$XDG_CONFIG_HOME/openshell/gateways/openshell" &&
    cp -r /tls "$XDG_CONFIG_HOME/openshell/gateways/openshell/mtls" &&
    openshell "$@"'
  local overrides
  local args
  args=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  overrides=$(jq -n --arg image "$image" --arg cmd "$cmd" --argjson args "$args" '{spec: {containers: [{
      name: "openshell-cli",
      image: $image,
      command: (["sh", "-c", $cmd, "openshell"] + $args),
      volumeMounts: [{name: "tls", mountPath: "/tls", readOnly: true}]
    }],
    volumes: [{name: "tls", secret: {secretName: "openshell-client-tls"}}]}}')
  # --rm needs -i, but the pod never reads stdin, so don't let it take the
  # confirmation answer.
  kubectl "${kubectl_args[@]}" run "openshell-cli-$$-$RANDOM" --rm -i --quiet --restart=Never \
    --image="$image" --overrides="$overrides" </dev/null
}

if [ "${#names[@]}" -eq 0 ]; then
  echo "Listing sandboxes..."
  while read -r name; do
    [ -n "$name" ] && names+=("$name")
  done < <(openshell_in_cluster sandbox list --names | grep -E '^(acme-)?support-' || true)
  if [ "${#names[@]}" -eq 0 ]; then
    echo "No demo sandboxes found."
    exit 0
  fi
fi

echo "Sandboxes to delete:"
printf '  %s\n' "${names[@]}"
if ! $yes; then
  read -r -p "Delete them? [y/N] " answer
  case "$answer" in
    y|Y|yes) ;;
    *) echo "Nothing deleted."; exit 0 ;;
  esac
fi

openshell_in_cluster sandbox delete "${names[@]}"
