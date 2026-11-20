# Bash scripting: the traps that bite in DevOps scripts

Installers, CI steps, backup jobs: short scripts that must **fail loudly** and **run twice safely**.
Every trap below was hit for real in this lab (see [Phase 0 notes](../phase-0-notes.md)).

---

## 1. The header every script starts with

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "FAILED (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR
```

| Flag | Means | Without it |
|---|---|---|
| `-e` | exit on the first failing command | script carries on after an error and does damage |
| `-u` | unset variable = error | `rm -rf "$DIR/"` with empty `$DIR` → `rm -rf /` |
| `-o pipefail` | a pipeline fails if **any** part fails | `curl … \| tar x` "succeeds" when curl failed |
| `-E` | functions inherit the `ERR` trap | a failure inside a function exits **silently** |
| `trap … ERR` | print where it died | `set -e` exits with no message at all |

Interview line: *"`set -e` makes a script stop; the ERR trap makes it say where. You want both."*

---

## 2. SIGPIPE: the silent killer under `pipefail`

```bash
set -eo pipefail
v=$(apt-cache madison terraform | awk '/1.17/ {print $3; exit}')   # script DIES here, no message
```

1. `awk` finds a match and **exits**, closing the pipe.
2. `apt-cache` is still writing → kernel sends **SIGPIPE** → exit **141** (128 + 13).
3. `pipefail` → pipeline failed; `set -e` → script exits. Nothing printed.

Same trap: `cmd | grep -q x`, `cmd | grep -m1 x`, `cmd | head -1`. Small outputs often "work" (the writer finished
before the reader left), so the bug appears only with longer output: **flaky**.

**Fixes:**
```bash
out=$(cmd); [[ $out == *x* ]]                 # capture, then test (no pipe at all)
cmd | awk '!found && /x/ {print; found=1}'    # reader keeps reading to the end
```

---

## 3. Idempotency: running twice must be safe

| Do | Not |
|---|---|
| Check before acting: skip if the tool is already at the pinned version | Re-download and reinstall every run |
| Replace a marked block: `sed -i '/^# >>> x >>>$/,/^# <<< x <<<$/d' f` then append | `echo … >> ~/.bashrc` (duplicates every run) |
| `mkdir -p`, `install -m 0755 src dst`, `ln -sf` | `mkdir`, `cp` + `chmod`, `ln -s` (fail on second run) |
| Write files from a heredoc (`cat > f <<'EOF'`) | Edit files with fragile in-place appends |

Test it: **run the script twice; the second run must change nothing.**

---

## 4. Downloading safely

```bash
fetch() { curl -fsSL --retry 3 -o "${2:-$(basename "$1")}" "$1"; }
```
- `-f`: fail on HTTP 404/500 (without it, the error page is saved as your "binary").
- `-sS`: quiet, but still show errors. `-L`: follow redirects (GitHub release URLs redirect).
- **Verify the checksum** from the project's checksum file, and **pin the version**: no `latest`, no `curl | bash`.
- Checksum files differ (`hash  name`, `hash *name`, `hash  _dist/name`): look up by bare name, then
  `echo "$hash  $file" | sha256sum -c -`.
- Temp work in `TMP=$(mktemp -d)` with `trap 'rm -rf "$TMP"' EXIT`: cleaned up even on failure.

---

## 5. Quoting and words

```bash
rm -rf "$dir"/build       # always quote expansions
for f in "$@"; do …       # "$@" keeps arguments with spaces intact; $* does not
[[ -n ${x:-} ]]           # under set -u, give a default when a var may be unset
```

---

## 6. Environment gotchas seen on WSL / Ubuntu

| Symptom | Cause | Fix |
|---|---|---|
| `$'\r': command not found` | Script saved with Windows CRLF endings | `.gitattributes`: `*.sh text eol=lf` |
| Tool "not found" in `.bashrc`, found later | `~/.profile` sources `.bashrc` **before** adding `~/.local/bin` to `PATH` | Add the dir to `PATH` in the block itself |
| Two different `kubectl` versions | Docker Desktop's symlink in `/usr/local/bin` vs yours | `type -a kubectl`: first in `PATH` wins |
| `pip install` → "externally-managed-environment" | Ubuntu 24.04 protects the system Python (PEP 668) | `pipx install <tool>` |
| `git: detected dubious ownership` | Repo owned by another user (Windows files in WSL) | `git config --global --add safe.directory <that repo>` (never `*`) |

---

## 7. Lint it

```bash
shellcheck script.sh      # catches unquoted vars, useless cats, most of section 5
bash -n script.sh         # syntax only, no execution
```
