#!/usr/bin/env bash
# Runs an openshell CLI command against the demo's gateway, for example:
#
#   hack/openshell.sh policy get support-prod-eu --base   # the policy Kargo applied
#   hack/openshell.sh policy get support-prod-eu --full   # plus the provider's rules
#   hack/openshell.sh policy list support-prod-us         # its versions
#   hack/openshell.sh sandbox list
#   hack/openshell.sh sandbox connect support-dev        # a shell in the sandbox
#
# The gateway is only reachable inside the cluster and needs a client
# certificate, so the CLI runs in a one-off pod in the openshell namespace,
# with the chart's openshell-client-tls Secret mounted. The key never leaves
# the cluster. The pod uses the openshell-tools image the verification Job pins.
# Run from a terminal, it's interactive (stdin and a TTY); with its output
# piped, it reads no stdin. Local files aren't passed to the pod.
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
  ""|-h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

image=$(yq -N '.spec.metrics[0].provider.job.spec.template.spec.containers[0].image' setup/kargo/30_analysis-template.yaml)
cmd='mkdir -p "$XDG_CONFIG_HOME/openshell/gateways/openshell" &&
  cp -r /tls "$XDG_CONFIG_HOME/openshell/gateways/openshell/mtls" &&
  { i=0; until openshell sandbox list >/dev/null 2>&1 || [ "$i" -ge 15 ]; do i=$((i+1)); sleep 1; done; } &&
  openshell "$@"'
# The wait above is for k3s: NetworkPolicy reaches a new pod a moment after it
# starts, so its first connection to the gateway can fail.
# Interactive only when both stdin and stdout are a terminal: a TTY turns
# newlines into CRLF, which would break callers that parse the output.
tty=false
if [ -t 0 ] && [ -t 1 ]; then
  tty=true
fi

args=$(printf '%s\n' "$@" | jq -R . | jq -s .)
# --overrides replaces the whole container, so it carries stdin and tty too.
overrides=$(jq -n --arg image "$image" --arg cmd "$cmd" --argjson args "$args" --argjson tty "$tty" '{spec: {containers: [{
    name: "openshell-cli",
    image: $image,
    command: (["sh", "-c", $cmd, "openshell"] + $args),
    stdin: true,
    stdinOnce: true,
    tty: $tty,
    volumeMounts: [{name: "tls", mountPath: "/tls", readOnly: true}]
  }],
  volumes: [{name: "tls", secret: {secretName: "openshell-client-tls"}}]}}')

run=(kubectl "${kubectl_args[@]}" run "openshell-cli-$$-$RANDOM" --rm --quiet --restart=Never
  --image="$image" --overrides="$overrides")
if $tty; then
  exec "${run[@]}" -it
fi
# --rm needs -i. The pod gets no stdin, so it can't take input meant for the
# caller, such as an answer to a prompt.
exec "${run[@]}" -i </dev/null
