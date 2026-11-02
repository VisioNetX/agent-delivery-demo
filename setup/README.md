# Setup

These manifests target an **existing** Argo CD and Kargo Enterprise. Run the
commands below from the repo root.

| Path | What it is | Managed by |
|---|---|---|
| `setup/argocd/` | Applied to Argo CD: the `agent-delivery` project, the app-of-apps, and the Applications | Argo CD |
| `setup/kargo/` | Applied to Kargo: project, Warehouse, Stages, PromotionTask, Custom Steps, verification | Kargo |
| `setup/cluster/` | Synced to the demo cluster: Agent Sandbox (v1.0.3), the OpenShell gateway (chart 0.1.6) and its Anthropic provider, the Orders API | Argo CD |

## Requirements

- **A demo Kubernetes cluster.** Version 1.29 or later, and a CNI that
  **enforces NetworkPolicy**. OpenShell's isolation depends on it. k3s/k3d is
  fine: it ships kube-router.
- **Argo CD** with the demo cluster registered under the name
  `demo`. Otherwise, edit `destination.name` in
  `setup/argocd/apps/*.yaml`.
- **Kargo Enterprise v1.11 or later**, for Custom Steps. Its promotion
  and verification pods must run in the demo cluster, because they call the
  gateway Service at `openshell.openshell.svc.cluster.local`.
- **An Anthropic API key.**

Both repos and both images are public, so you can use them as published. 
To change the agent or the boundaries yourself, see
[Using your own copies](#using-your-own-copies).

| Image | Used by |
|---|---|
| `ghcr.io/akuity/openshell-tools` | Kargo Custom Steps, verification, the gateway setup Job |
| `ghcr.io/akuity/support-agent-demo` | The agent sandboxes |

## 1. Argo CD

1. Create two Secrets in the demo cluster. Neither is committed:
   ```sh
   kubectl create namespace openshell
   kubectl -n openshell create secret generic anthropic-api-key --from-literal=ANTHROPIC_API_KEY=sk-ant-...
   kubectl -n openshell create secret generic openshell-credential-encryption-key \
     --from-literal=key-encryption-key="$(openssl rand -base64 32)"
   ```
   The second is the key the gateway encrypts stored credentials with. It's
   created here, not by the chart, because the chart would generate a new one
   on every Argo CD sync, and the gateway would lose access to everything it
   encrypted before.
2. Create the `agent-delivery` project, then the app-of-apps:
   ```sh
   argocd login <argocd-server> --sso
   argocd proj create -f setup/argocd/project.yaml --upsert
   argocd app create -f setup/argocd/root.yaml --upsert
   ```
   The project limits the Applications to this repo, the OpenShell chart, the
   demo's namespaces, and the few cluster-scoped kinds they need. The
   app-of-apps creates its Applications in the Argo CD control plane. If it
   can't, create the three in `setup/argocd/apps/` directly with
   `argocd app create -f`.
3. Wait for the Applications to be Healthy:
   ```sh
   argocd app wait openshell openshell-setup orders-api --health
   ```
   The `openshell-setup` PostSync Job's log should end with the `anthropic`
   provider listed.

## 2. Kargo

1. Label the namespace where Kargo runs promotion and verification pods in the
   demo cluster, so the gateway NetworkPolicy lets them in:
   ```sh
   kubectl label namespace <kargo-namespace> openshell.akuity.io/gateway-client=true
   ```
2. Apply the project, pipeline and verification to the Kargo control plane:
   ```sh
   kargo apply -f setup/kargo/
   ```
   Re-run it whenever you change these files. This doesn't include the `freight/` subdirectory.
3. Create the Freight, one per agent version:
   ```sh
   kargo apply -f setup/kargo/freight/
   ```
   Apply it after step 2, and only once: Freight is immutable, so applying it
   again only reports that the aliases are already taken.
4. Give the project the gateway's client certificate, which the Custom Steps and
   verification use to call the gateway. The values are the base64 strings from
   the chart's `openshell-client-tls` Secret in the demo cluster:
   ```sh
   tls() { kubectl -n openshell get secret openshell-client-tls -o jsonpath="{.data.$1}"; }
   kargo create generic-credentials --project acme-support openshell-gateway-tls \
     --set ca="$(tls 'ca\.crt')" --set cert="$(tls 'tls\.crt')" --set key="$(tls 'tls\.key')"
   ```
5. Follow the [walkthrough](../README.md#walkthrough).

## Using your own copies

To change the agent or the boundaries yourself, fork both repos into the same
GitHub org or user, and point each fork's Git URLs at it:

```sh
git grep -l 'github\.com/akuity/' \
  | xargs sed -i '' 's#github\.com/akuity/#github.com/<your-github-org>/#g'
```

Leave the `ghcr.io/akuity/` images and the `*.akuity.io` API groups and labels
alone. To build your own images too, for example to change the harness code,
also rewrite the `ghcr.io/akuity/` prefix, enable Actions in the forks (GitHub
disables workflows in forks by default), and make the resulting GHCR packages
public:

- `openshell-tools` is built by `.github/workflows/openshell-tools.yaml`, which
  you run by hand (Actions > Build openshell-tools image > Run workflow) with
  the tag to build. The tag is the bundled OpenShell version (`0.1.6`), or the
  next `-N` build of it (`0.1.6-1`) for a scripts-only change. Check
  "overwrite" to replace a tag that's already published. Then update the
  image digest in `setup/kargo/10_custom-steps.yaml`, which pins it.
- `support-agent-demo` is built by its release workflow on each GitHub release
  (`v0.1.0` → `0.1.0`). Your build has a different digest, so refill
  `setup/kargo/freight/freight.yaml` afterwards, as described in
  `support-agent-demo`'s maintainer note.

## Cleanup

Tear down in this order: Kargo first so nothing promotes, then the sandboxes
while the gateway can still delete them, then the platform.

1. Delete the Kargo project. This removes its Stages, Freight, Warehouse,
   PromotionTask, verification template and credentials:
   ```sh
   kargo delete project acme-support
   ```
   The two `CustomPromotionStep`s are cluster-scoped, so they stay. Delete
   `openshell-policy-prove` and `openshell-sandbox-apply` in the Kargo UI, or
   with `kubectl delete custompromotionstep` against the Kargo control plane.
2. Delete the sandboxes through the gateway:
   ```sh
   hack/delete-sandboxes.sh --yes
   ```
3. Delete the Argo CD Applications. Remove the app-of-apps first without
   cascading, so it doesn't recreate the others, then delete each one with its
   resources:
   ```sh
   argocd app delete openshell-platform --cascade=false --yes
   argocd app delete openshell-setup orders-api openshell --yes
   argocd proj delete agent-delivery
   ```
   Deleting `openshell` also removes the Agent Sandbox CRD, its controller and
   the `agent-sandbox-system` namespace.
4. Delete what Argo CD doesn't own: the namespaces, which still hold the
   gateway's database volume and the API key Secret, and the label on the
   Kargo namespace:
   ```sh
   kubectl delete namespace openshell orders
   kubectl label namespace <kargo-namespace> openshell.akuity.io/gateway-client-
   ```
