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

## Security & Configuration Tips
- SOPS keys: set `SOPS_AGE_KEY_FILE` locally; keep private key in Bitwarden and offline backup.
- Pin chart versions in Argo CD Applications and values. Avoid ad-hoc `helm upgrade` on the cluster.

