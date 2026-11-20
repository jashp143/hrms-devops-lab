# Phase 2 notes: CI with GitHub Actions

**Date:** 2026-11-20 · **Status:** done ✅ (branch protection carried forward, section 6)

Every service now has a pipeline that **tests, lints, builds, scans and publishes** on every push to `main`.
The plan was GitHub Actions for four services and Jenkins for one, to compare them; that was dropped
(section 5). The most useful result: on its first runs, the scan gate and the Linux runners found
**real problems that local Windows builds had hidden for weeks**.

---

## 1. What was built

One workflow per service repo (`.github/workflows/ci.yml`), all the same shape:

```
push to main / PR / manual button
  └─ job 1: test         ← language-specific (below)
  └─ job 2: image        ← needs job 1
       hadolint (fail on errors) → buildx build ONCE, load → Trivy (fail on fixable CRITICAL)
       → login to GHCR → push  ghcr.io/<owner>/<service>:<full commit SHA>
```

| Service | Job 1 | Runtime in CI |
|---|---|---|
| API backend | `mvnw test` (unit) + `*IT` run against a **PostgreSQL + pgvector service container** | Java 25 |
| Realtime service | `mvnw verify`: Surefire (unit) + Failsafe (IT); **Testcontainers** starts its own PostgreSQL, Valkey and S3 | Java 25 |
| ML service | `pip install` + `pytest` (DB and model stubbed, so no services) | Python 3.14 |
| Web console | `npm ci` → lint → typecheck → test → `next build` | Node 26 |
| Admin portal | same as web console | Node 26 |

Choices every workflow shares:

| Choice | Why |
|---|---|
| Actions pinned to a **full commit SHA** (version in a comment) | A tag can be moved to malicious code; a commit can't |
| `permissions: contents: read`, `packages: write` only on the image job | Least privilege for the built-in token; **no personal access token stored anywhere** |
| Build once, `load`, scan, then push **the same image** | What was scanned is exactly what ships |
| Tag = full commit SHA, never `latest` | Always know which commit runs; roll back to any commit |
| `concurrency` with `cancel-in-progress` | A newer push cancels the stale run: saves minutes |
| Trigger on `main` + PRs + manual button only | `main` and the lab branch usually point at the same commit; both triggering ran everything twice |
| Same language version as the Dockerfile (Java 25, Python 3.14, Node 26) | CI tests what production runs |
| Caches: Maven/npm/pip via `setup-*`, Docker layers via `type=gha,mode=max` | Second runs skip downloads and unchanged layers |
| Test reports uploaded **only on failure** | Read a failure without re-running; no storage on green runs |
| `.trivyignore` with a reason **and an expiry date** per entry | An accepted risk can't quietly become permanent |

---

## 2. Numbers

### Last green run per service (GitHub-hosted runner)

| Service | Test job | Image job (lint, build, scan, push) |
|---|---|---|
| API backend | 314 s (1,777 unit + 292 integration tests) | 103 s |
| Realtime service | 214 s (unit + Testcontainers ITs) | 302 s |
| ML service | 57 s (pip cache hit; ~3.5 min on a cold cache) | 411 s (288 MB model layer) |
| Web console | 49 s | 208 s |
| Admin portal | 126 s | 236 s |

### What the gate found on the first scans

| Service | Finding (fixable CRITICAL) | Fix |
|---|---|---|
| API backend | 10: Tomcat ×5, Netty ×1, **Spring Framework ×3 fixed only in the next major** | Patched Tomcat/Netty, then **framework major upgrade** (Spring Boot 3.5 → 4.1, Java 17 → 25) |
| Realtime service | Tomcat ×1 | Framework patch release |
| Web console | **2 unauthenticated remote-code-execution** advisories in Next.js | Next.js 16.3 → 16.4 (same version as the admin portal) |
| ML service | anyio (TLS certificate spoofing), pinned old by the web framework | FastAPI 0.104 → 0.165 |
| Admin portal | none | — |

End state: **0 fixable CRITICAL** in all five images, and `.trivyignore` is empty everywhere it exists.

---

## 3. What broke and how it was fixed

Almost nothing here was a CI problem. CI was the first **clean Linux machine** these projects ever ran on.

1. **`./mvnw: Permission denied` (exit 126).** The wrapper script was committed from Windows without the
   executable bit (git mode `100644`). Windows doesn't care; Linux does.
   Fix: `git update-index --chmod=+x mvnw` (a mode-only commit, no content change).
2. **229 of 318 tests errored on every machine.** A test container image (an S3 server) had been **removed
   from Docker Hub**. Fix: a maintained registry, **pinned by digest** because it only publishes `latest`.
   Lesson: an unpinned third-party test image is a dependency that can vanish.
3. **io_uring out of locked memory.** On Linux the socket library auto-selects Netty's **io_uring** transport;
   every cached test context opened rings until the runner's `RLIMIT_MEMLOCK` ran out. Fix: transport is a
   setting; production keeps `AUTO`, tests use plain NIO.
4. **"Address already in use", Linux only.** Two causes stacked:
   - every test context bound the **same static port**;
   - Spring Framework 7 **pauses** cached test contexts. A paused context frees its port, a new context is
     handed that port by the OS, and the paused one can't rebind when it resumes.

   Windows hid both: `SO_REUSEADDR` lets two sockets bind one port there. Fix: one free port per context, plus
   `spring.test.context.cache.pause=never`.
5. **A lock test that passed everywhere except CI.** `CompletableFuture.supplyAsync()` uses the common pool,
   which has **CPUs − 1** threads: **one** on a 2-vCPU runner. The two "concurrent" attempts ran one after
   the other (1.0 s = 2 × 500 ms), so both got the lock. Fix: the test brings its own 2-thread pool.
6. **Cache tests racing an echo.** A cache invalidation evicts locally *and* is broadcast through a Valkey
   stream to every instance, **including itself**, asynchronously. On a slow runner, the echo of a test's own
   setup arrived after the test warmed a cache it expected to stay stale. Fix: the stream records the last
   *handled* id, and those tests wait until every published note is handled.
7. **Tests that only passed with a developer's `.env`.** The ML service refuses to start without an API key;
   locally it came from `.env`, in CI there is none. Fix: a test-only key set before config loads.
8. **Moving to the new framework major.** One real behaviour change, caught in review rather than by a test:
   the new JSON library binds request objects that have an all-args constructor **through the constructor**,
   skipping normalising setters and field defaults (a phone number stopped being normalised, a default country
   became `null`). The app runs in backward-compatible mode; the test that should have caught it was still
   using the *old* library, which another dependency kept on the classpath.

### How bugs 4–7 were found without burning CI minutes

Run the suite **in a Linux container on the laptop**, with Testcontainers talking to the host's Docker:

```bash
docker run --rm --cpus=2 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal --add-host host.docker.internal:host-gateway \
  -v "$PWD:/src:ro" -v m2:/root/.m2 -w /work maven:3.9-eclipse-temurin-25-noble \
  sh -c 'cp -r /src/. /work && mvn -B -q verify'
```

`--cpus=2` mimics the runner (the JVM honours the cgroup quota even though `nproc` still shows all cores).
It's harsher than a real 2-vCPU machine, which makes it a good flake detector. Copy the source **without
`.env`** (bug 7 was hidden by exactly that), and run anything flaky twice.

---

## 4. Decisions worth defending

| Decision | Why | Alternative considered |
|---|---|---|
| Gate on **fixable CRITICAL** only | Unfixed CVEs can't be acted on; HIGH would block every run today | Block on HIGH: right later, with Renovate keeping deps fresh |
| Accepted risks need an **expiry** | When it expires CI fails again, forcing a re-decision | Plain ignore list: becomes permanent |
| Upgrade the framework major instead of living with exceptions | The fix only existed in the next major and the old line was out of open-source support | Timed exception (drafted, made unnecessary by the upgrade before it was committed) |
| Fix flaky tests at the root, never "re-run until green" | A flaky gate trains everyone to ignore red | Retries: hide real races |
| Test-only switches (`transport=NIO`, `pause=never`) instead of changing production defaults | Production behaviour unchanged; the switch is named and documented | Change prod to NIO: slower, for a test-only problem |
| Hosted runners, no self-hosted | Free minutes cover it with caching; nothing to patch | Self-hosted on the laptop: free, but the laptop must be on |

---

## 5. Jenkins: dropped

The roadmap planned Jenkins for the ML service to compare with Actions. **Dropped on 2026-11-20**: one CI
system for five services is simpler to run and to explain, and the comparison is answerable without
running both:

- **Actions:** hosted, YAML next to the code, marketplace actions, OIDC to clouds, GitHub-native checks.
- **Jenkins:** self-hosted controller + agents, Groovy `Jenkinsfile`, plugins, credentials store; strong when
  builds must stay on-premises or across many SCMs. The cost is running and patching it yourself.

---

## 6. Not done (carried forward)

- **Branch protection** on `main` requiring the CI check (the roadmap's "done when").
- **Renovate / Dependabot** for dependencies, actions and base-image digests (Phase 10).
- **Image signing** (cosign) and SBOM attestations: Phase 6 (supply chain).
- **`on_event` → lifespan** in the ML service (deprecated in the new FastAPI; works today).
- **Self-hosted S3 compose file** still references the image that was removed from Docker Hub.
- **Deploy** of the security fixes: the web console's RCE fix and the backend upgrade are built and pushed,
  not deployed. The backend's first deploy needs a cache flush (cache entries are in the old JSON format).

---

## 7. Interview stories

- **"Our scanner found an unauthenticated RCE on day one."** Gate on fixable CRITICAL, what we fixed, why the
  gate stays strict, and expiring exceptions for what can't be fixed yet.
- **"Upgrading a framework major to fix three CVEs."** Patched what could be patched, timed exception for the
  rest, then the major upgrade; the one silent behaviour change (constructor binding) and how review caught it.
- **"Tests that only failed in CI."** Executable bit, `SO_REUSEADDR`, io_uring memlock, the common pool on
  2 CPUs, a test reading a developer's `.env`. Each one is a real difference between a laptop and a server.
- **"Reproducing CI on my laptop."** Linux container, Docker socket, `--cpus=2`, no `.env`.
- **"Least-privilege CI."** SHA-pinned actions, read-only token by default, no stored PAT, build-once-scan-push.

## 8. Resume line

> Built GitHub Actions CI for 5 services (Java, Python, Next.js): tests against real PostgreSQL/Valkey,
> Dockerfile linting, **Trivy gating on fixable CRITICALs**, SHA-tagged images to GHCR with SHA-pinned
> actions and no stored credentials; the gate found and drove fixes for **14 CRITICAL CVEs** on its first
> runs, including two unauthenticated RCEs and a framework major upgrade (Spring Boot 3 → 4, Java 17 → 25).
