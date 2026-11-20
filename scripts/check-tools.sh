#!/usr/bin/env bash
# Phase 0 "done when": prints every lab tool with its version; exits 0 only if all
# are present and Docker answers. Run inside WSL Ubuntu: bash scripts/check-tools.sh
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"   # pipx tools, even before a new login shell

missing=0
check() {   # check NAME COMMAND...
  local name=$1; shift
  local raw out=""
  # Capture, then extract: `cmd | grep -m1` would SIGPIPE cmd and pipefail would call it missing.
  raw=$("$@" 2>&1) && [[ $raw =~ v?[0-9]+\.[0-9]+(\.[0-9]+)? ]] && out=${BASH_REMATCH[0]}
  if [[ -n $out ]]; then
    printf '  \033[32m✔\033[0m %-11s %s\n' "$name" "$out"
  else
    printf '  \033[31m✘\033[0m %-11s missing\n' "$name"
    missing=$((missing + 1))
  fi
}

echo "Lab toolbox ($(. /etc/os-release && echo "$PRETTY_NAME"), $(nproc) CPUs, $(free -g | awk '/Mem:/{print $2}') GB RAM)"
check git        git --version
check docker     docker version --format '{{.Server.Version}}'
check kubectl    kubectl version --client
check helm       helm version --short
check k3d        k3d version
check terraform  terraform version
check ansible    ansible --version
check trivy      trivy --version
check hadolint   hadolint --version
check gitleaks   gitleaks version
check pre-commit pre-commit --version
check argocd     argocd version --client --short
check jq         jq --version
check yq         yq --version

if (( missing )); then
  echo "$missing tool(s) missing: run scripts/install-tools.sh"
  exit 1
fi
echo "All tools present."
