# Copilot Review Instructions

This repository manages a personal k3s homelab cluster using GitOps (ArgoCD). All changes are applied to the cluster via ArgoCD syncing from this repo.

## Review Focus

### Security
- Flag any plaintext secrets, tokens, passwords, or API keys — all secrets must be SOPS-encrypted (`.enc.yaml`) in `secrets/`.
- Check that new ingresses use TLS (`cert-manager.io/cluster-issuer` annotation) and the `security-headers` Traefik middleware.
- Flag containers running as root (`runAsUser: 0`) without explicit justification.
- Flag containers with `privileged: true` or `allowPrivilegeEscalation: true` unless required.
- Flag images using `latest` tag — prefer pinned versions for reproducibility.

### Stability
- Check that all Deployments and StatefulSets define `resources.requests` and `resources.limits`.
- Check that liveness and readiness probes are defined with appropriate `initialDelaySeconds` (especially for heavy JVM/Elasticsearch workloads on ARM).
- Flag PVC storage reductions — Kubernetes does not allow shrinking PVCs.
- Flag StatefulSet volume mount path changes that could cause data loss on restart.
- Check that CronJobs have `concurrencyPolicy: Forbid` to prevent overlapping runs.

### Summary
Start every review with a short summary (2-3 sentences) of what the PR changes, which namespaces are affected, and whether any workloads will be restarted.
