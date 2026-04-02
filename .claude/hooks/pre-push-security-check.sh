#!/bin/bash
# Pre-push security check for Claude Code
# Scans files in commits about to be pushed for cleartext secrets
# and Kubernetes/YAML security misconfigurations.
#
# Input:  stdin JSON {"tool_name":"Bash","tool_input":{"command":"..."}}
# Output: JSON {"continue":false,"stopReason":"..."} on findings, else silent exit 0

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('command', ''))
" 2>/dev/null || echo "")

# Only act on git push
if ! echo "$CMD" | grep -qE '^git push'; then
  exit 0
fi

# Move to repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO_ROOT"

# Determine files being pushed (new commits not yet on remote)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
REMOTE_REF="origin/${BRANCH}"

if git rev-parse --verify "${REMOTE_REF}" >/dev/null 2>&1; then
  FILES=$(git diff --name-only "${REMOTE_REF}..HEAD" 2>/dev/null || true)
else
  BASE=$(git merge-base HEAD origin/main 2>/dev/null \
    || git merge-base HEAD origin/master 2>/dev/null \
    || git rev-parse HEAD~1 2>/dev/null \
    || true)
  FILES=$([ -n "$BASE" ] && git diff --name-only "${BASE}..HEAD" 2>/dev/null || true)
fi

[ -z "$FILES" ] && exit 0

ISSUES=""

add_issue() {
  ISSUES="${ISSUES}\n  $1"
}

while IFS= read -r file; do
  [ -f "$file" ] || continue

  # ── Private keys ──────────────────────────────────────────────────────────
  if grep -qE "BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY" "$file" 2>/dev/null; then
    add_issue "[PRIVATE KEY] ${file}"
  fi

  # ── YAML / env / config files ─────────────────────────────────────────────
  if echo "$file" | grep -qiE '\.(yaml|yml|env|conf|config|toml|ini)$'; then

    # Skip SOPS-encrypted files (they contain a top-level `sops:` key)
    if grep -qE '^sops:' "$file" 2>/dev/null; then
      continue
    fi

    # Secret key/value patterns — skip SOPS ENC[] values, placeholders, env var refs
    MATCHES=$(grep -nP \
      '(?i)(password|passwd|token|secret|api[_-]?key|auth[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)\s*[:=]\s*["'"'"']?[A-Za-z0-9+/=$%@!_\-]{12,}["'"'"']?' \
      "$file" 2>/dev/null \
      | grep -vE 'ENC\[|^\s*#|\$\{|\$\(|<[^>]+>|\*{4,}|changeme|example|placeholder|your[_\-]' \
      || true)
    if [ -n "$MATCHES" ]; then
      add_issue "[POSSIBLE SECRET] ${file}"
      # Show line numbers but truncate long values for readability
      while IFS= read -r match; do
        add_issue "    $(echo "$match" | cut -c1-120)"
      done <<< "$MATCHES"
    fi

    # Kubernetes secrets with base64 data (not SOPS-encrypted)
    if grep -qE '^kind:\s*Secret' "$file" 2>/dev/null; then
      if grep -qE '^\s+(data|stringData):' "$file" 2>/dev/null \
        && ! grep -qE 'ENC\[' "$file" 2>/dev/null; then
        add_issue "[K8S SECRET NOT ENCRYPTED] ${file} — use SOPS to encrypt"
      fi
    fi

    # Kubernetes containers running as root (uid 0 or no securityContext)
    if grep -qE '^kind:\s*(Deployment|DaemonSet|StatefulSet|Pod)' "$file" 2>/dev/null; then
      if grep -qE 'runAsUser:\s*0' "$file" 2>/dev/null; then
        add_issue "[SECURITY] ${file} — container running as root (runAsUser: 0)"
      fi
      if grep -qE 'privileged:\s*true' "$file" 2>/dev/null; then
        add_issue "[SECURITY] ${file} — privileged container"
      fi
      if grep -qE 'allowPrivilegeEscalation:\s*true' "$file" 2>/dev/null; then
        add_issue "[SECURITY] ${file} — allowPrivilegeEscalation: true"
      fi
      if grep -qE 'hostNetwork:\s*true' "$file" 2>/dev/null; then
        add_issue "[SECURITY] ${file} — hostNetwork: true"
      fi
      if grep -qE 'hostPID:\s*true' "$file" 2>/dev/null; then
        add_issue "[SECURITY] ${file} — hostPID: true"
      fi
    fi
  fi

  # ── Kubeconfig files ──────────────────────────────────────────────────────
  if echo "$file" | grep -qiE '(kubeconfig|kube/config)'; then
    if grep -qE 'client-certificate-data:|client-key-data:|token:' "$file" 2>/dev/null; then
      add_issue "[KUBECONFIG WITH EMBEDDED CREDENTIALS] ${file}"
    fi
  fi

  # ── Generic high-entropy strings (any file) ───────────────────────────────
  # Catch common secret patterns regardless of file type
  if grep -qP '(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}' "$file" 2>/dev/null; then
    add_issue "[GITHUB TOKEN] ${file}"
  fi
  if grep -qP 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null; then
    add_issue "[AWS ACCESS KEY] ${file}"
  fi
  if grep -qP 'xox[baprs]-[0-9A-Za-z\-]+' "$file" 2>/dev/null; then
    add_issue "[SLACK TOKEN] ${file}"
  fi

done <<< "$FILES"

if [ -n "$ISSUES" ]; then
  python3 -c "
import json, sys
issues = sys.argv[1]
msg = ('Security check BLOCKED push — findings in commits about to be pushed:\n'
       + issues
       + '\n\nFix before pushing:'
       + '\n  - Encrypt secrets with SOPS: sops -e -i <file>'
       + '\n  - Remove private keys; regenerate and use sealed secrets or SOPS'
       + '\n  - Fix security misconfigurations in pod specs')
print(json.dumps({'continue': False, 'stopReason': msg}))
" "$ISSUES"
fi
