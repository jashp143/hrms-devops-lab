# Phase 1 notes: Docker production images

**Dates:** 2026-11-19 to 2026-11-20 · **Status:** done ✅

Five services, three languages, one goal: images that are **small to update, safe to run, and the same image
everywhere** (Docker Compose in production today, Kubernetes in this lab later). The patterns are in the
[cheatsheet](cheatsheets/dockerfile-from-scratch.md); this file is the record of what was done and what broke.

---

## 1. What was built

| Service | Stack | Key changes |
|---|---|---|
| API backend | Spring Boot, Maven | Layered jar, numeric user (kept the existing UID), exec entrypoint, `JAVA_TOOL_OPTIONS`, OCI labels, `.dockerignore` |
| ML service | Python, FastAPI, ONNX | Model baked in and checksum-verified, Python 3.10 → 3.14, headless OpenCV only, upgraded ML stack with identical outputs |
| Realtime service | Spring Boot, Socket.IO | Pinned distro, numeric user, read-only app dir, OOM exit flag, GET healthcheck, labels |
| Web console | Next.js 16 | Node 26 LTS, numeric user, read-only app dir, `node_modules` split into its own layer, self-only healthcheck |
| Admin portal | Next.js 16 | Same as web console (one approved pattern, reused) |

Every image: multi-stage, runs as a **numeric non-root user**, exec-form entrypoint (app is PID 1 and gets
`SIGTERM`), pinned base image + distro, `.dockerignore`, OCI labels (`source`, `revision`, `version`) from
build args. Every Dockerfile was reviewed line by line before commit.

---

## 2. Numbers

### Bytes shipped per code commit (the number that matters for CI/CD)

| Service | Before | After |
|---|---|---|
| API backend | ~173 MB (fat jar) | **~3 MB** |
| Realtime service | already layered | **1.25 MB** (89 MB deps stay cached) |
| Web console | ~45 MB (one standalone layer) | **~3.2 MB** |
| Admin portal | ~53 MB | **~10.7 MB** |

Proved with a **layer test**: change one string, rebuild, compare `docker inspect --format '{{.RootFS.Layers}}'`.
Web console: 7 of 10 layers byte-identical, including the 41.7 MB dependency layer.

### Image size (local, uncompressed)

| Service | Before | After | Why |
|---|---|---|---|
| API backend | 762 MB | 762 MB | Layering makes **updates** smaller, not images |
| ML service | 1.6 GB **+ 288 MB download on every start** | 1.93 GB, **no download** | Model moved from runtime to build time; system packages layer 237 MB → 18 MB |
| Realtime service | 646 MB | 625 MB | |
| Web console | 308 MB | 309 MB | |
| Admin portal | 320 MB | 319 MB | |

Honest takeaway: total size barely moved, and that's fine. The wins are **per-commit transfer**, **startup
without internet**, and **security posture**, not a smaller `docker images` column.

### Runtime checks (every service)

| Check | Result |
|---|---|
| `docker exec <c> id` | numeric non-root UID |
| `touch /app/x` | `Permission denied` (code is read-only to the app) on the three newest images |
| Healthcheck | `healthy` in the real Compose stack |
| `docker stop` (web apps) | ~0.5 s, exit **143** = exited cleanly on SIGTERM |
| ML embeddings old vs new stack | cosine similarity **1.000000** |
| ML start with `--network none` | starts, no download |

---

## 3. What broke and how it was fixed

1. **Healthcheck 401, container `unhealthy`.** A copied `wget --spider` sends **HEAD**; the service's
   security config allowed only **GET** on the health URL. A manual `curl` passed because curl sends GET.
   Fix: `wget -q -O /dev/null`. Lesson: test the exact command production runs (`.State.Health.Log`).
2. **Changing the UID would have locked the app out of its own files.** Existing uploads on a volume were
   owned by the old UID. Fix: pin the existing number. A UID on a volume is a data contract.
3. **Renaming an env var silently dropped memory flags.** `JAVA_OPTS` → `JAVA_TOOL_OPTIONS` removed the shell
   from the entrypoint, but Compose still set `JAVA_OPTS`. Fix: update every place that sets it.
4. **288 MB model downloaded on every container start** (found by reading the startup log). Fix: separate build
   stage downloads it once and verifies its SHA-256.
5. **Two OpenCV builds installed** (one pulled in by a dependency): ~230 MB of duplicates plus an unneeded
   graphics stack. Found with `pip list` inside the image.
6. **"Latest Python" had no wheels yet** for the ML runtime. Fix: newest version every dependency supports.
7. **A health check that depends on another service.** The web console's `/api/health` calls the backend, and
   the backend reported DOWN because of an unrelated mail check. A probe there would mark the web container
   unhealthy for someone else's problem. Fix: self-only `/login` for the container healthcheck.
8. **`NEXT_PUBLIC_*` is baked in at build,** including in server-side middleware, so a "maintenance mode" env var
   can't be toggled on a running container. Documented; app change pending.

---

## 4. Decisions worth defending

| Decision | Why | Alternative considered |
|---|---|---|
| One image for Compose **and** Kubernetes | Production must keep working if this branch is merged | Separate lab images: two things to maintain |
| Keep `wget` + `HEALTHCHECK` | Compose uses them; Kubernetes just ignores `HEALTHCHECK` | Distroless: smaller, but breaks Compose health |
| Alpine for Node, Ubuntu/Debian slim for JVM and Python | Node deps ship musl builds; the ML stack needs glibc | Alpine everywhere: risky for native wheels |
| Root-owned `/app`, writable dirs listed explicitly | A compromised app can't rewrite its code; ready for `readOnlyRootFilesystem` | `chown -R` app user: simpler, weaker |
| Tags, not digests | Rebuilds pick up base-image security patches | Digest pinning: reproducible, needs a bot (Renovate) to stay patched |
| BuildKit cache mounts for `~/.m2` / `~/.npm` | Fast local rebuilds, nothing in layers | Needs `--cache-to type=gha` in CI (Phase 2) |

---

## 5. Not done (carried forward)

- **Trivy scan and hadolint:** not run yet; they arrive with CI in **Phase 2** (fail on CRITICAL).
- **Digest pinning + Renovate:** Phase 2/10.
- **Kubernetes probes:** liveness should use a self-only endpoint, readiness may include dependencies:
  design in **Phase 3**.
- **ML image in production:** the upgraded ML image is on the lab branch only; promote after a production check.
- **ML model license:** the pretrained face model is non-commercial; needs a decision before commercial use.
- **Backend mail health indicator** and the build-time maintenance flag: app fixes, outside this lab.

---

## 6. Interview stories

- **"Cut what we ship per commit from 173 MB to 3 MB."** Layered jar / split `node_modules`: dependencies change
  rarely, code every commit, so they become separate cached layers. Total size didn't change, and I can explain
  why that's still the win: CI push, registry storage, node pull time on rollout.
- **"A healthcheck that passed by hand and failed in production."** HEAD vs GET, 401, why you test the exact probe.
- **"Removing root without breaking data."** Numeric UID for `runAsNonRoot`; kept the existing UID because a
  volume's file ownership is a contract.
- **"An ML container that downloaded 288 MB on every restart."** Read the logs, moved it to build time with a
  checksum, proved the outputs identical (cosine 1.000000), proved it starts offline.
- **"Why my web container doesn't check the backend in its health check."** Cascading failure; liveness vs readiness.

## 7. Resume line (with real numbers)

> Containerised 5 polyglot services (Java/Spring, Python/FastAPI, Next.js) with hardened multi-stage images:
> numeric non-root users, read-only app directories, graceful SIGTERM shutdown; cut per-commit image transfer
> by up to **98%** (173 MB → 3 MB) and removed a 288 MB runtime model download.
