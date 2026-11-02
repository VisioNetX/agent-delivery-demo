# Delivering AI Agents with OpenShell, Kargo, and Argo CD

![The acme-support project in Kargo: Freight v1 to v4, the Warehouse, and the dev, prod-us and prod-eu Stages](docs/images/kargo-pipeline.png)

## Overview

Delivering an AI agent isn't the same as updating a container image. An agent
is a composite: a harness image, a model, a system prompt, tool definitions, a
sandbox policy controlling what it can reach, and evals defining what "working"
means. A change to any one of them changes the agent's behavior. Most of them
don't live in the image, so an image-centric pipeline promotes only part of the
agent and leaves the rest to be edited in place.

This demo versions and promotes all of them together:

- **One release.** The harness image digest and the agent bundle form a single
  piece of Kargo Freight, so a prompt or model change is promoted and rolled
  back like an image change.
- **Stage boundaries.** Before each promotion, the
  [OpenShell](https://docs.nvidia.com/openshell/) prover checks that the agent's
  policy fits within that stage's boundary in `boundaries/`. If it doesn't, the
  promotion fails and shows what exceeds the boundary.
- **Evals as verification.** After each promotion, Kargo runs the bundle's evals
  against the live sandbox.

The example agent handles customer support for a fictional store, Acme
Outfitters, using Claude and a mock Orders API.

The demo spans two repos, split by who owns what:

| Repo | Owner | Contains |
|---|---|---|
| [`support-agent-demo`](https://github.com/akuity/support-agent-demo) | Agent team | The harness image and the agent bundle (`agent/`) |
| this repo | Platform and security | The platform, the stage boundaries, and the Kargo pipeline |

The agent team can change anything about the agent, but can't change what a
stage allows. Widening a boundary is a pull request to this repo.


## How it works

```mermaid
%%{init: {"themeVariables": {"fontSize": "12px"}, "flowchart": {"nodeSpacing": 20, "rankSpacing": 30, "padding": 6}}}%%
flowchart LR
    subgraph freight["One piece of Kargo Freight"]
        image["Harness image<br/>(by digest)"]
        bundle["Agent bundle (Git commit)<br/>model · prompt · tools<br/>policy · evals"]
    end

    dev["<b>dev</b><br/>any Orders API call"]
    produs["<b>prod-us</b><br/>read + refunds"]
    prodeu["<b>prod-eu</b><br/>read-only"]

    freight --> dev
    dev --> produs
    dev --> prodeu
```

Argo CD manages everything Kubernetes-native, the long-lived platform the
agents run on:
* **[Agent Sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
  controller:** a Kubernetes SIG project that runs OpenShell's sandboxes as pods.
* **[OpenShell](https://github.com/NVIDIA/OpenShell) gateway:** OpenShell's API
  server, installed from its Helm chart. It creates and manages the sandboxes
  (see [OpenShell in brief](#openshell-in-brief)).
* **Gateway setup:** registers the Anthropic provider, which keeps the API key
  out of every sandbox, and limits which namespaces can reach the gateway.
* **Orders API:** the store backend the agent's tools call.

Kargo manages the agent lifecycle itself, one version at a time. It:
* **Promotes Freight** from stage to stage.
* **Proves the agent's policy** against the stage's boundary with the OpenShell
  prover, and stops the promotion if the policy grants anything more.
* **Applies the agent to the stage's sandbox** through the OpenShell gateway,
  creating or updating it. The prove and apply steps run as
  [Custom Steps](#custom-steps).
* **Verifies each version** by running the agent's evals against the live
  sandbox after every promotion. Freight that fails can't be promoted to the
  next stage.

### OpenShell in brief

[OpenShell](https://docs.nvidia.com/openshell/) runs agents in sandboxes and
controls what they can reach, read, write and authenticate with. The parts this
demo uses:

- **Gateway.** OpenShell's API server, which the `openshell` CLI talks to. It
  keeps sandboxes, their policies and providers in its own database. On
  Kubernetes, it turns each sandbox into an Agent Sandbox `Sandbox` object, but
  the gateway, not that object, is the source of truth.
- **Sandbox.** A pair of pods. The workload pod runs the agent's image under
  OpenShell's runtime. The supervisor pod makes every outbound connection on the
  agent's behalf: the runtime hands it each connection the agent opens, and
  NetworkPolicies leave the workload pod no other way out, so the agent can't
  route around its policy.
- **Policy** (`policy.yaml`). Filesystem and process rules are fixed when the
  sandbox is created. Network rules reload live. Each one names an endpoint, the
  binaries allowed to use it, and for an HTTP API the methods and paths allowed.
  With `enforcement: enforce` the supervisor blocks anything else (the default,
  `audit`, only logs it), and it logs every denial.
- **Provider.** Holds a credential, here the Anthropic API key. The agent sees a
  placeholder, and the supervisor adds the real key only to requests to the
  provider's API.
- **Prover** (`openshell-prover`). Checks whether one policy allows anything
  another doesn't, and if so, returns a request as a counterexample. This demo
  uses it to hold each agent version to its stage's boundary.

```mermaid
%%{init: {"themeVariables": {"fontSize": "12px"}, "flowchart": {"nodeSpacing": 20, "rankSpacing": 30, "padding": 6}}}%%
flowchart LR
    gateway["Gateway<br/>sandboxes · policies · providers"]
    subgraph sandbox["Sandbox"]
        agent["Agent<br/>(workload pod)"]
        supervisor["Supervisor<br/>checks host, binary,<br/>method and path"]
    end
    apis["Orders API<br/>Anthropic API"]

    gateway -- "policy, credentials" --> supervisor
    agent -- "every connection" --> supervisor
    supervisor -- "allowed" --> apis
```

### The agent as Freight

In Kargo, [Freight](https://docs.kargo.io/user-guide/core-concepts/#freight)
is the unit of promotion: an immutable set of artifact references, such as an
image digest and a Git commit, that moves from stage to stage together. Kargo
promotes Freight, never an individual artifact.

The [Warehouse](setup/kargo/40_warehouse.yaml) discovers two kinds of artifact:

- **the harness image**, `ghcr.io/akuity/support-agent-demo`, new on each GitHub
  release;
- **the agent bundle**, the `agent/` directory of the `support-agent-demo` repo,
  new on each commit to `main` that touches it.

Each piece of Freight pairs one image with one bundle commit, so it's one
complete, versioned agent. Because the agent's whole history is already in the
repo, this demo defines its Freight up front in `setup/kargo/freight/freight.yaml`, one
per version, rather than letting the Warehouse create it:

| Part | Source in Freight | What it controls | How it reaches the sandbox |
|---|---|---|---|
| Harness image | Image digest | The tool-use loop and its runtime | Sandbox image. A change recreates the sandbox |
| `agent.yaml` | Git commit | Model, effort, token and turn limits | Uploaded to `/sandbox/agent` |
| `system-prompt.md` | Git commit | Instructions and rules, such as never revealing another customer's order | Uploaded |
| `tools.yaml` | Git commit | Which tools the model can call, and the HTTP request each one makes | Uploaded |
| `policy.yaml` | Git commit | What the sandbox may reach on the network and filesystem. Proven against the stage boundary | Applied by the gateway. Network rules reload live |
| `evals.yaml` | Git commit | What "working" means for this version | Uploaded, and read by verification |

Because the evals travel with the version, verification always tests the agent
version that's actually deployed. The stage boundaries are deliberately *not*
part of the Freight: they come from this repo at promotion time, so no agent
version can change what a stage allows. Neither is the Orders API's address,
which depends on where the agent runs: each Stage sets it in its `ordersApiURL`
variable, and the apply step passes it to the sandbox as `ORDERS_API_URL`.

### What happens when an agent change is promoted

```mermaid
%%{init: {"themeVariables": {"fontSize": "12px"}, "flowchart": {"nodeSpacing": 20, "rankSpacing": 30, "padding": 6}}}%%
flowchart LR
    subgraph promotion["Promotion"]
        prove["Prove policy ⊆<br/>stage boundary"] --> apply["Apply<br/>sandbox"]
    end
    subgraph verification["Verification"]
        evals["Run evals against<br/>the live sandbox"]
    end
    promotion --> verification
```

The [promotion](setup/kargo/20_promotion-task.yaml) runs these steps:

1. **Clone** the Freight's commit of the `support-agent-demo` repo, to get the
   bundle being promoted, and this repo's `main`, to get the stage boundaries.
2. **`openshell-policy-prove`** ([Custom Step](#custom-steps)). A check by an
   SMT (Satisfiability Modulo Theories) solver that `policy.yaml` grants
   nothing beyond `boundaries/<stage>.yaml`. Any result other than
   `within_boundary` fails the promotion here, so the blocked version never
   reaches the sandbox.
3. **`openshell-sandbox-apply`** ([Custom Step](#custom-steps)). Runs the
   bundle on the Freight's image, by digest. Changes to the image, environment
   variables, filesystem rules or process rules recreate the sandbox, because
   OpenShell locks those when a sandbox is created. Network rules and bundle
   files are updated in place.

Once the promotion succeeds, the Stage's
[verification](setup/kargo/30_analysis-template.yaml) runs as a separate
step: a Job that runs `openshell-run-evals` against the live sandbox. These
are real conversations through the real model and the real policy, plus raw
allow and deny probes. Freight that fails verification stays in the stage it
reached but can't be promoted any further.

Rolling back means re-promoting earlier Freight; the same steps run.

### Custom Steps

The usual way to deliver something with Kargo is to write its desired state to
Git and let Argo CD sync it. That doesn't work for OpenShell sandboxes yet:

- **No CRDs.** Sandboxes are created through the gateway API
  (`openshell sandbox create`), which keeps them in its own database and ignores
  any `Sandbox` object it didn't create. So there's nothing for Argo CD to
  sync. Upstream issue
  [#1719](https://github.com/NVIDIA/OpenShell/issues/1719) has just formed a
  working group for an OpenShell operator.
- **No idempotent apply.** The `openshell` CLI has `sandbox create`, `sandbox delete`,
  `policy set` and `sandbox upload`, but no "make this sandbox look like this
  bundle". Which commands a promotion needs depends on what changed, because
  the image and the filesystem and process rules are fixed when a sandbox is
  created.
- **The prover is a CLI.** The policy check is the `openshell-prover` binary.

So the promotion drives the gateway directly, through two
[Kargo Enterprise Custom Steps](setup/kargo/10_custom-steps.yaml). A Custom
Step runs a container in the promotion pod, sharing the working directory with
the built-in steps, so it reads the bundle the `git-clone` step checked out. Both use the
[`openshell-tools`](images/openshell-tools/) image, which holds the OpenShell
CLI, the prover, and the wrapper scripts that mimic the `openshell` CLI:

| Step | Input | What it does | Output |
|---|---|---|---|
| `openshell-policy-prove` | The bundle's policy and the stage's boundary | Runs the prover. Fails the step on anything other than `within_boundary`, and prints the counterexample when there is one | `result`; `exceedsBoundary` with the counterexample; the `policy` and `boundary` checked; `logs` |
| `openshell-sandbox-apply` | Sandbox name, the Freight's image, policy, provider, bundle, the stage's Orders API URL | Reconciles the sandbox: creates it if it's missing; deletes and recreates it if the image, the environment, or the filesystem or process rules changed; otherwise applies the network rules with `policy set --wait` and uploads the bundle, with no restart | `action` (`created`, `recreated` or `updated`) and the `reason`; the startup hash; `logs`, with each `openshell` command and its output |

Both steps return a `logs` output with everything they printed, so the
promotion's details in the Kargo UI show what each step did, even when it
succeeds.

`openshell-sandbox-apply` is a small reconciler standing in for the operator
OpenShell doesn't have yet. In the future, this step could become "write the
sandbox to Git", and Argo CD would sync it like any other resource.

Verification doesn't use a Custom Step: `openshell-run-evals` runs in an
ordinary Job from the [AnalysisTemplate](setup/kargo/30_analysis-template.yaml),
in the same image.

## What's where

`setup/` is grouped by where each part is applied: `setup/argocd/` to the Argo
CD control plane, `setup/kargo/` to the Kargo control plane, and
`setup/cluster/` to the demo cluster, synced by Argo CD.

| Path | What it is | Managed by |
|---|---|---|
| `setup/argocd/` | The `agent-delivery` project, the app-of-apps, and the Applications | Argo CD |
| `setup/kargo/` | Project, Warehouse, Stages, PromotionTask, Custom Steps, verification | Kargo |
| `setup/cluster/agent-sandbox/` | Agent Sandbox CRD and controller (v1.0.3), sync wave -1 | Argo CD |
| `setup/cluster/openshell/` | OpenShell gateway Helm values (chart 0.1.6) | Argo CD |
| `setup/cluster/openshell-setup/` | Provider profile, PostSync Job that registers the Anthropic provider, gateway NetworkPolicy | Argo CD |
| `setup/cluster/orders-api/` | The store's Orders API, which the agent's tools call | Argo CD |
| `boundaries/` | Per-stage maximum policy. Read from `main` at promotion time, never from the Freight | Humans, via review |
| `images/openshell-tools/` | OpenShell CLI and prover, plus the scripts the Kargo steps run | CI |
| `hack/openshell.sh` | Runs an `openshell` CLI command against the gateway, from a one-off pod in the cluster | You |
| `hack/delete-sandboxes.sh` | Deletes the demo's sandboxes from the gateway, for a clean start | You |
| `test/` | Checks that catch manifest mistakes before a promotion would (`make test`, run in CI) | CI |

In the [`support-agent-demo`](https://github.com/akuity/support-agent-demo) repo:

| Path | What it is | Managed by |
|---|---|---|
| `agent/` | **The agent bundle**: `agent.yaml` (model, effort, limits), `system-prompt.md`, `tools.yaml`, `policy.yaml` (OpenShell), `evals.yaml` | Kargo (Freight) |
| `harness/` | Harness image: a manual Claude tool-use loop configured entirely by the bundle | CI, on GitHub release |

Its `main` branch holds one commit per agent version in the walkthrough below.

## Setup

These manifests target an **existing** Argo CD and Kargo Enterprise.

### Requirements

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

### 1. Argo CD

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

### 2. Kargo

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
5. Follow the [walkthrough](#walkthrough).

## Walkthrough

The agent's four versions are commits on the `support-agent-demo` repo's
`main` branch. `setup/kargo/freight/freight.yaml` turns each one into Freight with an
alias, so you can promote versions by name. The commands below use the `kargo`
CLI; the Kargo UI works too.

```sh
kargo login <kargo-api-url> --sso
kargo config set-project acme-support
```

Every promotion is deliberate, including to dev. A stage only accepts Freight
that has passed verification in the stage before it, so wait for verification
to finish (`kargo get stages`) before the next step. `--downstream-from dev`
promotes to both prod stages at once.

In the Kargo UI, the four pieces of Freight line up in version order, and each
Stage shows the version it runs and whether it's verified.

### 1. `v1-initial`: the first release

The agent team ships the first version: Claude Opus 5, tools that can only
look up orders, and a policy that lets the sandbox read the Orders API and
nothing else.

```sh
kargo promote --freight-alias v1-initial --stage dev
kargo promote --freight-alias v1-initial --downstream-from dev
```

What you'll see:
- **Prove:** `result: within_boundary` in every stage.
- **Apply:** there's no sandbox yet, so the step creates one (`Created sandbox:
  support-dev`) and outputs `action=created`.
- **Verification:** `7/7 evals passed`. Three are real conversations, for
  example the agent finding order A-5002's UPS tracking number. Four are raw
  requests from inside the sandbox: reading orders is allowed, and posting a
  refund, reading the refund ledger, or reaching the internet are all denied by
  OpenShell, whatever the model does.

Once dev verifies it, both prod stages accept it. Three sandboxes now run the
same image digest and the same bundle commit.

In the cluster, the gateway has created a `Sandbox` for each stage, named
`<workspace>--<sandbox>`:

```console
$ kubectl -n openshell get sandboxes
NAME                       READY   REASON              AGE
default--support-dev       True    DependenciesReady   2m 
default--support-prod-eu   True    DependenciesReady   2m 
default--support-prod-us   True    DependenciesReady   2m 
```

Each one traces back to Kargo: its image is the Freight's harness image, pinned
by digest, and its `ORDERS_API_URL` is the Stage's `ordersApiURL` variable. An
excerpt:

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: default--support-prod-us
spec:
  operatingMode: Running
  podTemplate:
    spec:
      containers:
      - name: agent
        image: ghcr.io/akuity/support-agent-demo@sha256:8557b252…
        command: [/.openshell/runtime/openshell-sandbox, --bootstrap, …]
        env:
        - name: ORDERS_API_URL
          value: http://orders-api.orders.svc.cluster.local
        # …
```

The agent's container runs OpenShell's sandbox runtime, which then starts the
image's entrypoint, the harness.

Each sandbox runs as a pair of pods: the agent (`workload`) and an OpenShell
supervisor, which injects the API key and enforces the sandbox's policy:

```console
$ kubectl -n openshell get pods -l openshell.ai/boundary-pair -L openshell.ai/boundary-role
NAME                                                 READY   STATUS    RESTARTS   AGE   BOUNDARY-ROLE
default--support-dev                                 1/1     Running   0          2m    workload
default--support-prod-eu                             1/1     Running   0          2m    workload
default--support-prod-us                             1/1     Running   0          2m    workload
os-supervisor-1e922bff-244c-4817-9f59-4c3514a54b53   1/1     Running   0          2m    supervisor
os-supervisor-d165013c-9eb5-4a9e-ab9c-89ed7ffdbf8a   1/1     Running   0          2m    supervisor
os-supervisor-d73c28a0-9218-4627-9b12-bf5790f4f9e7   1/1     Running   0          2m    supervisor
```

The policy itself lives in the gateway, not on the `Sandbox` object;
[Debugging](#debugging-with-hackopenshellsh) shows how to read it.

OpenShell also creates NetworkPolicies, the same for every sandbox, so that an
agent pod can only reach the network through its supervisor. That's why the
cluster's CNI must enforce NetworkPolicy.

### 2. `v2-model-upgrade`: a model upgrade is a release

The team moves to Claude Opus 5.5. It's one line in `agent.yaml`, with no image
build.

```sh
kargo promote --freight-alias v2-model-upgrade --stage dev
kargo promote --freight-alias v2-model-upgrade --downstream-from dev
```

What you'll see:
- **Apply:** `image, environment and startup policy unchanged, updating in
  place`, then `policy set --wait` and `sandbox upload`, and `action=updated`.
  The sandbox isn't restarted: `kubectl -n openshell get pods` shows the same
  pod, with the same age.
- **Inside the sandbox,** the uploaded `agent.yaml` names the new model
  ([`hack/openshell.sh`](#debugging-with-hackopenshellsh) runs `openshell`
  commands from inside the cluster):
  ```console
  $ hack/openshell.sh sandbox exec support-dev -- grep '  id:' /sandbox/agent/agent.yaml
    id: claude-opus-5-5
  ```
  Before the promotion, the same command shows `claude-opus-5`.
- **Verification:** the same evals, now against the new model, pass in dev
  before prod gets it.

A model change goes through the same gates as any other change, and rolling it
back means promoting v1 again.

### 3. `v3-prompt-regression`: evals catch what review misses

Someone "streamlines" the prompt so the agent answers in a single reply. It
reads as harmless, but it drops the rules section, and with it the promise that
a specialist follows up on damaged items: customers are sent to a self-service
returns page instead.

```sh
kargo promote --freight-alias v3-prompt-regression --stage dev
kargo promote --freight-alias v3-prompt-regression --stage prod-us   # refused: not verified in dev
```

What you'll see:
- **Prove and apply** pass: the policy didn't change, and dev is updated in
  place.
- **Verification fails.** The Kargo UI shows the eval log in dev's
  verification:

  ![The evals log in Kargo: refund-handoff fails because the reply doesn't mention a specialist, follow-up or email; 6/7 evals passed](docs/images/failed-eval.png)

  The reply sends the customer to the returns page: "I can't issue refunds
  myself, but you can request one right away at https://acme.example/returns."
- **Prod refuses it.** Dev now runs v3, but it isn't verified, so neither prod
  stage will take it. Both keep running v2.

Nothing in Kubernetes changed and no image was built. Only the prompt did, and
only evals against the live agent caught it. (`no-cross-customer-leak` still
passes: even without the ownership rule, Claude declines to share another
customer's order.)

### 4. `v4-refunds`: one release, two answers

The business wants the agent to refund damaged deliveries. Version 4 adds an
`issue_refund` tool, restores the rules with conditions on when to refund, and
asks for a new policy rule, `orders_api_refunds`, allowing
`POST /orders/*/refunds`. What each stage allows is the platform team's call:
prod-us allows refunds, and prod-eu hasn't been approved for them.

```sh
kargo promote --freight-alias v4-refunds --stage dev
kargo promote --freight-alias v4-refunds --downstream-from dev
kargo get promotions        # prod-us succeeded, prod-eu failed
```

What you'll see:
- **dev and prod-us:** the prover accepts the policy, and the new network rule
  loads live, with no restart. New evals check that the agent refunds a
  delivered, damaged order and won't refund one that hasn't been delivered.
- **prod-eu fails at the prove step.** The promotion's details in the Kargo UI
  show the prover's result and counterexample, and the apply step skipped:

  ![A prod-eu promotion in Kargo: openshell-policy-prove fails with exceeds_boundary for POST orders-api.orders.svc.cluster.local:80/orders/a/refunds, and the apply step is skipped](docs/images/exceeds-boundary.png)

  The counterexample is a concrete request this version could make that the
  boundary forbids. The promotion stops before the apply step, so prod-eu's
  sandbox is untouched and keeps running v2.
- **Inside the sandboxes,** the difference is in the tools each agent has.
  prod-us runs v4's bundle, and prod-eu never received it:
  ```console
  $ hack/openshell.sh sandbox exec support-prod-us -- grep '  - name:' /sandbox/agent/tools.yaml
    - name: get_customer_orders
    - name: get_order
    - name: issue_refund
  $ hack/openshell.sh sandbox exec support-prod-eu -- grep '  - name:' /sandbox/agent/tools.yaml
    - name: get_customer_orders
    - name: get_order
  ```

The same Freight gets a different answer in each stage, and the agent team
can't widen its own permissions: the boundaries live in this repo.

### 5. Roll back prod-us

Say refunds misbehave in prod-us. Rolling back is a promotion of the previous
version:

```sh
kargo promote --freight-alias v2-model-upgrade --stage prod-us
```

What you'll see: an in-place update. `policy set --wait` unloads the refund
rule, the old prompt and tools are uploaded, and the evals run again, so the
`refunds-denied` probe confirms OpenShell blocks refund requests once more. The
sandbox isn't restarted.

Allowing refunds in prod-eu would be a reviewed pull request to this repo,
adding the `orders_api_refunds` entry from `boundaries/prod-us.yaml` to
`boundaries/prod-eu.yaml`. No new Freight is needed: re-promote version 4 and
it passes.

### Where to look

- `kargo` promotion details, which show the prove step's output.
- `kubectl -n orders logs deploy/orders-api`, which shows the requests the
  agent made. A request OpenShell blocked never appears here.
- The supervisors' logs, which show each request OpenShell blocked and the
  rule that blocked it, as OCSF security events:
  ```console
  $ kubectl -n openshell logs -l openshell.ai/boundary-role=supervisor --prefix | grep DENIED
  … OCSF HTTP:POST [MED] DENIED POST http://orders-api.orders.svc.cluster.local/orders/A-5001/refunds [policy:orders_api engine:l7] …
  … OCSF NET:REFUSE [MED] DENIED example.com [reason:policy_dns_ineligible]
  ```
  These are the evals' deny probes. The refund `POST` never reaches the Orders
  API log.

The evals call a real model, so results can vary between runs.

## Debugging with `hack/openshell.sh`

Most of what happens to a sandbox happens in the OpenShell gateway, not in
Kubernetes: the `Sandbox` objects show the image and environment, but not the
policy, the uploaded bundle, or why a request was denied. The `openshell` CLI
shows all of that, but the gateway is only reachable inside the cluster and
requires a client certificate.

[`hack/openshell.sh`](hack/openshell.sh) runs any `openshell` command for you,
in a one-off pod in the `openshell` namespace with the chart's
`openshell-client-tls` Secret mounted, so the key never leaves the cluster. It
uses the `openshell-tools` image the Custom Steps pin. Run from a terminal, it's
interactive. It needs `kubectl`, `jq` and `yq`, and takes `--context
<kube-context>` as its first argument.

**Sandboxes:**

```sh
hack/openshell.sh sandbox list
hack/openshell.sh sandbox get support-prod-us     # status and labels, including startup-hash
hack/openshell.sh logs support-dev --since 30m    # the gateway's and the sandbox's logs
```

**A shell in a sandbox,** as the sandbox user and under its policy, so you see
what the agent sees:

```sh
hack/openshell.sh sandbox connect support-dev
```

From there:

```sh
ls /sandbox/agent                                  # the bundle the promotion uploaded
echo "$ORDERS_API_URL"                             # the Stage's Orders API
python3 /app/agent.py chat --customer C-1001 "Where is my order A-5002?"
python3 /app/agent.py probe POST \
  http://orders-api.orders.svc.cluster.local/orders/A-5001/refunds \
  --body '{"amount": 1, "reason": "test"}'          # denied unless the policy allows refunds
```

`chat` is a real conversation with the agent. `probe` makes one request
directly, with no model involved, the way the evals' probes do. The image has no
`curl`, and the policy only allows the agent's Python interpreter to reach the
network anyway.

**One command, no shell:**

```sh
hack/openshell.sh sandbox exec support-prod-us -- \
  python3 /app/agent.py chat --customer C-1002 "My stove arrived with a broken fuel valve. I want a refund."
```

Between walkthrough steps 4 and 5, run the same message against
`support-prod-eu` too: prod-us (v4) issues the refund, and prod-eu (still on
v2) hands the customer off to a specialist.

**Policy:**

```sh
hack/openshell.sh policy get support-prod-eu --base   # the policy the promotion applied
hack/openshell.sh policy get support-prod-eu --full   # plus the Anthropic provider's rules
hack/openshell.sh policy list support-prod-us         # one version per policy change
```

The supervisor's log shows each request the policy denied:
`kubectl -n openshell logs -l openshell.ai/boundary-role=supervisor --prefix | grep DENIED`.

Local files aren't available to the pod, so commands that read one, such as
`policy set --policy <file>`, don't work through the script.

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

## Demo-only shortcuts

- **The gateway accepts unauthenticated callers.**
  `server.auth.allowUnauthenticatedUsers` is on, and a NetworkPolicy limits
  which namespaces can reach the gateway. In production, use OIDC.
- **One cluster and one gateway serve all three stages.** In production, each
  stage would be its own gateway, cluster, or workspace.
- **The Orders API is an in-memory mock.** It resets on restart.

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
