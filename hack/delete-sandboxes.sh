#!/usr/bin/env bash
# Deletes the demo's agent sandboxes from the OpenShell gateway: the ones the
# promotion creates (support-<stage>), and acme-support-<stage> from before
# they were renamed. Pass names to delete only those. The next promotion to a
# stage creates its sandbox again.
#
# Runs the openshell CLI in the cluster with hack/openshell.sh.
#
# Usage: hack/delete-sandboxes.sh [--context <kube-context>] [--yes] [NAME...]
set -euo pipefail

cd "$(dirname "$0")/.."

openshell=(hack/openshell.sh)
yes=false
names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context) openshell+=(--context "$2"); shift 2 ;;
    --context=*) openshell+=(--context "${1#*=}"); shift ;;
    -y|--yes) yes=true; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done

if [ "${#names[@]}" -eq 0 ]; then
  echo "Listing sandboxes..."
  while read -r name; do
    [ -n "$name" ] && names+=("$name")
  done < <("${openshell[@]}" sandbox list --names | grep -E '^(acme-)?support-' || true)
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

"${openshell[@]}" sandbox delete "${names[@]}"
