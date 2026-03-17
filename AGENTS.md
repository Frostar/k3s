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

## Networking — MetalLB IP Pools

This cluster uses MetalLB for bare-metal LoadBalancer IPs. Two pools are defined:

| Pool | Range | Assignment |
|---|---|---|
| `traefik-pool` | `192.168.10.120/32` | Manual only — reserved for Traefik |
| `default-pool` | `192.168.10.121–192.168.10.150` | Auto-assigned to LoadBalancer services |

When creating a LoadBalancer service, do not hard-code an IP unless necessary. If a specific IP is required, annotate with `metallb.universe.tf/loadBalancerIPs` and pick from the default pool range.

## Security & Configuration Tips
- SOPS keys: set `SOPS_AGE_KEY_FILE` locally; keep private key in Bitwarden and offline backup.
- Do not use `helm upgrade` ad-hoc on the cluster. If a Helm chart must be used, pin the chart version in the ArgoCD Application and keep values in `helm-values/`.

## Bootstrap Instructions

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

