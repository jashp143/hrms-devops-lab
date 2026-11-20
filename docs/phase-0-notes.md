# Phase 0 notes: Workstation setup

**Date:** 2026-11-20 · **Status:** done ✅

**Goal:** a Linux toolbox on a Windows laptop (16 GB RAM, 6 cores / 12 threads), reproducible from one script.

---

## 1. What was built

| Piece | What | Why |
|---|---|---|
| `~/.wslconfig` (Windows) | `memory=10GB`, `processors=8`, `swap=4GB`, `autoMemoryReclaim=gradual`, `sparseVhd=true` | All WSL2 distros **and** Docker Desktop share one VM; without a cap it can take half the RAM and keep it |
| WSL distro | Ubuntu 24.04 LTS | What most CI runners and servers still run; lab matches work |
| Docker | Docker Desktop with WSL integration for the distro | One engine for Windows and Linux shells |
| [`scripts/install-tools.sh`](../scripts/install-tools.sh) | 13 tools, pinned versions, **SHA-256 verified**, safe to re-run | Reproducible toolbox; a second run changes nothing |
| [`scripts/check-tools.sh`](../scripts/check-tools.sh) | Prints every tool + version, exits 1 if any is missing | The phase's "done when" check, reusable in CI |
| [`.pre-commit-config.yaml`](../.pre-commit-config.yaml) | gitleaks scans staged changes on every commit | This repo is public |
| [`.gitattributes`](../.gitattributes) | `*.sh text eol=lf` | A Windows checkout must not turn scripts into CRLF |
| `~/.bashrc` block | `k` alias, completion for kubectl/helm/k3d/terraform | Daily speed; block is replaced on every install run |
| Git in WSL | identity, `safe.directory`, `core.autocrlf=input`, Windows Credential Manager | Commits come from Linux, so the gitleaks hook runs |

**Done-when check:** `bash scripts/check-tools.sh` → 14 tools ✔, exit 0.

| Tool | Version | Installed via |
|---|---|---|
| kubectl | v1.37.2 | binary + `.sha256` |
| helm | v4.3.2 | tarball + `.sha256sum` |
| k3d | v5.9.0 | binary + `checksums.txt` |
| terraform | 1.17.2 | HashiCorp **signed apt repo** |
| ansible | 2.21.6 | pipx |
| trivy | 0.76.2 | tarball + checksums |
| hadolint | 2.15.1 | binary + checksums |
| gitleaks | 8.30.1 | tarball + checksums |
| argocd CLI | v3.6.2 | binary + checksums |
| yq (mikefarah) | v4.54.3 | binary + multi-hash checksums |
| pre-commit | 4.7.0 | pipx |
| git, jq, curl, unzip | Ubuntu | apt |

---

## 2. Decisions

| Decision | Why | Alternative |
|---|---|---|
| Pin every version in the script | Same toolbox on every rebuild; upgrades are a reviewed one-line diff | "latest" at install time: different machines, different tools |
| Verify SHA-256 of every download | A tampered or truncated download fails loudly instead of running | `curl \| bash` installers: trust whatever the server sends |
| Binaries in `~/.local/bin` | Docker Desktop owns `/usr/local/bin/kubectl` (a symlink it re-creates on restart); `~/.local/bin` is earlier in `PATH` and needs no sudo | `/usr/local/bin`: silently overwritten by Docker Desktop |
| Terraform from the vendor apt repo, key restricted with `signed-by=` | Shows the signed-repo pattern; the vendor key can only vouch for its own repo | Global trusted keyring (old `apt-key`): any key trusts any repo |
| pipx for Python CLIs | One venv per tool; Ubuntu 24.04 blocks `pip install` into the system Python (PEP 668) | `pip --break-system-packages`: breaks apt-managed Python |
| mikefarah `yq`, not `apt install yq` | Ubuntu's `yq` is a different (Python) tool with other syntax | Same name, wrong program |
| Lab commits from WSL | The gitleaks hook lives in WSL; Windows Git can't run it | Manual `gitleaks` before push: easy to forget |

---

## 3. What broke and how it was fixed

1. **Install script died silently after "terraform".** `apt-cache madison | awk '{...; exit}'`: awk exits at the
   first match, `apt-cache` is still writing, gets **SIGPIPE** (exit 141), `pipefail` fails the pipeline and
   `set -e` ends the script with no message. Same trap in `cmd | grep -q`. Fix: never let the reader stop early
   under `pipefail`; capture output first (`out=$(cmd)`), then test it.
2. **"no properly formatted checksum lines" for k3d.** Checksum files differ: `hash  _dist/name` (path prefix),
   `hash *name` (binary-mode marker), `hash  name`. Fix: look up the hash by bare file name, then feed
   `sha256sum -c` one clean line. Tested against all five real files before re-running.
3. **The new `ERR` trap printed nothing.** `ERR` traps are **not inherited by functions** unless `set -E`
   (errtrace) is on, and the failure was inside `verify()`. Fix: `set -Eeuo pipefail`.
4. **`helm: command not found` on every new shell.** Ubuntu's `~/.profile` sources `~/.bashrc` *before* it adds
   `~/.local/bin` to `PATH`. Fix: the bashrc block adds it itself; completions only load if the tool exists.
5. **`fatal: detected dubious ownership` from git in WSL.** Repo files belong to the Windows user, git runs as the
   Linux user. Fix: `safe.directory` for this one repo only (never `*`).

Lessons 1–3 are in the [bash scripting cheatsheet](cheatsheets/bash-scripting.md).

---

## 4. Interview stories

- **"My install script failed silently: here's SIGPIPE."** Explain `set -euo pipefail`, why an early-exiting
  reader kills the writer, exit code 141 = 128 + 13, and how an `ERR` trap with `set -E` makes failures loud.
- **"Every binary I install is checksum-verified and pinned."** Supply-chain basics: why not `curl | bash`, why
  `signed-by=` per repo, why a pinned version is a reviewable change.
- **"Two `kubectl`s on one machine."** `PATH` order, `type -a`, who owns which directory.

## 5. Not done / later

- Repo lives on the Windows drive (`/mnt/f`); WSL file I/O there is slower than the Linux filesystem. Fine for
  docs and scripts; heavy builds (Phase 2+) can clone into `~/` instead.
- `floci` (local AWS emulator) runs as a container: set up in Phase 7, not installed here.
- Renovate (or similar) to bump pinned tool versions: Phase 2/10.
