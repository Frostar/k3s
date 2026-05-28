# Repository Guidelines

This repo manages a personal k3s cluster with GitOps. Keep everything reproducible and declarative: Helm chart values, raw Kubernetes YAML, and Argo CD Applications live here. Secrets are committed encrypted with SOPS.

## Project Structure & Module Organization
- argocd/ – Argo CD Projects and Applications (app-of-apps).
- namespaces/ – One Namespace manifest per non-system namespace.
- core/ – Cluster-wide infra (Traefik, cert-manager, MetalLB, monitoring).
- apps/ – App-specific manifests not covered by Helm.
- helm-values/<namespace>/<release>.values.yaml – Pinned values per Helm release.
- secrets/ – SOPS-encrypted secrets only.

## Build, Test, and Development Commands
- kubectl: `k3s kubectl get/apply -f <file>` for local validation.
- helm (export): `helm -n <ns> get values <release> -o yaml > helm-values/<ns>/<release>.values.yaml`.
- sops (decrypt for apply): `sops -d secrets/<path>.enc.yaml | kubectl apply -f -`.

## Coding Style & Naming Conventions
- YAML: 2-space indent, kebab-case filenames, one resource per file when practical.
- Directories mirror namespaces/apps; keep values files named `<release>.values.yaml`.
- No plaintext secrets. Use SOPS; encrypt fields under `data/stringData` or matching `(password|token|secret)`.

## Security

**This repository is public.** Anyone on the internet can read every file in git history. Never commit plaintext secrets, tokens, passwords, or private keys — not even temporarily. All secrets must be SOPS-encrypted before they touch the repo. ArgoCD pulls from this repo without credentials precisely because it is public; if it is ever made private, ArgoCD deploy keys will need to be configured.

A Claude Code pre-push hook (`.claude/hooks/pre-push-security-check.sh`) runs automatically before every `git push`. It will **block the push** if it finds:

- Cleartext private keys or credentials
- Kubernetes `Secret` manifests with unencrypted `data`/`stringData` (must be SOPS-encrypted)
- Common token patterns (GitHub, AWS, Slack)
- Kubernetes pod specs with `privileged: true`, `runAsUser: 0`, `hostNetwork: true`, etc.

To bypass in an emergency: `SKIP_SECURITY_CHECK=1 git push` is **not supported** — fix the issue instead.

Recommended tools to add for stronger scanning (not yet installed):
- **gitleaks** — entropy-based secret scanning across full git history
- **trivy** — Kubernetes manifest misconfiguration scanning (NSA/CIS benchmarks)
- **kubescape** — NSA/MITRE ATT&CK framework checks for k8s manifests

## Testing Guidelines
- Dry-run: `kubectl apply --server-dry-run=client -f <file>`.
- Lint values (optional): `helm template --values <file> <chart> --namespace <ns>`.
- Prefer sandbox namespaces when trying changes.

## Commit & Pull Request Guidelines
- Commits: present tense, scoped prefixes (e.g., `core/cert-manager: add cluster-issuer`).
- PRs: include purpose, affected namespaces/apps, and commands used to validate (template/dry-run). Link related issues if any.

## Manifest Style — Raw YAML Over Helm

**Prefer raw Kubernetes manifests over Helm charts.** All applications should be expressed as plain YAML in `apps/<name>/`. Helm is only used where a chart is the only practical deployment method (e.g. longhorn, kube-prometheus-stack). When in doubt, use raw manifests.

- Do NOT introduce new Helm releases without a clear reason.
- If converting a Helm-managed app to raw manifests, export the rendered templates and commit them to `apps/<name>/`.
- Helm values files in `helm-values/` are only for existing Helm-managed components.

**Gotcha — `helm-values/<app>/` files only matter if something reads them.** A `values.yaml` here is inert unless the corresponding Argo CD Application is a Helm source (`source.helm.valueFiles` or `source.chart`) that explicitly references it. If the Argo Application uses a `Directory` source pointing at `apps/<name>/`, the `helm-values/<name>/` file is **not** wired up — Renovate may still bump tags in it, but nothing on the cluster changes. Before editing or trusting a `helm-values/` file, check `argocd/apps/<name>.yaml` to confirm it is actually a Helm source.

**Gotcha — switching an Argo Application's source type can prune resources via shared labels.** Argo CD's default resource-tracking method is the `app.kubernetes.io/instance` label. When an App's source changes (e.g. Directory → Helm chart) but its name stays the same, any cluster-scoped resources it previously claimed via that label become candidates for **prune** if the new render does not include them and `syncPolicy.automated.prune` is on. This bit us during the cert-manager/metallb migration on 2026-05-27: switching `metallb` to a chart source deleted the user-supplied `IPAddressPool` and `L2Advertisement` resources (they carried `instance=metallb` from the previous Directory source App) because the chart does not render them. All LoadBalancer services lost their IPs for ~5 minutes.

When switching an App's source type:

1. **Disable `syncPolicy.automated`** on the App first (`kubectl -n argocd patch application <name> --type=merge -p '{"spec":{"syncPolicy":null}}'`). This prevents auto-prune the moment the new spec is applied.
2. **Inventory cluster-scoped or user-supplied resources** the App previously owned. Anything not rendered by the new source needs a new home — either a separate Argo App (e.g. `metallb-config` for the IPAddressPools), or moved into the chart values via `extraObjects` / `extraDeploy`.
3. **Strip the `app.kubernetes.io/instance` label** from those orphaned resources, or move them under their new App, *before* syncing the renamed source.
4. **Sync manually and review the diff** in the Argo UI. Adoption is fine; deletion of anything you didn't expect is the warning sign.

Note that `syncPolicy: {}` in git is interpreted by strategic-merge-patch as "leave the existing field alone", so it will **not** reset a live `automated:` syncPolicy. You must patch live explicitly.

## Networking — MetalLB IP Pools

This cluster uses MetalLB for bare-metal LoadBalancer IPs. Two pools are defined:

| Pool | Range | Assignment |
|---|---|---|
| `traefik-pool` | `192.168.10.120/32` | Manual only — reserved for Traefik |
| `default-pool` | `192.168.10.121–192.168.10.150` | Auto-assigned to LoadBalancer services |

When creating a LoadBalancer service, do not hard-code an IP unless necessary. If a specific IP is required, annotate with `metallb.universe.tf/loadBalancerIPs` and pick from the default pool range.

Reserved IPs (do not reuse):

| IP | Service |
|---|---|
| `192.168.10.120` | Traefik |
| `192.168.10.130` | ArgoCD |
| `192.168.10.131` | AdGuard Home (DNS — do not change) |

## Security & Configuration Tips
- SOPS keys: set `SOPS_AGE_KEY_FILE` locally; keep private key in Bitwarden and offline backup.
- Do not use `helm upgrade` ad-hoc on the cluster. If a Helm chart must be used, pin the chart version in the ArgoCD Application and keep values in `helm-values/`.

## Bootstrap Instructions

The four nodes run on a **Turing Pi 2** mini-ITX board (slots 1–4 = kube01–kube04). The board has a BMC for out-of-band power control and flashing. See the official docs for physical layout, BMC access, and OS flashing: https://docs.turingpi.com/docs/turing-pi2-intro

### Phase 0 — Install k3s on fresh nodes

**Mount the SSDs (kube01, kube02, kube03 only)**

Do this before installing k3s. Longhorn's default disk path is `/storage1`; if the mount isn't present when Longhorn first starts it will see no disk and skip the node.

If the SSDs were **preserved** (OS reinstall, disks not wiped) just re-add the fstab entries and mount — Longhorn will recognise the existing replica data:

```bash
# kube01, kube02
echo '/dev/sda /storage1 ext4 defaults 0 0' | sudo tee -a /etc/fstab
sudo mkdir -p /storage1 && sudo mount -a

# kube03 only — has a second SSD (unused by Longhorn, but keep it mounted)
echo '/dev/sda /storage1 ext4 defaults 0 0' | sudo tee -a /etc/fstab
echo '/dev/sdb /storage2 ext4 defaults 0 0' | sudo tee -a /etc/fstab
sudo mkdir -p /storage1 /storage2 && sudo mount -a
```

If the SSDs were **wiped**, format first:

```bash
sudo mkfs.ext4 /dev/sda   # repeat for /dev/sdb on kube03
```

Then add the fstab entries and mount as above. Longhorn will create fresh empty volumes — all PVC data is lost. Recovery: restore AdGuard config manually (DNS rewrites are in `CLAUDE.md`), and restore PostgreSQL databases from the dump-job backups on MinIO (`espeon:9000`).

**kube01 (control plane)**

Create `/etc/rancher/k3s/config.yaml` before running the installer — without it k3s bundles its own Traefik and ServiceLB, which conflict with the cluster's:

```yaml
# /etc/rancher/k3s/config.yaml on kube01
disable:
  - servicelb
  - traefik
```

Then install (pin the version to match the rest of the cluster — check `kubectl get nodes` or `AGENTS.md` for the current version):

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.1+k3s1 sh -
```

Copy the kubeconfig to your workstation and fix it up:

```bash
scp kube01:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
# Replace the loopback address with kube01's IP, and rename the context
# so it matches the name used throughout this repo (k3s-context)
sed -i \
  -e 's|https://127.0.0.1:6443|https://192.168.10.211:6443|' \
  -e 's/name: default/name: k3s-context/g' \
  -e 's/cluster: default/cluster: k3s-context/g' \
  -e 's/user: default/user: k3s-context/g' \
  -e 's/current-context: default/current-context: k3s-context/' \
  ~/.kube/k3s.yaml
```

**kube02, kube03, kube04 (workers)**

Grab the cluster token from kube01, then install the agent on each worker:

```bash
TOKEN=$(ssh kube01 sudo cat /var/lib/rancher/k3s/server/token)

for node in kube02 kube03 kube04; do
  ssh $node "curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION=v1.36.1+k3s1 \
    K3S_URL=https://192.168.10.211:6443 \
    K3S_TOKEN=$TOKEN sh -"
done
```

**Apply node labels**

Longhorn uses a label to decide which nodes get a default disk. kube01–03 each have an SSD at `/storage1`; kube04 does not and must not host replicas:

```bash
kubectl label node kube01 kube02 kube03 node.longhorn.io/create-default-disk=config
# kube04 intentionally omitted
```

After Longhorn is running (ArgoCD will deploy it in Phase 2), re-apply the kube04 Longhorn Node CRD patch to prevent replica scheduling there:

```bash
kubectl --context k3s-context -n longhorn-system patch nodes.longhorn.io kube04 \
  --type=merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true,"disks":{"default-disk-d6c2e7766f5bd2d5":{"allowScheduling":false,"evictionRequested":true,"diskDriver":"","diskType":"filesystem","path":"/storage1","storageReserved":9186888499,"tags":[]}}}}'
```

### Phase 1 — Install ArgoCD

Install ArgoCD (match the version currently pinned in the cluster — `v3.2.3` as of this writing):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.3/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd
```

### Phase 2 — Bootstrap GitOps

Run these once to bring up ArgoCD GitOps from scratch:

```bash
# 1. Store the age private key in the cluster
kubectl create secret generic argocd-age-key -n argocd \
  --from-literal=keys.txt="$(cat ~/.config/sops/age/keys.txt)"

# 2. Apply the SOPS CMP plugin (patches argocd-repo-server)
kubectl apply -f core/argocd/cmp-sops.yaml

# 3. Wait for repo-server to restart with the sidecar
kubectl rollout status deployment/argocd-repo-server -n argocd

# 4. Bootstrap the app-of-apps
kubectl apply -f argocd/projects/homelab.yaml
kubectl apply -f argocd/apps/root-app.yaml
```

After step 4, ArgoCD will sync all Applications (apps, core, secrets) from this repo.

## Cluster Upgrades — system-upgrade-controller

k3s itself is upgraded declaratively via Rancher's `system-upgrade-controller`. Two `Plan` CRs live in `core/system-upgrade-controller/`:

- `server-plan.yaml` — matches nodes with the `node-role.kubernetes.io/control-plane` label
- `agent-plan.yaml` — matches workers; `prepare` references `k3s-server` so workers wait for the control plane

Both Plans additionally require `k3s-upgrade=true` on the node. Without that label, the Plans match zero nodes and the controller does nothing. This is the opt-in gate — Plans can stay committed on `main` without any risk of firing.

### Running an upgrade

1. Pick a target version. Pin to an exact tag (never a channel — channels auto-bump). For patch bumps within the running minor, take the latest of that minor; for minor bumps, do one at a time and verify Longhorn / cert-manager / Authentik compatibility first.

2. Update `spec.version` in **both** `server-plan.yaml` and `agent-plan.yaml`. Commit and push. Wait for Argo CD to sync (`kubectl --context k3s-context get application system-upgrade-controller -n argocd`).

3. Trigger the control plane first:

   ```bash
   kubectl --context k3s-context label node kube01 k3s-upgrade=true
   kubectl --context k3s-context -n system-upgrade get jobs -w
   ```

   The control-plane upgrade cordons, drains, runs the `rancher/k3s-upgrade` image, restarts k3s, and uncordons. Expect 3–5 min. The cluster API will be briefly unreachable while k3s restarts on kube01 (it is the only control-plane node).

4. Verify before continuing:

   ```bash
   kubectl --context k3s-context get nodes   # kube01 must show target version
   ```

5. Trigger the workers. `concurrency: 1` on the Plan serializes them even if all are labeled together:

   ```bash
   kubectl --context k3s-context label node kube02 kube03 kube04 k3s-upgrade=true
   ```

6. Once all nodes are on the new version, remove the labels so the Plans are dormant again:

   ```bash
   kubectl --context k3s-context label node kube01 kube02 kube03 kube04 k3s-upgrade-
   ```

### Pre-flight check on worker nodes

Each worker should have **exactly one** k3s systemd unit active: `k3s-agent.service`. kube02 and kube03 historically had a stale `k3s.service` (server) left over from their original install, stuck in `activating/start` with a `k3s server` process running alongside `k3s agent`. The upgrade controller's safety script aborts with `Found multiple K3s pids` when this happens.

To check from this machine:

```bash
for n in kube02 kube03 kube04; do
  echo "=== $n ==="
  ssh $n "sudo systemctl list-units --all 'k3s*' --no-pager | grep -E 'k3s.*service'"
done
```

To clean up if a stale `k3s.service` exists on a worker:

```bash
ssh <node> "sudo systemctl disable --now k3s.service"
```

Only kube01 should run `k3s.service` (server). All workers should run only `k3s-agent.service`.

### Known interactions during a node upgrade

- **Longhorn replicas** on the draining node detach and reattach elsewhere. With 3 replicas (current default) there is no data loss; expect a brief I/O blip on volumes whose primary replica was on that node.
- **kube04 hosts pinned StatefulSets** (`prometheus-0`, `grafana`, `wikijs/postgresql-0`). They will restart when kube04 upgrades. Plan upgrades during a maintenance window if any of these are user-visible at the time.
- **Argo CD itself runs on kube01**. The CLI will pause briefly during the kube01 upgrade window; in-flight syncs resume afterwards.
- **system-upgrade-controller runs on the control-plane**, so it gets restarted during the kube01 upgrade. Rancher's design handles this — the Plan continues from where it left off after the controller restarts.

### Adding a fifth node (or replacing a node)

Label the new node with `node.longhorn.io/create-default-disk=config` if it should host Longhorn replicas (kube01-03 have this; kube04 does not). Without it, the `createDefaultDiskLabeledNodes: true` setting in `helm-values/longhorn-system/longhorn.values.yaml` will keep Longhorn from creating a default disk on the new node.

## GitOps Source-of-Truth Rule

**Every cluster configuration must be reflected as a file in this repository. The repo is the single source of truth — not the cluster.**

This means:
- Never apply raw YAML directly to the cluster without committing it here first.
- Never run `helm upgrade` manually; all Helm values live in `helm-values/` and are applied via Argo CD.
- Never create secrets with `kubectl create secret`; all secrets must be SOPS-encrypted and committed to `secrets/`.
- Never configure cluster resources (namespaces, ingresses, CRDs, RBAC, etc.) imperatively; declare them in the appropriate directory.
- If a resource currently exists on the cluster but has no corresponding file here, it must be exported and committed before it is considered managed.

When asked to make a cluster change, always:
1. Write or update the relevant file(s) in this repo.
2. Commit the change.
3. Let Argo CD sync it to the cluster (or apply manually only for bootstrapping, then verify Argo CD takes ownership).

If you find configuration on the cluster that is not represented in this repo, treat it as drift and reconcile it by adding the missing files.

