#!/usr/bin/env bash
# Installs the lab toolbox on Ubuntu 24.04 (WSL2). Safe to re-run: a tool already at
# the pinned version is skipped. Every downloaded binary is checked against the
# project's published SHA-256 before it is installed.
#
#   bash scripts/install-tools.sh        (asks for your sudo password once)
#
# To upgrade a tool: change its version below, re-run, then re-run check-tools.sh.
# -E: functions inherit the ERR trap below (without it, a failure inside a
# function exits the script silently).
set -Eeuo pipefail

# ---- Pinned versions (checked 2026-11-20) -----------------------------------
KUBECTL=v1.37.2
HELM=v4.3.2
K3D=v5.9.0
YQ=v4.54.3
HADOLINT=v2.15.1
GITLEAKS=v8.30.1
ARGOCD=v3.6.2
TRIVY=v0.76.2
TERRAFORM=1.17.2      # via HashiCorp's apt repo

# ~/.local/bin, not /usr/local/bin: Docker Desktop owns /usr/local/bin/kubectl (a
# symlink it re-creates on every restart). ~/.local/bin comes first in PATH
# (Ubuntu's ~/.profile), so our pinned kubectl wins, and no sudo is needed.
BIN=$HOME/.local/bin
mkdir -p "$BIN"
export PATH="$BIN:$PATH"   # so the version checks below see what we install
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# set -e exits silently; say where. (A silent exit is how the SIGPIPE bug below was found.)
trap 'echo "FAILED (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# have CMD...: CMD exists and its output contains the pinned $WANT version.
# Capture first, then search. NOT `"$@" | grep -q`: grep -q quits at the first
# match, the command dies of SIGPIPE (exit 141), and pipefail reports failure.
have() {
  local out
  command -v "$1" >/dev/null 2>&1 && out=$("$@" 2>/dev/null) && [[ $out == *"${WANT#v}"* ]]
}

# fetch URL [FILE]: download with retries; fail on HTTP errors.
fetch() { curl -fsSL --retry 3 -o "${2:-$(basename "$1")}" "$1"; }

# verify FILE SUMS: check FILE against its line in a "<sha256>  <name>" list.
# Projects differ: "*name" (binary mode, hadolint), "_dist/name" (path, k3d).
# So pick the hash by bare file name, then feed sha256sum one clean line.
verify() {
  local hash
  hash=$(awk -v f="$1" '{ n = $2; sub(/^\*/, "", n); sub(/.*\//, "", n) } n == f { print $1 }' "$2")
  [[ -n $hash ]] || { echo "no checksum for $1 in $2" >&2; return 1; }
  echo "$hash  $1" | sha256sum -c -
}

# ---- 1. Base packages from Ubuntu -------------------------------------------
log "apt: base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl ca-certificates gnupg unzip jq pipx >/dev/null

# ---- 2. Terraform: vendor apt repo (the signed-repo pattern) ----------------
# The key goes in its own keyring and `signed-by` limits it to this one repo,
# so HashiCorp's key can't vouch for packages from any other source.
WANT=$TERRAFORM
if ! have terraform version; then
  log "terraform $TERRAFORM (HashiCorp apt repo)"
  fetch https://apt.releases.hashicorp.com/gpg hashicorp.gpg
  sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp.gpg hashicorp.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  # apt versions carry a package revision (1.17.2-1): look up the exact string.
  # awk keeps reading after the match (no `exit`): an early exit would SIGPIPE
  # apt-cache, and pipefail + set -e would end the script with no message.
  pkgver=$(apt-cache madison terraform | awk -v v="$TERRAFORM" '!found && $3 ~ "^"v"-" {print $3; found=1}')
  [[ -n $pkgver ]] || { echo "terraform $TERRAFORM not in the apt repo"; exit 1; }
  sudo apt-get install -y -qq "terraform=$pkgver" >/dev/null
fi

# ---- 3. Single-binary tools: download + checksum + install ------------------
WANT=$KUBECTL
if ! have kubectl version --client; then
  log "kubectl $KUBECTL"
  fetch "https://dl.k8s.io/release/$KUBECTL/bin/linux/amd64/kubectl"
  fetch "https://dl.k8s.io/release/$KUBECTL/bin/linux/amd64/kubectl.sha256"
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -     # file holds the bare hash
  install -m 0755 kubectl "$BIN/kubectl"
fi

WANT=$HELM
if ! have helm version; then
  log "helm $HELM"
  f=helm-$HELM-linux-amd64.tar.gz
  fetch "https://get.helm.sh/$f"
  fetch "https://get.helm.sh/$f.sha256sum"
  sha256sum -c "$f.sha256sum"
  tar -xzf "$f" linux-amd64/helm
  install -m 0755 linux-amd64/helm "$BIN/helm"
fi

WANT=$K3D
if ! have k3d version; then
  log "k3d $K3D"
  fetch "https://github.com/k3d-io/k3d/releases/download/$K3D/k3d-linux-amd64"
  fetch "https://github.com/k3d-io/k3d/releases/download/$K3D/checksums.txt"
  verify k3d-linux-amd64 checksums.txt
  install -m 0755 k3d-linux-amd64 "$BIN/k3d"
fi

# NOT `apt install yq`: Ubuntu's yq is a different (Python) tool with other syntax.
WANT=$YQ
if ! have yq --version; then
  log "yq $YQ (mikefarah)"
  base="https://github.com/mikefarah/yq/releases/download/$YQ"
  fetch "$base/yq_linux_amd64"
  fetch "$base/checksums"
  fetch "$base/checksums_hashes_order"
  # yq's checksums file lists many hashes per line; the order file says which column is SHA-256.
  col=$(( $(grep -nx 'SHA-256' checksums_hashes_order | cut -d: -f1) + 1 ))
  echo "$(awk -v c="$col" '$1=="yq_linux_amd64"{print $c}' checksums)  yq_linux_amd64" | sha256sum -c -
  install -m 0755 yq_linux_amd64 "$BIN/yq"
fi

WANT=$HADOLINT
if ! have hadolint --version; then
  log "hadolint $HADOLINT"
  fetch "https://github.com/hadolint/hadolint/releases/download/$HADOLINT/hadolint-linux-x86_64"
  fetch "https://github.com/hadolint/hadolint/releases/download/$HADOLINT/checksums.sha256"
  verify hadolint-linux-x86_64 checksums.sha256
  install -m 0755 hadolint-linux-x86_64 "$BIN/hadolint"
fi

WANT=$GITLEAKS
if ! have gitleaks version; then
  log "gitleaks $GITLEAKS"
  v=${GITLEAKS#v}
  f=gitleaks_${v}_linux_x64.tar.gz
  fetch "https://github.com/gitleaks/gitleaks/releases/download/$GITLEAKS/$f"
  fetch "https://github.com/gitleaks/gitleaks/releases/download/$GITLEAKS/gitleaks_${v}_checksums.txt"
  verify "$f" "gitleaks_${v}_checksums.txt"
  tar -xzf "$f" gitleaks
  install -m 0755 gitleaks "$BIN/gitleaks"
fi

WANT=$ARGOCD
if ! have argocd version --client; then
  log "argocd CLI $ARGOCD"
  fetch "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD/argocd-linux-amd64"
  fetch "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD/cli_checksums.txt"
  verify argocd-linux-amd64 cli_checksums.txt
  install -m 0755 argocd-linux-amd64 "$BIN/argocd"
fi

WANT=$TRIVY
if ! have trivy --version; then
  log "trivy $TRIVY"
  v=${TRIVY#v}
  f=trivy_${v}_Linux-64bit.tar.gz
  fetch "https://github.com/aquasecurity/trivy/releases/download/$TRIVY/$f"
  fetch "https://github.com/aquasecurity/trivy/releases/download/$TRIVY/trivy_${v}_checksums.txt"
  verify "$f" "trivy_${v}_checksums.txt"
  tar -xzf "$f" trivy
  install -m 0755 trivy "$BIN/trivy"
fi

# ---- 4. Python CLI tools: pipx = one isolated venv per tool ------------------
# (pip install --user into the system Python is blocked on Ubuntu 24.04: PEP 668.)
log "pipx: ansible, pre-commit"
pipx ensurepath >/dev/null 2>&1
pipx install --include-deps ansible >/dev/null 2>&1   # no-op if already installed
pipx install pre-commit >/dev/null 2>&1

# ---- 5. Shell: aliases + tab completion --------------------------------------
# The block sits between markers and is REPLACED on every run, so editing it
# here and re-running updates ~/.bashrc instead of piling up copies.
log "~/.bashrc: aliases and completion"
sed -i '/^# >>> devops-lab >>>$/,/^# <<< devops-lab <<<$/d' ~/.bashrc
cat >> ~/.bashrc <<'RC'
# >>> devops-lab >>>
# Ubuntu's ~/.profile runs this file BEFORE it adds ~/.local/bin to PATH,
# so add it here or the completions below can't find helm, k3d...
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
alias k=kubectl
for t in kubectl helm k3d; do command -v "$t" >/dev/null && source <("$t" completion bash); done
complete -o default -F __start_kubectl k
command -v terraform >/dev/null && complete -C "$(command -v terraform)" terraform
# <<< devops-lab <<<
RC

log "Done. Open a new shell (for PATH), then run: bash scripts/check-tools.sh"
