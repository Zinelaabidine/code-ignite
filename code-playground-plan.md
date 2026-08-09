# Code playground — phase 1 build plan

Local-first build using Python/Docker, SQS and S3. EKS and Argo CD come later.

SQS and S3 are not scaffolding — they stay exactly as they are after the move to
EKS. Only the component that *executes* the code changes.

---

## The four pieces

| Piece | Responsibility |
| --- | --- |
| Frontend | Login, editor, Run button, output pane |
| API | Verify token, store code, enqueue job, return job ID; serve result on request |
| Queue + storage | SQS carries job IDs, S3 holds code and output |
| Worker | Pull from SQS, execute code, write result to S3 |

No database yet. S3 is the result store.

---

## The one thing to get right now

Put execution behind a single interface. Nothing else in the system knows what
sits underneath it.

```python
from typing import Protocol, Literal
from dataclasses import dataclass

@dataclass
class RunResult:
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    status: Literal["ok", "timeout", "oom", "error"]

class Runner(Protocol):
    def run(self, code: str, language: str, timeout: int) -> RunResult: ...
```

Today: `LocalDockerRunner`.
Later: `KubernetesJobRunner`.

The worker loop, the API, the frontend, SQS and S3 do not change. That single
swap is the entire EKS migration.

Write the local runner first, but write it *against this interface* rather than
inlining `docker run` calls into the worker. Costs nothing today, saves the
rewrite later.

---

## The flow

```
POST /runs          → verify JWT
                    → job_id = uuid4()
                    → S3 PUT  jobs/{job_id}/input.json   {code, language, user_sub}
                    → SQS SEND {job_id}
                    → 202 {job_id}

worker loop         → SQS RECEIVE
                    → S3 GET  jobs/{job_id}/input.json
                    → runner.run(...)
                    → S3 PUT  jobs/{job_id}/result.json  {stdout, stderr, status, ...}
                    → SQS DELETE

GET /runs/{job_id}  → S3 GET result.json
                    → 200 result, or 202 if not there yet
```

The frontend polls the GET every 500 ms until a result appears. Polling is fine
here — no WebSockets yet.

**Two settings to get right from the start:**

- SQS visibility timeout slightly longer than max execution time (60 s for a
  10 s limit).
- A dead-letter queue after 2 receives, so a job that crashes the worker isn't
  redelivered forever.

---

## The local runner

```bash
docker run --rm \
  --network none \
  --memory 256m --cpus 0.5 \
  --read-only --tmpfs /tmp:size=16m \
  --user 65534 \
  -v /tmp/job-xyz:/sandbox:ro \
  python:3.12-alpine timeout 8 python /sandbox/main.py
```

These flags aren't about hardening yet — they map almost one-to-one onto
Kubernetes Job fields later, which makes the migration mechanical:

| Docker flag | Kubernetes equivalent |
| --- | --- |
| `--memory 256m` | `resources.limits.memory` |
| `--cpus 0.5` | `resources.limits.cpu` |
| `--network none` | NetworkPolicy (deny all) |
| `--user 65534` | `securityContext.runAsUser` |
| `--read-only` | `readOnlyRootFilesystem: true` |
| `timeout 8` | `activeDeadlineSeconds` |

---

## Build order

### 1. Skeleton, no queue
API calls `runner.run()` synchronously and returns output. Hardcode Python. No
auth. Get `curl` → `print("hi")` → `"hi"` working end to end.
*Half a day. Proves the Docker sandboxing works.*

### 2. Split via SQS + S3
Same behaviour, now asynchronous. API returns a job ID, worker is a separate
process, frontend polls.
*Don't skip this even though step 1 already "works" — it's what makes the EKS
step trivial.*

### 3. Bolt on Cognito login
Reuse the existing frontend flow; add JWT verification to the API. Store
`user_sub` in the input object so metering is possible later.

### 4. Frontend
CodeMirror, language dropdown, run button, output pane with spinner. Show
status distinctly: finished, timed out, crashed.

### 5. More languages
Keep a dict mapping language → `{image, command, extension}`. Adding Node or Go
becomes one entry. Later this dict becomes a ConfigMap — which is the Argo CD
demo.

---

## Run against real AWS, not LocalStack

- SQS: 1M requests free per month, permanently.
- S3: cents for a handful of small objects.

Real services mean no surprises on migration, and IAM gets used properly from
day one. LocalStack adds a "is it failing because of LocalStack?" layer that
isn't worth it here.

---

## What changes at EKS time

**Unchanged:** the API, the queue, the storage layout.

**Changed:**

- Worker becomes a Deployment in the cluster instead of a local process
- `LocalDockerRunner` → `KubernetesJobRunner`
- Worker replica count driven by SQS queue depth instead of always-on
- Manifests move into Git, Argo CD syncs them

A clean before/after migration story — more compelling than building on
Kubernetes from the start.

---

## Features worth adding later

**Code side**

- Execution time and memory shown next to output
- Starter examples per language
- stdin support (another field in the input object)

**Backend side** — these become the EKS demos

- Per-user rate limits keyed on the Cognito `sub`
- A `premium` Cognito group with longer timeouts and more memory
- A status endpoint showing how many workers are alive — dull locally, the
  centrepiece once workers scale from zero on queue depth

---

## Next action

Start with step 1. Code running in a sandbox by this evening.
