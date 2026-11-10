# Setup

These steps install the demo on a local k3d cluster, with open-source Argo CD
and Kargo in the same cluster. Run the commands below from the repo root.

| Path | What it is | Managed by |
|---|---|---|
| `setup/argocd/` | Applied to Argo CD: the `agent-delivery` project, the app-of-apps, and the Applications | Argo CD |
| `setup/kargo/` | Applied to Kargo: project, Warehouse, Stages, PromotionTask, verification | Kargo |
| `setup/cluster/` | Synced to the demo cluster: Agent Sandbox (v1.0.3), the OpenShell gateway (chart 0.1.6) and its model provider, the Orders API | Argo CD |

## Requirements

- **`k3d`, `kubectl`, `helm`, `kargo`, `jq` and `yq` v4.** The steps below use
  k3d, whose k3s **enforces NetworkPolicy**, which OpenShell's isolation depends
  on. Another cluster needs Kubernetes 1.29 or later and a CNI that enforces it.
- **Docker with 8 GB of memory or more.** One node is enough.
- **[Ollama](https://ollama.com) on the Docker host** (tested with 0.40), with a
  model that supports tool calling. It serves the agent's model. See
  [Local model with Ollama](#local-model-with-ollama).

Both repos and both images are public, so you can use them as published. 
To change the agent or the boundaries yourself, see
[Using your own copies](#using-your-own-copies).

| Image | Used by |
|---|---|
| `ghcr.io/akuity/openshell-tools` | Kargo verification, the gateway setup Job |
| `ghcr.io/akuity/support-agent-demo` | The agent sandboxes |

## 1. Cluster, Argo CD and Kargo

1. Create the cluster. k3d also switches your kubectl context to `k3d-demo`:
   ```sh
   k3d cluster create demo --no-lb --k3s-arg "--disable=traefik@server:0"
   ```
2. Install cert-manager, Argo CD and Argo Rollouts:
   ```sh
   helm install cert-manager cert-manager --repo https://charts.jetstack.io \
     --version 1.21.2 --namespace cert-manager --create-namespace --set crds.enabled=true --wait
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
     --version 10.10.5 --namespace argocd --create-namespace \
     --set 'configs.secret.argocdServerAdminPassword=$2a$10$5vm8wXaSdbuff0m9l21JdevzXBzJFPCi8sy6OOnpZMAG.fOXL7jvO' \
     --set dex.enabled=false --set notifications.enabled=false \
     --set 'server.extraArgs={--insecure}' --wait
   helm install argo-rollouts argo-rollouts --repo https://argoproj.github.io/argo-helm \
     --version 2.43.8 --namespace argo-rollouts --create-namespace --wait
   ```
3. Install Kargo:
   ```sh
   helm install kargo oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.5 \
     --namespace kargo --create-namespace --set api.tls.enabled=false \
     --set api.adminAccount.passwordHash='$pbkdf2-sha256$600000$Fc8fnFyUR9wjfx7Mu0BuEA$IIOU/KwMqEZuFpq0uAGwJTLTgrI0Ep8g7p.XRgId3Ks' \
     --set api.adminAccount.tokenSigningKey=iwishtowashmyirishwristwatch \
     --set database.postgres.password=kargo \
     --set externalWebhooksServer.tls.enabled=false --wait
   ```
   These are the Kargo quickstart's settings. **Both admin passwords are `admin`**,
   so only use them on a cluster that isn't exposed.

   If `helm` can't fetch the chart because of a credential prompt or a 403, the
   chart is public, so download it anonymously and pass the file to `helm install`
   in place of the `oci://` URL:
   ```sh
   T=$(curl -fsSL 'https://ghcr.io/token?scope=repository:akuity/kargo-charts/kargo:pull' | jq -r .token)
   D=$(curl -fsSL -H "Authorization: Bearer $T" -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
     https://ghcr.io/v2/akuity/kargo-charts/kargo/manifests/1.12.5 \
     | jq -r '.layers[] | select(.mediaType=="application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest')
   curl -fsSL -H "Authorization: Bearer $T" -o kargo-1.12.5.tgz https://ghcr.io/v2/akuity/kargo-charts/kargo/blobs/$D
   ```
4. In two separate terminals, open the UIs. Log in with `admin` / `admin`:
   ```sh
   kubectl -n argocd port-forward svc/argocd-server 31443:80  # http://localhost:31443
   kubectl -n kargo port-forward svc/kargo-api 31444:80       # http://localhost:31444
   ```

## 2. Platform

1. Create two Secrets in the demo cluster. Neither is committed:
   ```sh
   kubectl create namespace openshell
   kubectl -n openshell create secret generic anthropic-api-key --from-literal=ANTHROPIC_API_KEY=sk-ant-...
   kubectl -n openshell create secret generic openshell-credential-encryption-key \
     --from-literal=key-encryption-key="$(openssl rand -base64 32)"
   ```
   The first is still required, because the `anthropic` provider needs a
   credential, but Ollama ignores its value. The second is the key the gateway
   encrypts stored credentials with. It's
   created here, not by the chart, because the chart would generate a new one
   on every Argo CD sync, and the gateway would lose access to everything it
   encrypted before.
2. Argo CD runs in the demo cluster, so register that cluster under the name
   the Applications deploy to:
   ```sh
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: cluster-demo
     namespace: argocd
     labels:
       argocd.argoproj.io/secret-type: cluster
   stringData:
     name: demo
     server: https://kubernetes.default.svc
     config: '{"tlsClientConfig":{"insecure":false}}'
   EOF
   ```
3. Create the `agent-delivery` project and the Applications:
   ```sh
   kubectl apply -f setup/argocd/project.yaml -f setup/argocd/apps/
   ```
   The project limits the Applications to this repo, the OpenShell chart, the
   demo's namespaces, and the few cluster-scoped kinds they need. Don't apply
   `setup/argocd/root.yaml`: it targets the `in-cluster` destination, which step
   2 renamed to `demo`.
4. Wait for the Applications to be Healthy:
   ```sh
   kubectl -n argocd get applications -w
   ```
   The `openshell-setup` PostSync Job's log should end with the `anthropic`
   provider listed.

## 3. Kargo

1. Log in, then apply the project, pipeline and verification:
   ```sh
   kargo login http://localhost:31444 --admin --password admin --insecure-skip-tls-verify
   kargo apply -f setup/kargo/
   kargo config set-project acme-support
   ```
   Re-run `kargo apply` whenever you change these files. This doesn't include the
   `freight/` subdirectory.
2. Label the project's namespace, where the verification Jobs run, so the
   gateway NetworkPolicy lets them in:
   ```sh
   kubectl label namespace acme-support openshell.akuity.io/gateway-client=true
   ```
3. Create the Freight, one per agent version:
   ```sh
   kargo apply -f setup/kargo/freight/
   ```
   Apply it after step 2, and only once: Freight is immutable, so applying it
   again only reports that the aliases are already taken.
4. Give the project the gateway's client certificate, which verification uses
   to call the gateway. The values are the base64 strings from
   the chart's `openshell-client-tls` Secret in the demo cluster:
   ```sh
   tls() { kubectl -n openshell get secret openshell-client-tls -o jsonpath="{.data.$1}"; }
   kargo create generic-credentials --project acme-support openshell-gateway-tls \
     --set ca="$(tls 'ca\.crt')" --set cert="$(tls 'tls\.crt')" --set key="$(tls 'tls\.key')"
   ```
5. Follow the [walkthrough](../README.md#walkthrough).

## Local model with Ollama

The agent runs on a local model, so the demo needs no Anthropic credits. Ollama
serves the Anthropic Messages API with tool use, so the harness and the Freight
are unchanged. It runs on the Docker host, outside the 8 GB or so a typical
Docker VM has.

1. Start Ollama, then alias a local model to the model IDs the agent bundles name:
   ```sh
   ollama pull llama3.1:8b
   ollama cp llama3.1:8b claude-opus-5
   ollama cp llama3.1:8b claude-opus-5-5
   ```
2. Check that the cluster can reach it. k3d provides the `host.k3d.internal` name:
   ```sh
   kubectl run ollama-check --rm -i --restart=Never --image=curlimages/curl:8.11.1 \
     --command -- curl -s http://host.k3d.internal:11434/api/version
   ```

Three settings connect the sandboxes to Ollama:

| File | Setting |
|---|---|
| `setup/cluster/openshell-setup/anthropic-python.yaml` | The provider's endpoint is `host.k3d.internal:11434`, not `api.anthropic.com:443` |
| `setup/kargo/30_analysis-template.yaml` | `openshell-sandbox-apply` sets `ANTHROPIC_BASE_URL=http://host.k3d.internal:11434` |
| `setup/argocd/apps/openshell-setup.yaml` | `targetRevision` is `local-oss-kargo`, the branch with the provider change |

On a cluster other than k3d, replace `host.k3d.internal` in the first two files
with an address that reaches Ollama. If Ollama doesn't answer from the cluster,
start it with `OLLAMA_HOST=0.0.0.0`.

To return to Claude, restore `api.anthropic.com` on port 443 in the provider,
remove the `ANTHROPIC_BASE_URL` line, and use a real Anthropic key in the
`anthropic-api-key` Secret.

### Hosted model through OpenRouter

The 7B and 8B local models fail `v4-refunds`' refund eval (see the
[walkthrough](../README.md#walkthrough)). To run v4, serve the agent from a
hosted model instead, with an [OpenRouter](https://openrouter.ai) key and a
little credit. Claude Haiku 5.5 passes all evals, at a few cents at most for
the walkthrough.

[`hack/openrouter-proxy.py`](../hack/openrouter-proxy.py) takes Ollama's place
on port 11434, so the cluster settings above stay as they are. It renames the
model the agent asks for to an OpenRouter ID and sends your key as a bearer
token. The key stays in that process on your machine, never in the cluster.

1. Quit Ollama (menu bar > Quit Ollama) to free the port.
2. In a separate terminal, start the proxy and enter your key at the hidden
   prompt. Leave it running:
   ```sh
   python3 -I hack/openrouter-proxy.py
   ```
   Set `OPENROUTER_MODEL` to use another model, for example a free one; free
   models are rate-limited, which can fail evals.
3. Re-run verification on a Stage, for example `kargo verify stage dev`. Each
   model call prints a line in the proxy's terminal, with `200` on success,
   `401` for a bad key, and `402` for no credit.

The proxy listens on `127.0.0.1`, which Docker Desktop forwards
`host.k3d.internal` to. On Linux, set `PROXY_HOST` to the address that
`host.k3d.internal` resolves to. To go back to Ollama, stop the proxy and start
Ollama.

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
  image digest in `setup/kargo/30_analysis-template.yaml`, which pins it.
- `support-agent-demo` is built by its release workflow on each GitHub release
  (`v0.1.0` → `0.1.0`). Your build has a different digest, so refill
  `setup/kargo/freight/freight.yaml` afterwards, as described in
  `support-agent-demo`'s maintainer note.

## Cleanup

Everything runs in the k3d cluster, so deleting it removes the demo, including
the Secrets and the gateway's database. Then remove the model aliases:

```sh
k3d cluster delete demo
ollama rm claude-opus-5 claude-opus-5-5
```

The aliases share the base model's data, so this doesn't remove `llama3.1:8b`.
