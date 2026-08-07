# Code Playground — Implementation Specification

> **Audience:** an AI coding agent (Claude Sonnet) implementing this feature in
> this repository, step by step, in order.
>
> **Read `CLAUDE.md` in full before starting.** Every rule in it applies here.
> This document adds feature-specific requirements; it does not relax any
> existing standard.

---

## 0. How to use this document

1. Work through **§7 Build steps** strictly in order. Each step lists the files
   it touches, the code to write, and a **Done when** condition.
2. Do not start a step until the previous step's *Done when* is satisfied.
3. After each step, run the relevant checklist from `CLAUDE.md` §7.
4. Commit after each step using the message format in `CLAUDE.md` §7. Suggested
   scopes: `feat(infra)`, `feat(backend)`, `feat(frontend)`.
5. Code blocks in this document are **specifications, not always complete
   files**. Where a block is partial it says so. Fill in imports, type
   annotations, docstrings and error handling to the standard of the
   surrounding codebase.
6. `<project>` and `<env>` below mean the values of `var.project_name` and the
   environment (`dev`). Never hardcode them — use `local.name_prefix`.

### Non-negotiables specific to this feature

- **The frontend is a static export.** `next.config.ts` sets `output: "export"`
  in production. There are **no API routes, no server actions, no middleware,
  and no dynamic route segments**. All backend logic lives in a separate
  service. All navigation state lives in query strings.
- **Never trust the browser for authorization.** The frontend hides the admin
  UI as a convenience; the API must independently verify the JWT and the
  `cognito:groups` claim on every request.
- **User code is hostile.** Every sandbox control in §6 is mandatory, not
  optional, even locally.
- **No wildcards in IAM.** Same rule as the rest of the repo.

---

## 1. What exists today

| Layer | Current state |
|---|---|
| Frontend | Next.js 16.3 App Router, **static export**, TypeScript strict, Tailwind 4, shadcn/ui, `@base-ui/react` |
| Auth | Amplify 6 → Cognito User Pool. Tokens in `CookieStorage` (never localStorage) |
| Routes | Exactly one: `app/page.tsx` → `<AuthGate><SignedInHome/></AuthGate>` |
| Env | `frontend/lib/env.ts` — build-time contract, throws on missing var |
| Backend | **None.** No API, no database, no compute |
| Infra | Terraform: `infra/bootstrap`, `infra/envs/{dev,staging,prod}`, `infra/modules/static-site` (one `.tf` per AWS service) |
| CI/CD | GitHub Actions over OIDC, no static AWS keys |

Files you will read before writing anything:

```
CLAUDE.md
frontend/lib/env.ts
frontend/lib/auth/amplifyClient.ts
frontend/components/layout/AuthGate.tsx
frontend/components/home/SignedInHome.tsx
infra/modules/static-site/auth.tf
infra/modules/static-site/s3.tf
infra/modules/static-site/locals.tf
infra/modules/static-site/iam-github-oidc.tf
infra/modules/static-site/outputs.tf
infra/envs/dev/main.tf
infra/envs/dev/outputs.tf
.github/workflows/deploy.yml
```

---

## 2. What we are building

A signed-in user can:

- see a list of **their own** saved programs;
- create a program, choose a language (Python only in v1), and edit its source;
- press **Run** — the code is stored in S3 and a message is put on SQS;
- watch the status change and see the program's output when it finishes;
- see their own profile and remaining daily run quota.

A user in the Cognito `admins` group additionally gets an **Admin** section
listing every user (from Cognito) and every program (from DynamoDB), with the
ability to disable a user and delete any program.

Execution happens in a **Docker worker running on your laptop**. It long-polls
SQS, pulls the code from S3, runs it in a locked-down throwaway container, and
writes `output.txt` back to the same S3 prefix.

### Architecture (local phase)

```
Browser  (Next.js static export — `npm run dev` on :3000)
   │
   │ 1. Amplify → Cognito  (sign in, access token in a cookie)
   │ 2. fetch() with `Authorization: Bearer <accessToken>`
   ▼
API      (FastAPI in Docker — http://localhost:8000)
   ├─ verifies the JWT against the Cognito JWKS
   ├─ DynamoDB  ← program metadata, user profiles, quota counters
   ├─ S3        ← PUT  <sub>/<programId>/main.py
   └─ SQS       ← SendMessage {runId, programId, userSub, codeKey, outputKey}
                          │
                          ▼
Worker   (Python in Docker, long-polls SQS, mounts /var/run/docker.sock)
   ├─ DynamoDB  → status: queued → running
   ├─ S3        → GET  <sub>/<programId>/main.py
   ├─ docker run --network none --read-only --user 65534 … runner-python:3.12
   ├─ S3        → PUT  <sub>/<programId>/output.txt
   └─ DynamoDB  → status: succeeded | failed | timeout | oom | error
                          │
Browser polls GET /api/programs/{id}/status every 1s ──┘
   └─ on a terminal status → GET /api/programs/{id}/output → render
```

**Cognito, S3, DynamoDB and SQS are real AWS.** Only the API and the worker run
locally. That is deliberate: the AWS-facing code is the code that ships.

---

## 3. Data model

### 3.1 S3 layout

Bucket: `<domain-with-dashes>-programs` (see §7 Step 2 for the exact `locals`
expression). Private, versioned, encrypted, TLS-only — the same four companion
resources every bucket in this repo has.

```
s3://<programs-bucket>/
  <cognitoSub>/
    <programId>/
      main.py        # the source, written by the API on save
      output.txt     # combined stdout+stderr, written by the worker
```

Rules:

- `<cognitoSub>` is the `sub` claim, never an email or a username. It is stable
  and opaque.
- `<programId>` is a UUIDv4 generated by the API. **Never** accept a
  client-supplied program ID for a create.
- The API **always** derives the key prefix from the verified token's `sub`.
  A user cannot address another user's prefix, because the prefix is never
  taken from the request body.
- The file name comes from the language registry (`main.py` for Python), never
  from user input.
- The bucket has **no public access and no CORS configuration**. The browser
  never talks to S3 — the API proxies both reads and writes.

### 3.2 DynamoDB table

One table, `<project>-<env>-playground`, `PAY_PER_REQUEST`.

| | Attribute | Type |
|---|---|---|
| PK | `pk` | S |
| SK | `sk` | S |
| GSI1 PK | `gsi1pk` | S |
| GSI1 SK | `gsi1sk` | S |

**Program item**

| Attribute | Example | Notes |
|---|---|---|
| `pk` | `USER#a1b2c3-…` | `USER#<sub>` |
| `sk` | `PROG#7f9e…` | `PROG#<programId>` |
| `gsi1pk` | `PROGRAM` | constant — lets admin list everything |
| `gsi1sk` | `2026-08-06T10:12:00Z#7f9e…` | `<createdAt>#<programId>` |
| `programId` | `7f9e…` | |
| `ownerSub` | `a1b2c3-…` | |
| `ownerEmail` | `me@example.com` | denormalised for the admin table |
| `title` | `Fizzbuzz` | 1–120 chars |
| `language` | `python` | must exist in the language registry |
| `status` | `draft` | see §3.3 |
| `currentRunId` | `1f2e…` \| absent | guards against stale worker writes |
| `codeKey` | `a1b2c3/7f9e/main.py` | |
| `outputKey` | `a1b2c3/7f9e/output.txt` | |
| `codeBytes` | `312` | |
| `lastRunAt` | ISO-8601 | |
| `lastExitCode` | `0` | |
| `lastDurationMs` | `842` | |
| `outputTruncated` | `false` | |
| `runCount` | `4` | |
| `createdAt` / `updatedAt` | ISO-8601 UTC, `Z` suffix | |

**User profile item**

| Attribute | Notes |
|---|---|
| `pk` | `USER#<sub>` |
| `sk` | `PROFILE` |
| `email` | from the ID token at first sight |
| `quotaDate` | `2026-08-06` — the UTC day `runsToday` counts |
| `runsToday` | integer |
| `runsTotal` | integer |
| `dailyQuota` | integer, default 50 |
| `disabled` | bool, default `false` — set by an admin; the API rejects runs |
| `createdAt` / `updatedAt` | |

Access patterns, all served without a scan:

| Need | Query |
|---|---|
| List my programs | `Query pk = USER#<sub> AND begins_with(sk, "PROG#")` |
| Get one program | `GetItem pk = USER#<sub>, sk = PROG#<id>` |
| My profile / quota | `GetItem pk = USER#<sub>, sk = PROFILE` |
| Admin: all programs | `Query GSI1 gsi1pk = "PROGRAM"`, `ScanIndexForward=false` |
| Admin: all users | **Cognito `ListUsers`**, not DynamoDB — Cognito is the user directory. Enrich each row with its `PROFILE` item. |

> Do not build a second user directory in DynamoDB. The `PROFILE` item holds
> app state (quota, counters, disabled flag) and nothing else.

### 3.3 Run lifecycle

```
draft ──run──► queued ──worker picks up──► running ──┬─► succeeded   (exit 0)
                 │                                   ├─► failed      (exit ≠ 0)
                 │                                   ├─► timeout     (wall clock)
                 │                                   ├─► oom         (OOMKilled)
                 └── DLQ after 2 receives ────────►  └─► error       (infra fault)
```

Terminal statuses: `succeeded`, `failed`, `timeout`, `oom`, `error`.

**Stale-result guard.** Every run gets a `runId`. The API sets
`currentRunId = <runId>` and `status = queued` in one `UpdateItem`. The worker's
writes are all conditional on `currentRunId = :runId`. If a user presses Run
twice, the first worker's result is silently discarded instead of overwriting
the second run's output. This is the single most important correctness detail
in the whole feature — implement it in Step 13 and Step 17 and test it.

### 3.4 SQS message body

```json
{
  "schemaVersion": 1,
  "runId": "1f2e…",
  "programId": "7f9e…",
  "userSub": "a1b2c3-…",
  "language": "python",
  "codeKey": "a1b2c3-…/7f9e…/main.py",
  "outputKey": "a1b2c3-…/7f9e…/output.txt",
  "timeoutSeconds": 10,
  "submittedAt": "2026-08-06T10:12:00Z"
}
```

**Never put source code in the message body.** SQS caps at 256 KB, message
bodies surface in the console and in logs, and the S3 object is already the
source of truth.

---

## 4. API contract

Base URL: `http://localhost:8000` in local dev, injected into the frontend as
`NEXT_PUBLIC_API_BASE_URL`.

Every route below requires `Authorization: Bearer <cognito access token>`.
There are no unauthenticated routes except `GET /healthz`.

| Method | Path | Body / query | Returns |
|---|---|---|---|
| `GET` | `/healthz` | — | `{"status":"ok"}` (no auth) |
| `GET` | `/api/me` | — | `{sub, email, groups[], isAdmin, quota:{dailyQuota,runsToday,runsRemaining,disabled}}` |
| `GET` | `/api/languages` | — | `[{id:"python", label:"Python 3.12", fileName:"main.py", timeoutSeconds:10}]` |
| `GET` | `/api/programs` | — | `{items: ProgramSummary[]}` — newest first |
| `POST` | `/api/programs` | `{title, language}` | `Program` (201) — creates an empty `main.py` |
| `GET` | `/api/programs/{id}` | — | `Program & {code: string}` |
| `PUT` | `/api/programs/{id}` | `{title?, code?}` | `Program` — writes `main.py` |
| `DELETE` | `/api/programs/{id}` | — | `204` — deletes the S3 prefix and the item |
| `POST` | `/api/programs/{id}/run` | — | `{runId, status:"queued"}` (202) |
| `GET` | `/api/programs/{id}/status` | — | `{status, runId, exitCode, durationMs, updatedAt}` |
| `GET` | `/api/programs/{id}/output` | — | `{output, truncated, status}` |
| `GET` | `/api/admin/users` | `?limit&paginationToken` | `{items: AdminUser[], paginationToken?}` |
| `GET` | `/api/admin/programs` | `?limit&cursor` | `{items: AdminProgram[], cursor?}` |
| `PATCH` | `/api/admin/users/{sub}` | `{dailyQuota?, disabled?}` | `AdminUser` |
| `DELETE` | `/api/admin/programs/{sub}/{id}` | — | `204` |

### Error shape

Every non-2xx response is exactly:

```json
{ "error": { "code": "PROGRAM_NOT_FOUND", "message": "Program does not exist." } }
```

| HTTP | `code` | When |
|---|---|---|
| 400 | `INVALID_INPUT` | validation failure |
| 401 | `UNAUTHENTICATED` | missing / invalid / expired token |
| 403 | `FORBIDDEN` | not in `admins` for an admin route |
| 403 | `ACCOUNT_DISABLED` | profile `disabled` is true |
| 404 | `PROGRAM_NOT_FOUND` | not found **or owned by someone else** |
| 409 | `RUN_IN_PROGRESS` | status is already `queued` or `running` |
| 413 | `CODE_TOO_LARGE` | source over 64 KB |
| 429 | `QUOTA_EXCEEDED` | daily run quota reached |
| 500 | `INTERNAL` | anything else — never leak a stack trace |

> A program owned by another user returns **404, not 403**. 403 confirms the ID
> exists, which is an enumeration oracle.

### Validation rules

| Field | Rule |
|---|---|
| `title` | 1–120 chars after trim; reject control characters |
| `language` | must be a key in the language registry |
| `code` | ≤ 64 KB UTF-8 (`CODE_TOO_LARGE`). Enforced even though S3 has no such limit — the EKS version uses a ConfigMap, which caps at ~1 MiB, so keeping the limit now means behaviour does not change on migration |
| `programId` | must parse as a UUID before any AWS call |
| output | worker caps at 256 KB and sets `outputTruncated` |

---

## 5. Repository layout after this change

```
.
├── backend/                        # NEW — the API and the worker
│   ├── pyproject.toml
│   ├── Dockerfile.api
│   ├── Dockerfile.worker
│   ├── .env.example
│   ├── app/
│   │   ├── main.py                 # FastAPI app, CORS, error handlers
│   │   ├── config.py               # env contract (mirrors lib/env.ts)
│   │   ├── auth.py                 # Cognito JWT verification
│   │   ├── errors.py               # ApiError + handlers
│   │   ├── models.py               # pydantic request/response models
│   │   ├── languages.py            # the language registry
│   │   ├── aws.py                  # boto3 client factories
│   │   ├── repositories/
│   │   │   ├── programs.py         # DynamoDB
│   │   │   ├── profiles.py         # DynamoDB + quota
│   │   │   └── storage.py          # S3
│   │   └── routers/
│   │       ├── programs.py
│   │       ├── runs.py
│   │       ├── me.py
│   │       └── admin.py
│   ├── worker/
│   │   ├── __main__.py             # SQS long-poll loop
│   │   ├── executor.py             # the sandbox — the important file
│   │   └── results.py              # S3 + DynamoDB result writes
│   ├── runners/
│   │   └── python/
│   │       ├── Dockerfile
│   │       └── entrypoint.sh
│   ├── demos/                      # exploit scripts, one per control
│   └── tests/
├── docker-compose.yml              # NEW — api + worker
├── frontend/
│   ├── app/
│   │   ├── layout.tsx              # unchanged
│   │   └── (app)/                  # NEW route group — AuthGate lives here
│   │       ├── layout.tsx
│   │       ├── page.tsx            # /          programs list
│   │       ├── editor/page.tsx     # /editor?id=…
│   │       ├── account/page.tsx    # /account
│   │       └── admin/page.tsx      # /admin
│   ├── components/
│   │   ├── layout/AppShell.tsx     # NEW sidebar + header
│   │   ├── programs/               # NEW
│   │   └── admin/                  # NEW
│   ├── lib/
│   │   ├── api/client.ts           # NEW authed fetch wrapper
│   │   ├── api/programs.ts         # NEW
│   │   ├── api/admin.ts            # NEW
│   │   ├── hooks/                  # NEW
│   │   └── useQueryParam.ts        # NEW
│   └── types/playground.ts         # NEW shared domain types
└── infra/modules/static-site/
    ├── dynamodb.tf                 # NEW
    ├── s3-programs.tf              # NEW
    ├── sqs.tf                      # NEW
    ├── auth-groups.tf              # NEW  (Cognito admins group)
    └── iam-playground.tf           # NEW  (runtime + deploy policies)
```

**`app/page.tsx` is deleted** and replaced by `app/(app)/page.tsx`. Leaving both
is a route conflict and the build will fail.

---

## 6. The sandbox

This is the part of the project that matters. Every control below is mandatory.

| Control | `docker run` flag | Blocks | Demo script |
|---|---|---|---|
| No network | `--network none` | exfiltration, reaching the host, the EC2 metadata endpoint | `demos/04_network.py` |
| Read-only root | `--read-only` | tampering, persistence | `demos/03_write_fs.py` |
| Small writable `/tmp` | `--tmpfs /tmp:rw,size=16m,mode=1777` | filling the disk | `demos/07_disk_fill.py` |
| Non-root | `--user 65534:65534` | root-only syscalls | `demos/08_whoami.py` |
| No capabilities | `--cap-drop ALL` | chown, raw sockets, module loading | — |
| No escalation | `--security-opt no-new-privileges` | setuid escalation | — |
| Seccomp | `--security-opt seccomp=unconfined` **must NOT be used** — leave the default on | ~44 syscalls, most escape paths | — |
| Memory ceiling | `--memory 256m --memory-swap 256m` | allocation loops (kernel OOM-kills) | `demos/06_memory_bomb.py` |
| CPU ceiling | `--cpus 0.5` | starving the host | `demos/02_cpu_burn.py` |
| Process ceiling | `--pids-limit 128` | fork bombs | `demos/05_fork_bomb.py` |
| Wall clock | `timeout -s KILL` in the entrypoint **and** a `subprocess` timeout in the worker | infinite loops | `demos/02_cpu_burn.py` |
| No credentials | nothing mounted; `--env` is never populated with AWS vars | reaching AWS with the worker's identity | `demos/09_env_dump.py` |

Two more rules:

- The container is started with `-i` and the **source is piped to its stdin**.
  Nothing from the host filesystem is mounted. This sidesteps the classic
  sibling-container trap: the worker talks to the host's Docker daemon, so any
  `-v` path it passes would be resolved on the *host*, not inside the worker
  container. Piping avoids the problem entirely. The cost is that user programs
  cannot read stdin in v1 — document it.
- The worker must **never** pass `AWS_*` environment variables, `--privileged`,
  `--pid=host`, `--network=host`, or any bind mount to a runner container.

### Known local-only weakness

The worker mounts `/var/run/docker.sock`, which is root-equivalent on your
machine. Say so in `SECURITY.md`. This is exactly the weakness the Kubernetes
version removes — there, the API talks to the Kubernetes API and never to a
container runtime. Keep the note; it is the strongest argument for the
migration.

---

## 7. Build steps

### Phase A — Infrastructure

---

#### Step 1 — DynamoDB table

**Files:** `infra/modules/static-site/dynamodb.tf` (new),
`infra/modules/static-site/variables.tf`, `infra/modules/static-site/outputs.tf`

```hcl
# Single-table store for playground program metadata, user profiles and run
# quota counters. Access patterns are documented in PLAYGROUND_BUILD_PLAN.md §3.2;
# every one is a GetItem or a Query — there is no Scan anywhere in the codebase.
resource "aws_dynamodb_table" "playground" {
  provider = aws.this

  name         = "${local.name_prefix}-playground"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "gsi1pk"
    type = "S"
  }

  attribute {
    name = "gsi1sk"
    type = "S"
  }

  # Admin "every program, newest first" listing. gsi1pk is the constant
  # "PROGRAM" for program items and absent on profile items, so profiles are
  # not projected into the index at all.
  global_secondary_index {
    name            = "gsi1"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  # Dropping this table destroys every saved program. Guarded twice, matching
  # the Cognito User Pool in auth.tf.
  deletion_protection_enabled = var.playground_table_deletion_protection

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${local.name_prefix}-playground"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}
```

Add to `variables.tf`:

```hcl
variable "playground_table_deletion_protection" {
  description = "AWS-side deletion protection on the playground DynamoDB table. Keep true outside throwaway sandboxes."
  type        = bool
  default     = true
}
```

Add to module `outputs.tf`:

```hcl
output "playground_table_name" {
  description = "Name of the DynamoDB table holding playground programs and profiles."
  value       = aws_dynamodb_table.playground.name
}

output "playground_table_arn" {
  description = "ARN of the playground DynamoDB table."
  value       = aws_dynamodb_table.playground.arn
}
```

**Done when:** `terraform validate` passes in all four roots and
`terraform fmt -recursive infra/` is a no-op.

---

#### Step 2 — Programs S3 bucket

**Files:** `infra/modules/static-site/s3-programs.tf` (new),
`infra/modules/static-site/locals.tf`

Read `infra/modules/static-site/s3.tf` first and copy its structure exactly.
The bucket needs **all four companions** plus a TLS-only deny policy.

In `locals.tf`, next to `bucket_name`:

```hcl
  # Programs bucket. Derived from the site domain for the same reason the site
  # bucket is: it is already globally unique. 63-char cap is the S3 limit.
  programs_bucket_name = substr(
    "${replace(var.domain_name, ".", "-")}-programs",
    0,
    63,
  )
```

`s3-programs.tf` must contain:

| Resource | Configuration |
|---|---|
| `aws_s3_bucket.programs` | `bucket = local.programs_bucket_name`, `lifecycle { prevent_destroy = true }`, all four tags |
| `aws_s3_bucket_public_access_block.programs` | all four `block_*` = `true` |
| `aws_s3_bucket_ownership_controls.programs` | `BucketOwnerEnforced` |
| `aws_s3_bucket_versioning.programs` | `Enabled` |
| `aws_s3_bucket_server_side_encryption_configuration.programs` | `AES256`, `bucket_key_enabled = true` |
| `aws_s3_bucket_lifecycle_configuration.programs` | expire noncurrent versions after `var.programs_noncurrent_version_retention_days` (default 30) and abort incomplete multipart uploads after 7 days |
| `aws_s3_bucket_policy.programs` | a single `Deny` on `s3:*` when `aws:SecureTransport` is `false`, principal `*` — copy the TLS-only statement from `s3-policy.tf` |

Deliberately **not** configured:

- **No CORS.** The browser never touches this bucket; the API proxies every
  read and write. Adding CORS would be adding an attack surface for a client
  that does not exist.
- **No public access of any kind.**
- **No object expiry on current versions.** Saved programs are user data.

Outputs: `playground_programs_bucket_name`, `playground_programs_bucket_arn`.

**Done when:** `terraform validate` passes and `grep -c aws_s3_bucket_ s3-programs.tf`
shows the five companion resources.

---

#### Step 3 — SQS queue and dead-letter queue

**File:** `infra/modules/static-site/sqs.tf` (new)

```hcl
# Dead-letter queue. Without one, a message that crashes the worker is
# redelivered forever and quietly burns the SQS free tier.
resource "aws_sqs_queue" "playground_runs_dlq" {
  provider = aws.this

  name                      = "${local.name_prefix}-playground-runs-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
  sqs_managed_sse_enabled   = true

  tags = {
    Name        = "${local.name_prefix}-playground-runs-dlq"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

resource "aws_sqs_queue" "playground_runs" {
  provider = aws.this

  name = "${local.name_prefix}-playground-runs"

  # Must comfortably exceed the longest possible run (10s) plus image pull and
  # S3 round trips. Too low and SQS redelivers a message that is still being
  # processed, and the program runs twice.
  visibility_timeout_seconds = 90

  # A run request older than an hour is worthless — the user has left.
  message_retention_seconds = 3600

  # Long polling. A 1-second poll loop is ~2.6M ReceiveMessage calls a month
  # against a 1M free tier; 20-second long polling is ~130k and has lower
  # latency. This single attribute is the difference between $0 and a bill.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.playground_runs_dlq.arn
    maxReceiveCount     = 2
  })

  tags = {
    Name        = "${local.name_prefix}-playground-runs"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}
```

Add an `aws_sqs_queue_policy` on both queues denying every action when
`aws:SecureTransport` is `false`, mirroring the S3 TLS-only deny.

Outputs: `playground_queue_url`, `playground_queue_arn`, `playground_dlq_url`,
`playground_dlq_arn`.

**Done when:** `terraform validate` passes.

---

#### Step 4 — Cognito `admins` group

**File:** `infra/modules/static-site/auth-groups.tf` (new)

```hcl
# Membership in this group is what the API checks for every /api/admin route.
# Cognito puts it in the `cognito:groups` claim of both the ID and the access
# token, so no extra lookup is needed to authorize a request.
#
# Deliberately empty at create time. Add the first admin by hand:
#   aws cognito-idp admin-add-user-to-group \
#     --user-pool-id <pool> --username <email> --group-name admins
resource "aws_cognito_user_group" "admins" {
  provider = aws.this

  name         = "admins"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Full read/write access to every user and every program."
  precedence   = 0
}
```

Output `cognito_admins_group_name`.

**Done when:** `terraform validate` passes.

---

#### Step 5 — IAM: runtime policies for the local API and worker

**File:** `infra/modules/static-site/iam-playground.tf` (new)

Read `iam-github-oidc.tf` first — copy its `data "aws_iam_policy_document"` +
`aws_iam_policy` + `aws_iam_role_policy_attachment` + `time_sleep` pattern
exactly, including the `triggers` map keyed on the policy hash.

Create **two separate customer-managed policies**. Splitting them is the point:
it demonstrates that the component that accepts internet traffic and the
component that executes untrusted code have different, minimal grants.

**Policy A — `${local.name_prefix}-playground-api`**

| Sid | Actions | Resources |
|---|---|---|
| `PlaygroundApiTableAccess` | `dynamodb:GetItem`, `PutItem`, `UpdateItem`, `DeleteItem`, `Query` | table ARN |
| `PlaygroundApiIndexAccess` | `dynamodb:Query` | `<table ARN>/index/gsi1` |
| `PlaygroundApiObjectAccess` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `<programs bucket ARN>/*` |
| `PlaygroundApiBucketList` | `s3:ListBucket` | `<programs bucket ARN>` |
| `PlaygroundApiEnqueue` | `sqs:SendMessage`, `sqs:GetQueueUrl`, `sqs:GetQueueAttributes` | run queue ARN |
| `PlaygroundApiUserDirectory` | `cognito-idp:ListUsers`, `AdminGetUser`, `AdminDisableUser`, `AdminEnableUser`, `AdminListGroupsForUser` | user pool ARN |

**Policy B — `${local.name_prefix}-playground-worker`**

| Sid | Actions | Resources |
|---|---|---|
| `PlaygroundWorkerConsume` | `sqs:ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`, `GetQueueUrl`, `GetQueueAttributes` | run queue ARN |
| `PlaygroundWorkerReadCode` | `s3:GetObject` | `<programs bucket ARN>/*` |
| `PlaygroundWorkerWriteOutput` | `s3:PutObject` | `<programs bucket ARN>/*` |
| `PlaygroundWorkerUpdateStatus` | `dynamodb:UpdateItem`, `GetItem` | table ARN |

The worker gets **no** `sqs:SendMessage`, **no** `s3:DeleteObject`, **no**
Cognito access, and **no** `dynamodb:Query`. Note this explicitly in a comment —
it is the least-privilege story a reviewer will ask about.

Attach both to the shared local-dev role, guarded by the existing flag:

```hcl
resource "aws_iam_role_policy_attachment" "local_dev_playground_api" {
  count    = var.attach_deploy_policies_to_local_dev_role ? 1 : 0
  provider = aws.this

  role       = data.aws_iam_role.local_dev_role[0].name
  policy_arn = aws_iam_policy.playground_api.arn
}
```

…and the same for the worker policy. Add a `time_sleep` for propagation,
following the existing pattern.

> Local containers get credentials by assuming this role through an AWS profile
> — see Step 7. No static access keys are created anywhere. That keeps the
> repo's "zero standing credentials" property intact in local development.

**Done when:** `terraform validate` passes and `grep -n '"\*"' iam-playground.tf`
returns nothing (every action here is resource-scopeable).

---

#### Step 6 — IAM: extend the deploy role, then apply

**Files:** `infra/modules/static-site/iam-github-oidc.tf`,
`infra/modules/static-site/iam-playground.tf`, `infra/envs/dev/outputs.tf`

1. The GitHub deploy role cannot currently create a DynamoDB table or an SQS
   queue. Add a **new** policy document + `aws_iam_policy` +
   attachments + `time_sleep` in `iam-playground.tf` named
   `${local.name_prefix}-github-deploy-playground`, granting:

   - `dynamodb:CreateTable`, `DescribeTable`, `UpdateTable`, `DeleteTable`,
     `DescribeTimeToLive`, `UpdateTimeToLive`, `DescribeContinuousBackups`,
     `UpdateContinuousBackups`, `TagResource`, `UntagResource`,
     `ListTagsOfResource` — on the table ARN and `<table ARN>/index/*`
   - `sqs:CreateQueue`, `GetQueueAttributes`, `SetQueueAttributes`,
     `GetQueueUrl`, `TagQueue`, `UntagQueue`, `ListQueueTags`, `DeleteQueue` —
     on both queue ARNs
   - `dynamodb:ListTables` and `sqs:ListQueues` on `"*"` **with a comment**
     saying AWS offers no resource-level scope for those two list APIs

2. Add the programs bucket ARN to the existing `S3BucketManage` and
   `S3SiteObjectsAccess` statements' `resources` lists in `iam-github-oidc.tf`.
   Do not duplicate the statements.

3. Ensure `aws_dynamodb_table.playground`, both `aws_sqs_queue` resources and
   `aws_s3_bucket.programs` carry `depends_on = [time_sleep.playground_iam_propagation]`,
   matching how `aws_cognito_user_pool.this` depends on `time_sleep.iam_propagation`.

4. Re-export everything through `infra/envs/dev/outputs.tf`:
   `playground_table_name`, `playground_programs_bucket_name`,
   `playground_queue_url`, `playground_dlq_url`, `cognito_admins_group_name`.

5. Apply:

```bash
cd infra/envs/dev
terraform init -backend-config=backend.hcl
terraform fmt -recursive ../../
terraform validate
terraform plan            # must contain ZERO destroy or replace actions
terraform apply
```

6. Capture the values you will need:

```bash
terraform output -raw playground_table_name
terraform output -raw playground_programs_bucket_name
terraform output -raw playground_queue_url
terraform output -raw cognito_user_pool_id
terraform output -raw cognito_client_id
```

**Done when:** `aws dynamodb describe-table`, `aws sqs get-queue-attributes` and
`aws s3api head-bucket` all succeed against the new resources, and the plan
contained no destroys.

---

### Phase B — Backend and worker

---

#### Step 7 — Backend scaffold and local credentials

**Files:** `backend/pyproject.toml`, `backend/.env.example`,
`backend/Dockerfile.api`, `backend/Dockerfile.worker`, `docker-compose.yml`,
`.gitignore`

`backend/pyproject.toml`:

```toml
[project]
name = "playground-backend"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
  "fastapi>=0.118",
  "uvicorn[standard]>=0.38",
  "boto3>=1.40",
  "pydantic>=2.12",
  "pydantic-settings>=2.11",
  "pyjwt[crypto]>=2.10",
]

[project.optional-dependencies]
dev = ["pytest>=8.4", "pytest-asyncio>=1.2", "httpx>=0.28", "moto[s3,dynamodb,sqs]>=5.1", "ruff>=0.14", "mypy>=1.18"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "S", "RUF"]

[tool.mypy]
strict = true
```

`backend/.env.example` — **gitignore `backend/.env`**:

```bash
# Every value comes from `terraform output` in infra/envs/dev.
AWS_REGION=us-east-1
AWS_PROFILE=playground-local

COGNITO_USER_POOL_ID=
COGNITO_CLIENT_ID=

PLAYGROUND_TABLE_NAME=
PLAYGROUND_BUCKET_NAME=
PLAYGROUND_QUEUE_URL=

# Comma-separated. The frontend dev server plus, later, the CloudFront domain.
CORS_ALLOWED_ORIGINS=http://localhost:3000

DEFAULT_DAILY_QUOTA=50
MAX_CODE_BYTES=65536
MAX_OUTPUT_BYTES=262144
LOG_LEVEL=INFO
```

**Credentials.** No access keys are created. Add a profile to `~/.aws/config`
that assumes the local-dev role from Step 5:

```ini
[profile playground-local]
role_arn       = arn:aws:iam::<account-id>:role/<project>-local-dev-role
source_profile = default
region         = us-east-1
```

`~/.aws` is mounted read-only into both containers and `AWS_PROFILE` selects
this profile. Nothing long-lived lands on disk in the repo.

`backend/Dockerfile.api`:

```dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /srv
COPY pyproject.toml ./
RUN pip install --no-cache-dir .
COPY app ./app
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin api
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

`backend/Dockerfile.worker` is the same shape but copies `worker/` and `app/`,
installs the Docker CLI (`apt-get install -y --no-install-recommends
docker.io` or the static `docker` binary), and runs
`CMD ["python", "-m", "worker"]`. It must **stay root** so it can talk to the
mounted socket — note that in a comment as a known local-only weakness.

`docker-compose.yml` at the repo root:

```yaml
services:
  api:
    build:
      context: ./backend
      dockerfile: Dockerfile.api
    ports:
      - "8000:8000"
    env_file: ./backend/.env
    volumes:
      # Read-only so a compromised API cannot rewrite your AWS config.
      - ~/.aws:/home/api/.aws:ro
    environment:
      AWS_SDK_LOAD_CONFIG: "1"
    restart: unless-stopped

  worker:
    build:
      context: ./backend
      dockerfile: Dockerfile.worker
    env_file: ./backend/.env
    volumes:
      - ~/.aws:/root/.aws:ro
      # Root-equivalent on the host. Local development only — the Kubernetes
      # version talks to the Kubernetes API instead and needs no socket.
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      AWS_SDK_LOAD_CONFIG: "1"
    restart: unless-stopped
```

Add to `.gitignore`: `backend/.env`, `backend/.venv/`, `__pycache__/`,
`.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`.

**Done when:** `docker compose build` succeeds.

---

#### Step 8 — Config, errors, AWS clients, language registry

**Files:** `backend/app/config.py`, `errors.py`, `aws.py`, `languages.py`

`config.py` is the backend's equivalent of `frontend/lib/env.ts` — it fails
loudly at import time rather than shipping `None`:

```python
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="forbid")

    aws_region: str
    cognito_user_pool_id: str
    cognito_client_id: str
    playground_table_name: str
    playground_bucket_name: str
    playground_queue_url: str
    cors_allowed_origins: str = "http://localhost:3000"
    default_daily_quota: int = 50
    max_code_bytes: int = 65_536
    max_output_bytes: int = 262_144
    log_level: str = "INFO"

    @property
    def allowed_origins(self) -> list[str]:
        return [o.strip() for o in self.cors_allowed_origins.split(",") if o.strip()]

    @property
    def cognito_issuer(self) -> str:
        return f"https://cognito-idp.{self.aws_region}.amazonaws.com/{self.cognito_user_pool_id}"

    @property
    def cognito_jwks_url(self) -> str:
        return f"{self.cognito_issuer}/.well-known/jwks.json"


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
```

`errors.py`:

```python
class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
```

Register a FastAPI exception handler that renders
`{"error": {"code": ..., "message": ...}}` and a catch-all handler for
`Exception` that logs the traceback server-side and returns
`500 INTERNAL` with a fixed message. **Never** return a stack trace.

`aws.py` — module-level `boto3.client(...)` singletons for `dynamodb`
(use `boto3.resource("dynamodb").Table(...)`), `s3`, `sqs`, `cognito-idp`.
Creating a client per request costs ~50 ms.

`languages.py` — the registry. Adding a language is an entry here plus a
Dockerfile, nothing else:

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class Language:
    id: str
    label: str
    file_name: str
    image: str
    timeout_seconds: int
    starter_code: str


LANGUAGES: dict[str, Language] = {
    "python": Language(
        id="python",
        label="Python 3.12",
        file_name="main.py",
        image="playground/runner-python:3.12",
        timeout_seconds=10,
        starter_code='print("Hello from the playground")\n',
    ),
}
```

**Done when:** `python -c "from app.config import get_settings; get_settings()"`
succeeds inside the container with `.env` filled in.

---

#### Step 9 — Cognito JWT verification

**File:** `backend/app/auth.py`

This is the security boundary. Get it exactly right.

```python
import jwt
from fastapi import Depends, Request
from jwt import PyJWKClient

from app.config import Settings, get_settings
from app.errors import ApiError

_jwk_client: PyJWKClient | None = None


def _jwks(settings: Settings) -> PyJWKClient:
    global _jwk_client
    if _jwk_client is None:
        # Cached across requests. Refetching the JWKS per request adds ~200 ms
        # and will eventually get you rate-limited by Cognito.
        _jwk_client = PyJWKClient(settings.cognito_jwks_url, cache_keys=True, lifespan=3600)
    return _jwk_client


class Principal:
    def __init__(self, sub: str, groups: list[str], client_id: str) -> None:
        self.sub = sub
        self.groups = groups
        self.client_id = client_id

    @property
    def is_admin(self) -> bool:
        return "admins" in self.groups


def current_principal(
    request: Request,
    settings: Settings = Depends(get_settings),
) -> Principal:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise ApiError(401, "UNAUTHENTICATED", "Missing bearer token.")

    try:
        key = _jwks(settings).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],          # never accept `none` or HS256
            issuer=settings.cognito_issuer,
            options={"verify_aud": False}, # access tokens carry no `aud`
        )
    except jwt.PyJWTError as exc:
        raise ApiError(401, "UNAUTHENTICATED", "Invalid or expired token.") from exc

    # An ID token would also verify against this JWKS. Reject it — only the
    # access token is an authorization credential.
    if claims.get("token_use") != "access":
        raise ApiError(401, "UNAUTHENTICATED", "Wrong token type.")
    if claims.get("client_id") != settings.cognito_client_id:
        raise ApiError(401, "UNAUTHENTICATED", "Token was not issued for this client.")

    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise ApiError(401, "UNAUTHENTICATED", "Token has no subject.")

    groups = claims.get("cognito:groups") or []
    return Principal(sub=sub, groups=list(groups), client_id=claims["client_id"])


def require_admin(principal: Principal = Depends(current_principal)) -> Principal:
    if not principal.is_admin:
        raise ApiError(403, "FORBIDDEN", "Administrator access required.")
    return principal
```

Checklist for this file — all five must be present:

- [ ] signature verified against the pool JWKS
- [ ] `algorithms=["RS256"]` pinned
- [ ] `issuer` checked
- [ ] `token_use == "access"` checked
- [ ] `client_id` checked

**Done when:** `pytest tests/test_auth.py` covers: valid token, expired token,
wrong `client_id`, an ID token, an `alg: none` token, and a token signed by a
different key — all six.

---

#### Step 10 — Repositories

**Files:** `backend/app/repositories/{storage,programs,profiles}.py`

`storage.py` — S3. Key construction lives here and nowhere else:

```python
def code_key(user_sub: str, program_id: str, file_name: str) -> str:
    return f"{user_sub}/{program_id}/{file_name}"


def output_key(user_sub: str, program_id: str) -> str:
    return f"{user_sub}/{program_id}/output.txt"
```

`user_sub` always comes from the verified token, never from a request body.
Add `put_code`, `get_code`, `get_output`, `delete_program_prefix`
(list-then-`delete_objects`, paginated).

`programs.py` — DynamoDB.

> **DynamoDB reserved words.** `status`, `language`, `name` and `timestamp` are
> all reserved. Every expression touching them needs
> `ExpressionAttributeNames={"#status": "status", "#language": "language"}`.
> Forgetting this produces `ValidationException: Invalid UpdateExpression`,
> which is an unhelpful error to debug later. Use the aliases everywhere from
> the start.

Functions: `create`, `get` (returns `None` when `pk`/`sk` miss — the router
turns that into 404), `list_for_user`, `update_metadata`, `delete`,
`mark_queued`, `list_all` (GSI1, admin only).

`mark_queued` is the conditional write that makes double-runs impossible:

```python
def mark_queued(user_sub: str, program_id: str, run_id: str, now: str) -> None:
    try:
        table.update_item(
            Key={"pk": f"USER#{user_sub}", "sk": f"PROG#{program_id}"},
            UpdateExpression=(
                "SET #status = :queued, currentRunId = :run, updatedAt = :now "
                "ADD runCount :one"
            ),
            ConditionExpression=(
                "attribute_exists(pk) AND NOT #status IN (:queued, :running)"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":queued": "queued",
                ":running": "running",
                ":run": run_id,
                ":now": now,
                ":one": 1,
            },
        )
    except client.exceptions.ConditionalCheckFailedException as exc:
        raise ApiError(409, "RUN_IN_PROGRESS", "This program is already running.") from exc
```

`profiles.py` — `get_or_create`, `consume_quota`, `set_admin_fields`.

`consume_quota` is two conditional updates, in this order:

1. `SET quotaDate = :today ADD runsToday :one, runsTotal :one` with condition
   `attribute_not_exists(quotaDate) OR quotaDate <> :today` — the first run of a
   new UTC day, which also resets the counter.
2. If that fails with `ConditionalCheckFailed`, the counter is already on
   today: `ADD runsToday :one, runsTotal :one` with condition
   `runsToday < :quota`. If *that* fails, raise
   `429 QUOTA_EXCEEDED`.

Both paths must also check `disabled` and raise `403 ACCOUNT_DISABLED`.

Doing this with conditional updates rather than read-then-write is what makes
the quota hold when a user opens two tabs.

**Done when:** `pytest tests/test_repositories.py` passes against `moto`,
including a test that fires `consume_quota` past the limit and gets a 429, and
one that calls `mark_queued` twice and gets a 409.

---

#### Step 11 — Program routes

**File:** `backend/app/routers/programs.py`

Implement `GET /api/programs`, `POST /api/programs`, `GET /api/programs/{id}`,
`PUT /api/programs/{id}`, `DELETE /api/programs/{id}` per §4.

Rules that must hold in every handler:

- The DynamoDB key is built from `principal.sub`. There is no code path where
  an owner is read from the request.
- `{id}` is parsed with `uuid.UUID(program_id)` before any AWS call; a parse
  failure is `400 INVALID_INPUT`.
- A miss is `404 PROGRAM_NOT_FOUND` whether the program is absent or owned by
  someone else.
- `POST` writes the language's `starter_code` to S3 so a new program is
  immediately runnable, then writes the DynamoDB item. If the DynamoDB write
  fails, delete the S3 object before raising — do not leave an orphan.
- `PUT` rejects code over `max_code_bytes` with `413 CODE_TOO_LARGE`, measured
  on the **encoded UTF-8 bytes**, not the character count.
- `DELETE` removes the S3 prefix first, then the item. The other order leaves
  unreachable objects.

**Done when:** the full CRUD cycle works through `curl` with a real token, and
a request for another user's program ID returns 404.

---

#### Step 12 — Run route

**File:** `backend/app/routers/runs.py`

`POST /api/programs/{id}/run`, in this exact order:

```python
program = programs.get(principal.sub, program_id)      # 404 if missing
language = LANGUAGES.get(program["language"])          # 400 if unknown
profiles.consume_quota(principal.sub)                  # 403 / 429
run_id = str(uuid.uuid4())
programs.mark_queued(principal.sub, program_id, run_id, now)   # 409
try:
    sqs.send_message(QueueUrl=..., MessageBody=json.dumps(message))
except ClientError:
    programs.mark_terminal(principal.sub, program_id, run_id, status="error")
    raise ApiError(500, "INTERNAL", "Could not queue the run.")
return {"runId": run_id, "status": "queued"}
```

Quota is consumed **before** the enqueue, so a user cannot burn the queue by
racing. The status is rolled back to `error` if the enqueue fails, so the
program never sits in `queued` forever with nothing coming.

`GET /api/programs/{id}/status` is a single `GetItem` — keep it cheap, the
browser hits it once a second.

`GET /api/programs/{id}/output` reads `output.txt` from S3. A `NoSuchKey` is
not an error: return `{"output": "", "truncated": false, "status": <status>}`.
That is the normal state of a program that has never run.

**Done when:** `POST …/run` returns 202, the message is visible with
`aws sqs receive-message`, and a second immediate `POST` returns 409.

---

#### Step 13 — Admin routes

**File:** `backend/app/routers/admin.py`

Every route depends on `require_admin`.

- `GET /api/admin/users` → `cognito_idp.list_users(UserPoolId=…, Limit=…)`,
  passing `PaginationToken` through. For each returned user, `GetItem` its
  `PROFILE` row and merge in `runsToday`, `runsTotal`, `dailyQuota`,
  `disabled`. Return `sub`, `email`, `status`, `enabled`, `createdAt` from
  Cognito. **Cognito is the user directory; DynamoDB only decorates it.**
- `GET /api/admin/programs` → `Query` on `gsi1` with `gsi1pk = "PROGRAM"`,
  `ScanIndexForward=False`, `Limit`, and `LastEvaluatedKey` round-tripped as an
  opaque base64 `cursor`. **No `Scan`, ever.**
- `PATCH /api/admin/users/{sub}` → updates `dailyQuota` and/or `disabled` on
  the `PROFILE` item. When `disabled` is set true, also call
  `cognito_idp.admin_disable_user` so the account cannot sign in at all.
- `DELETE /api/admin/programs/{sub}/{id}` → same delete path as Step 11, but
  the owner comes from the URL rather than the token.

**Done when:** a non-admin token gets 403 on every one of these, and an admin
token lists both users and programs.

---

#### Step 14 — FastAPI app assembly

**File:** `backend/app/main.py`

```python
app = FastAPI(title="Playground API", docs_url=None, redoc_url=None, openapi_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=get_settings().allowed_origins,  # explicit list, never "*"
    allow_credentials=False,                       # we use a bearer header, not cookies
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
    max_age=600,
)
```

`allow_origins=["*"]` combined with a bearer token is a real vulnerability —
any site could read responses on the user's behalf. Keep the explicit list.

Interactive docs are disabled because this service is reachable from a browser
origin and has no reason to publish a schema.

Register the exception handlers from Step 8, mount the four routers, and add
`GET /healthz` outside the auth dependency.

**Done when:** `curl localhost:8000/healthz` returns `{"status":"ok"}` and
`curl localhost:8000/api/programs` without a token returns 401 with the
`{"error":{...}}` shape.

---

#### Step 15 — The Python runner image

**Files:** `backend/runners/python/Dockerfile`, `entrypoint.sh`

```dockerfile
FROM python:3.12-alpine

# The image ships no package manager and no shell utilities beyond busybox.
# Alpine already defines uid 65534 as `nobody`, so do NOT `adduser -u 65534` —
# it fails with "uid 65534 already in use".
RUN rm -f /sbin/apk /usr/bin/apk

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0555 /usr/local/bin/entrypoint.sh

USER 65534:65534
WORKDIR /tmp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

`entrypoint.sh`:

```sh
#!/bin/sh
# The source arrives on stdin, not as a mounted file. The worker talks to the
# host's Docker daemon, so any -v path it passed would resolve on the HOST, not
# inside the worker container. Piping avoids that class of bug entirely.
#
# Consequence: user programs cannot read stdin in v1. Documented in the README.
set -eu
umask 077
cat > /tmp/main.py

# Belt: the control plane's own wall clock. Braces: the worker also enforces a
# subprocess timeout. Either alone is enough; both is cheap.
exec timeout -s KILL "${RUN_TIMEOUT_SECONDS:-8}" python3 -u /tmp/main.py
```

Build it, and add a `make runners` target:

```bash
docker build -t playground/runner-python:3.12 backend/runners/python
```

**Done when:**

```bash
echo 'print("hi")' | docker run -i --rm --network none --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m,mode=1777 \
  --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
  --memory 256m --memory-swap 256m --cpus 0.5 --pids-limit 128 \
  playground/runner-python:3.12
```

prints `hi`.

---

#### Step 16 — The sandbox executor

**File:** `backend/worker/executor.py`

Build this **one flag at a time**. For each flag, first write the matching
script in `backend/demos/`, run it and watch it succeed, then add the flag and
watch it fail. Those before/after pairs are the project's best documentation
and cost nothing extra to produce.

```python
DOCKER_FLAGS = [
    "--network", "none",
    "--read-only",
    "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
    "--user", "65534:65534",
    "--cap-drop", "ALL",
    "--security-opt", "no-new-privileges",
    "--memory", "256m",
    "--memory-swap", "256m",   # equal to --memory disables swap entirely
    "--cpus", "0.5",
    "--pids-limit", "128",
]


def execute(code: bytes, language: Language, run_id: str) -> RunResult:
    name = f"pgrun-{run_id}"
    cmd = [
        "docker", "run", "-i", "--name", name,
        *DOCKER_FLAGS,
        "--env", f"RUN_TIMEOUT_SECONDS={language.timeout_seconds}",
        language.image,
    ]
    started = time.monotonic()
    timed_out = False
    try:
        proc = subprocess.run(          # noqa: S603 - fixed argv, no shell
            cmd,
            input=code,
            capture_output=True,
            timeout=language.timeout_seconds + 5,
            check=False,
        )
        stdout, stderr, exit_code = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        stdout = exc.stdout or b""
        stderr = exc.stderr or b""
        exit_code = 124
        subprocess.run(["docker", "kill", name], capture_output=True, check=False)
    finally:
        oom = _inspect_oom(name)
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)

    elapsed_ms = int((time.monotonic() - started) * 1000)
    return RunResult(
        status=_classify(exit_code, timed_out, oom, elapsed_ms, language),
        exit_code=exit_code,
        duration_ms=elapsed_ms,
        output=_combine(stdout, stderr),
    )
```

`_inspect_oom` runs
`docker inspect -f '{{.State.OOMKilled}}' <name>` before removal — this is why
the container is created with `--name` and removed explicitly instead of using
`--rm`. Without it, an out-of-memory kill and a timeout are indistinguishable
(both exit 137) and the memory-limit demo loses its punchline.

`_classify`:

| Condition | Status |
|---|---|
| `oom` is true | `oom` |
| `timed_out`, or `exit_code == 137` and `elapsed_ms >= timeout_seconds * 1000` | `timeout` |
| `exit_code == 0` | `succeeded` |
| otherwise | `failed` |

`_combine` concatenates stdout, then stderr under a
`--- stderr ---` separator when stderr is non-empty, decodes as UTF-8 with
`errors="replace"`, and truncates at `max_output_bytes`, returning a
`truncated` flag. Truncate on **bytes**, then decode, or a multi-byte character
split at the boundary raises.

Absolute rules for this file:

- The argv list is fixed; **never** build the command with a shell string or
  interpolate anything user-controlled into it.
- Never pass `AWS_*` into `--env`, never `-v`, never `--privileged`,
  never `--network host`, never `--pid host`.

**Done when:** all of `backend/demos/` behave as the §6 table says, and
`pytest tests/test_sandbox.py` asserts it. That test suite is the deliverable
of this step, not a nice-to-have.

---

#### Step 17 — The worker loop

**Files:** `backend/worker/__main__.py`, `backend/worker/results.py`

```python
while not shutting_down:
    resp = sqs.receive_message(
        QueueUrl=settings.playground_queue_url,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=20,       # long polling — see Step 3
        VisibilityTimeout=90,
    )
    for message in resp.get("Messages", []):
        handle(message)
```

`handle` must:

1. Parse the body; on a malformed message log it and **delete** it — a message
   that can never be parsed will otherwise bounce to the DLQ and then sit there.
2. Claim the run with a conditional `UpdateItem`:
   `SET #status = :running` with
   `ConditionExpression="currentRunId = :run AND #status = :queued"`.
   On `ConditionalCheckFailedException`, this is a redelivery or a superseded
   run — log, delete the message, return. **Do not execute.**
3. `GET` the code from S3.
4. Call `executor.execute`.
5. `PUT` the output to `outputKey`, `ContentType="text/plain; charset=utf-8"`.
6. Write the terminal status with `ConditionExpression="currentRunId = :run"`,
   setting `status`, `lastExitCode`, `lastDurationMs`, `lastRunAt`,
   `outputTruncated`.
7. `DeleteMessage`.

Any unexpected exception in steps 3–6: write status `error` (still conditional
on `currentRunId`), then delete the message. Leaving it on the queue means the
same crash twice more and then a DLQ entry, while the user's UI polls forever.

Also implement:

- **SIGTERM handling** — finish the in-flight run, then exit, so
  `docker compose down` does not orphan a container.
- **Structured logging** — one JSON line per run with `runId`, `programId`,
  `status`, `durationMs`. Never log the source code or the output.
- **Startup image pre-pull** — `docker image inspect` each registry image and
  build/pull if missing, or the first run of the day takes 20 seconds and looks
  broken.

**Done when:** `docker compose up`, then a run submitted through the API
produces `output.txt` in S3 and a terminal status in DynamoDB, and stopping the
worker mid-run and restarting it does not double-execute.

---

#### Step 18 — Backend tests

**File:** `backend/tests/`

| File | Covers |
|---|---|
| `test_auth.py` | the six token cases from Step 9 |
| `test_repositories.py` | quota exhaustion, daily reset, `mark_queued` double-call, reserved-word expressions |
| `test_programs_api.py` | CRUD, cross-user 404, 413 on oversized code |
| `test_runs_api.py` | 202 → queued, 409 on double run, 429 at quota |
| `test_admin_api.py` | 403 for non-admin on all four routes |
| `test_sandbox.py` | one assertion per row of the §6 table |

Use `moto` for S3/DynamoDB/SQS. `test_sandbox.py` needs a real Docker daemon —
mark it `@pytest.mark.integration` and skip it when `DOCKER_HOST` is
unreachable so `pytest` still passes on a machine without Docker.

**Done when:** `pytest` is green and `ruff check` and `mypy --strict` are clean.

---

### Phase C — Frontend

> Read `frontend/components/layout/AuthGate.tsx` before writing any page. Two
> hard-won constraints are documented in its comments and both apply to every
> component you are about to write:
>
> 1. **Never use `useSearchParams`.** It forces a Suspense boundary that has to
>    re-resolve during static export, and with no server to stream a resolution
>    to, hydration dies with React error #412. Read
>    `window.location.search` in a `useState` lazy initializer instead.
> 2. **Defer auth-dependent rendering until after hydration.** Amplify resolves
>    cached sessions client-side only, so the first paint must match the server
>    HTML. Follow the `useSyncExternalStore` pattern already in `AuthGate`.

---

#### Step 19 — Dependencies, env contract, shared types

**Files:** `frontend/package.json`, `frontend/lib/env.ts`,
`frontend/.env.example`, `frontend/types/playground.ts`,
`.github/workflows/deploy.yml`

```bash
cd frontend
npm i @uiw/react-codemirror @codemirror/lang-python @codemirror/theme-one-dark
npx shadcn@latest add card input label select table badge skeleton dialog
```

Add to `lib/env.ts`, following the existing literal-property-access pattern
exactly — `process.env[name]` is not substituted by the compiler and would
always be `undefined` in the browser bundle:

```ts
export type PublicEnv = {
  readonly region: string;
  readonly userPoolId: string;
  readonly userPoolClientId: string;
  readonly apiBaseUrl: string;
};

const apiBaseUrl = required(
  "NEXT_PUBLIC_API_BASE_URL",
  process.env.NEXT_PUBLIC_API_BASE_URL,
);
```

Add `NEXT_PUBLIC_API_BASE_URL=http://localhost:8000` to `.env.example` with a
comment noting it is not a secret, and add it to the frontend build step's
`env:` block in `.github/workflows/deploy.yml` alongside the three Cognito
values (around line 371).

`frontend/types/playground.ts` — shared domain types live in `types/`, never
inline in a component (`CLAUDE.md` §5):

```ts
export type RunStatus =
  | "draft" | "queued" | "running"
  | "succeeded" | "failed" | "timeout" | "oom" | "error";

export const TERMINAL_STATUSES = [
  "succeeded", "failed", "timeout", "oom", "error",
] as const satisfies readonly RunStatus[];

export type ProgramSummary = {
  programId: string;
  title: string;
  language: string;
  status: RunStatus;
  lastRunAt: string | null;
  lastExitCode: number | null;
  lastDurationMs: number | null;
  runCount: number;
  createdAt: string;
  updatedAt: string;
};

export type Program = ProgramSummary & { code: string };

export type RunStatusResponse = {
  status: RunStatus;
  runId: string | null;
  exitCode: number | null;
  durationMs: number | null;
  updatedAt: string;
};

export type OutputResponse = {
  output: string;
  truncated: boolean;
  status: RunStatus;
};

export type Me = {
  sub: string;
  email: string;
  groups: readonly string[];
  isAdmin: boolean;
  quota: {
    dailyQuota: number;
    runsToday: number;
    runsRemaining: number;
    disabled: boolean;
  };
};
```

**Done when:** `npm run typecheck` and `npm run build` both pass — the build
will fail loudly if the new env var is missing, which is the point.

---

#### Step 20 — API client

**Files:** `frontend/lib/api/client.ts`, `programs.ts`, `admin.ts`

```ts
"use client";

import { fetchAuthSession } from "aws-amplify/auth";
import { env } from "@/lib/env";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

type ErrorBody = { error?: { code?: string; message?: string } };

export async function apiRequest<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  // Always the ACCESS token. The ID token is an identity assertion, not an
  // authorization credential, and the API rejects it (see backend app/auth.py).
  const session = await fetchAuthSession();
  const token = session.tokens?.accessToken?.toString();
  if (token === undefined) {
    throw new ApiError(401, "UNAUTHENTICATED", "Your session has expired.");
  }

  const response = await fetch(`${env.apiBaseUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init.headers,
      Authorization: `Bearer ${token}`,
    },
  });

  if (response.status === 204) {
    return undefined as T;
  }

  const body: unknown = await response.json().catch(() => ({}));

  if (!response.ok) {
    const parsed = body as ErrorBody;
    throw new ApiError(
      response.status,
      parsed.error?.code ?? "INTERNAL",
      parsed.error?.message ?? "Something went wrong.",
    );
  }

  return body as T;
}
```

`programs.ts` and `admin.ts` are thin typed wrappers: `listPrograms`,
`createProgram`, `getProgram`, `saveProgram`, `deleteProgram`, `runProgram`,
`getRunStatus`, `getOutput`, `getMe`; and `listUsers`, `listAllPrograms`,
`patchUser`, `adminDeleteProgram`.

No `any` anywhere. Narrow `unknown` explicitly (`CLAUDE.md` §5).

---

#### Step 21 — Hooks

**Files:** `frontend/lib/useQueryParam.ts`, `frontend/lib/hooks/*`

`useQueryParam.ts` — the `useSearchParams` replacement:

```ts
"use client";

import { useState } from "react";

/**
 * Read a query parameter once, on the client, without `useSearchParams`.
 *
 * `useSearchParams` forces a Suspense boundary that must re-resolve during
 * static export; with no server to stream a resolution to, hydration fails
 * with React error #412. See the same note in AuthGate.tsx.
 */
export function useQueryParam(name: string): string | null {
  const [value] = useState<string | null>(() => {
    if (typeof window === "undefined") return null;
    return new URLSearchParams(window.location.search).get(name);
  });
  return value;
}
```

`useRunPolling.ts` — the run loop:

```
run()  → POST /run
       → setStatus("queued")
       → poll GET /status every 1000 ms
       → stop when status ∈ TERMINAL_STATUSES
       → then GET /output once, and only once
       → give up after 90 s with a "still running" message
```

Requirements:

- Clear the interval in the `useEffect` cleanup, and abort the in-flight
  request on unmount — otherwise navigating away mid-run leaks a timer and
  React logs a state-update-after-unmount warning.
- Use `setTimeout` chained after each response rather than `setInterval`, so a
  slow response cannot stack up requests.
- Surface `ApiError` codes to the UI: `QUOTA_EXCEEDED` → "Daily run limit
  reached", `RUN_IN_PROGRESS` → "Already running", `ACCOUNT_DISABLED` →
  "Your account has been disabled".

Also add `usePrograms` (list + refresh) and `useMe` (fetches `/api/me` once;
this is the source of truth for `isAdmin` in the UI).

---

#### Step 22 — Route group and app shell

**Files:** `frontend/app/(app)/layout.tsx`, `frontend/components/layout/AppShell.tsx`;
**delete** `frontend/app/page.tsx`

`app/page.tsx` and `app/(app)/page.tsx` both resolve to `/`. Leaving both is a
route conflict and the build fails. Delete the old one; keep
`components/home/SignedInHome.tsx` as a reference or delete it too.

`app/(app)/layout.tsx`:

```tsx
import AuthGate from "@/components/layout/AuthGate";
import AppShell from "@/components/layout/AppShell";

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <AuthGate>
      <AppShell>{children}</AppShell>
    </AuthGate>
  );
}
```

`AppShell` is a client component: a left sidebar with `next/link` entries for
**Programs** (`/`), **Account** (`/account`) and — only when `useMe().isAdmin` —
**Admin** (`/admin`), plus a header with the user's initials (reuse
`parseUser`) and a sign-out button.

> Hiding the Admin link is a convenience, not a control. The API verifies
> `cognito:groups` on every admin request independently. Put that sentence in a
> comment above the conditional so nobody later mistakes it for the security
> boundary.

Styling: shadcn primitives from `components/ui/`, Tailwind utilities only,
colors from the `--nord-*` tokens in `app/globals.css`. Do not introduce hex
values in components; add a token if you need a new color.

---

#### Step 23 — Programs list

**Files:** `frontend/app/(app)/page.tsx`,
`frontend/components/programs/{ProgramList,ProgramCard,NewProgramDialog,StatusBadge}.tsx`

The landing page after sign-in. Requirements:

- Fetch `GET /api/programs` on mount; render a `Skeleton` grid while loading.
- Each row/card: title, language, `StatusBadge`, relative last-run time, run
  count, and buttons for **Open** (`/editor?id=<programId>`) and **Delete**
  (with a confirm `Dialog`).
- Empty state: a short line plus the same **New program** button, not a bare
  empty table.
- **New program** opens a dialog with a title `Input` and a language `Select`
  populated from `GET /api/languages`. On submit, `POST /api/programs`, then
  navigate straight to `/editor?id=<newId>`.
- `StatusBadge` maps status → token: `succeeded` green, `failed`/`error` red,
  `timeout`/`oom` amber, `queued`/`running` a pulsing neutral, `draft` muted.

---

#### Step 24 — Editor page

**Files:** `frontend/app/(app)/editor/page.tsx`,
`frontend/components/programs/{CodeEditor,OutputPane,RunButton}.tsx`

The core screen. Layout: title + language on top, editor on the left, output
pane on the right (stacked on narrow screens).

CodeMirror must be lazy-loaded and client-only (`CLAUDE.md` §5):

```tsx
const CodeEditor = dynamic(() => import("@/components/programs/CodeEditor"), {
  ssr: false,
  loading: () => <Skeleton className="h-[60vh] w-full" />,
});
```

Behaviour:

1. `const programId = useQueryParam("id")` — if null, render a "program not
   found" state with a link back to `/`. Do **not** create a dynamic route
   segment; static export cannot generate one without knowing every ID.
2. Load `GET /api/programs/{id}` into editor state.
3. **Save** (`PUT`) — explicit button plus autosave debounced at 1500 ms after
   the last keystroke. Show a small "Saved · 12:04" marker.
4. **Run** — save first if the buffer is dirty, then `POST …/run`. Disable the
   button while status is `queued` or `running` and show a spinner.
5. `OutputPane` renders monospace (`--font-geist-mono`) text, preserving
   whitespace. Header shows the terminal status, exit code and duration
   (`succeeded · exit 0 · 842 ms`). When `truncated`, show a banner:
   "Output truncated at 256 KB."
6. On `QUOTA_EXCEEDED`, disable Run and show remaining quota from `useMe`.

Accessibility: the Run button needs an `aria-busy` while running, and the
output pane an `aria-live="polite"` so a screen reader announces completion.

---

#### Step 25 — Account page

**File:** `frontend/app/(app)/account/page.tsx`

Reads `GET /api/me`. Shows email, `sub` (in a muted monospace line), group
membership, and a quota card: `runsToday / dailyQuota`, runs remaining, and a
`Progress`-style bar. Include a sign-out button. Nothing here is editable by
the user — quota is an admin field.

---

#### Step 26 — Admin panel

**Files:** `frontend/app/(app)/admin/page.tsx`,
`frontend/components/admin/{UsersTable,ProgramsTable,EditQuotaDialog}.tsx`

Two tabs.

**Users** — `GET /api/admin/users`. Columns: email, status (Cognito
`UserStatus`), enabled, runs today, runs total, daily quota, created. Row
actions: **Edit quota** (dialog → `PATCH`) and **Disable / Enable** (→ `PATCH`
`{disabled}`, with a confirm dialog for disabling). Paginate with the
`paginationToken` from the API — a "Load more" button is sufficient.

**Programs** — `GET /api/admin/programs`. Columns: title, owner email,
language, status, last run, runs. Actions: **Open** (`/editor?id=…` — note
this only works for the admin's own programs in v1; for others show a
read-only detail dialog instead) and **Delete** (→
`DELETE /api/admin/programs/{sub}/{id}`, confirm dialog).

Guard the page itself: `useMe()` → if `!isAdmin`, render a 403 state rather
than the tables. Again, this is UX; the API is the control.

---

#### Step 27 — Frontend checks

```bash
cd frontend
npm run lint
npm run typecheck
npm run test
npm run format:check
npm run build          # static export to out/ — must pass
```

Verify against `CLAUDE.md` §7 "Frontend changes":

- [ ] no `any` anywhere in the new code
- [ ] no hardcoded API URLs — everything through `lib/env.ts`
- [ ] no JWT or token written to `localStorage` / `sessionStorage`
- [ ] no `useSearchParams` in any new file
- [ ] auth-dependent UI defers until after hydration
- [ ] no `pages/` directory created
- [ ] every new color is a `--nord-*` token, not a hex literal

---

#### Step 28 — Documentation and CI

**Files:** `CLAUDE.md`, `README.md`, `SECURITY.md`, `.github/workflows/ci.yml`,
`scripts/pre-commit-check.sh`

1. **`CLAUDE.md`** — the template's own contract now describes an app that has
   a backend. Update:
   - §1 architecture diagram and the "No server by default" principle — it is
     no longer true, and leaving it will mislead the next agent.
   - §2 repository structure: add `backend/` and its boundary rule
     (*application logic lives in `frontend/` and `backend/`; infrastructure
     lives in `infra/`*).
   - §3 tech stack: add the Python row.
   - §4 commands: `docker compose up`, `make runners`, `pytest`.
   - §6 file-per-concern table: add `dynamodb.tf`, `s3-programs.tf`, `sqs.tf`,
     `auth-groups.tf`, `iam-playground.tf`.
   - §7: add a "Backend changes" checklist (`ruff`, `mypy --strict`, `pytest`,
     no `"*"` in new IAM, no AWS env passed to a runner container).
2. **`README.md`** — replace "There is no backend API" with the new
   architecture, and document the six demos with their before/after behaviour.
3. **`SECURITY.md`** — add the sandbox model, and state plainly that the worker
   mounts the Docker socket and is therefore root-equivalent on the host in
   local development.
4. **`ci.yml`** — add a `backend` job: `ruff check`, `mypy --strict`,
   `pytest -m "not integration"`. Pin every new action to a full commit SHA
   with a trailing version comment, per `CLAUDE.md` §7.
5. **`scripts/pre-commit-check.sh`** — add the backend lint/type/test run so the
   local hook still mirrors CI.

---

## 8. Acceptance test

Run this end to end before calling the feature done.

```bash
# 0. Build the runner image and start the stack.
docker build -t playground/runner-python:3.12 backend/runners/python
docker compose up --build -d
curl -s localhost:8000/healthz            # {"status":"ok"}

# 1. Frontend.
cd frontend && npm run dev                # http://localhost:3000
```

| # | Action | Expected |
|---|---|---|
| 1 | Sign up, confirm the emailed code, sign in | lands on `/` with an empty-state |
| 2 | New program "Hello", language Python | redirected to `/editor?id=…`, starter code present |
| 3 | Run | status `queued` → `running` → `succeeded`, output `Hello from the playground`, exit 0, duration shown |
| 4 | Check S3 | `<sub>/<id>/main.py` and `<sub>/<id>/output.txt` both exist |
| 5 | Back to `/` | the program is listed with a green badge and run count 1 |
| 6 | `while True: pass` → Run | after ~10 s: status `timeout`; the UI stays responsive throughout; open a second tab mid-run to prove it |
| 7 | `open("/etc/passwd","w")` | `failed`, output shows `Read-only file system` |
| 8 | `import urllib.request; urllib.request.urlopen("https://example.com")` | `failed`, DNS/connection error |
| 9 | `x = "a" * (10**10)` | `oom` (not `failed`) — proves the `docker inspect` step works |
| 10 | `import os; print(os.getuid())` | prints `65534` |
| 11 | `import os; print([k for k in os.environ if "AWS" in k])` | prints `[]` |
| 12 | Press Run twice quickly | second request returns 409, first result is not clobbered |
| 13 | Exhaust the daily quota | Run disabled, `QUOTA_EXCEEDED` message |
| 14 | Sign in as a second user | sees none of the first user's programs |
| 15 | Call `GET /api/programs/<other-user-id>` with user B's token | 404, not 403 |
| 16 | Visit `/admin` as a non-admin | 403 state; `curl` the admin API directly → 403 |
| 17 | `aws cognito-idp admin-add-user-to-group … --group-name admins`, sign out, sign back in | Admin link appears, both tables populate |
| 18 | Admin: set user B's quota to 0, disable user B | user B's next run is rejected; sign-in blocked |
| 19 | `docker compose stop worker`, run a program, `docker compose start worker` | the queued run is picked up and completes |
| 20 | Delete a program | S3 prefix and DynamoDB item both gone |

Steps 6–11 are the demo reel. Record them.

---

## 9. Gotchas

These will each cost an hour if you meet them cold.

**AWS**

- **SQS visibility timeout vs. run duration.** A 10-second job under a
  30-second visibility timeout is fine until an image pull pushes it past 30 —
  then SQS redelivers and the program runs twice. 90 seconds plus the
  `currentRunId` conditional write is the belt-and-braces fix.
- **A tight poll loop burns the free tier.** `ReceiveMessage` every second is
  ~2.6M calls a month against a 1M free tier. `WaitTimeSeconds=20` is ~130k.
- **DynamoDB reserved words.** `status`, `language`, `name` and `timestamp`
  need `ExpressionAttributeNames` in every expression.
- **`ConditionalCheckFailedException` is control flow, not an error.** Catch it
  specifically; do not let it fall into a generic `ClientError` handler.
- **Set a $5 AWS budget alarm** before the first run.

**Docker**

- **Sibling-container paths.** The worker's `-v` paths resolve on the *host*.
  This is why the source is piped to stdin. Do not "fix" it by adding a mount.
- **`adduser -u 65534` fails on Alpine** — `nobody` already owns that uid. Just
  `USER 65534:65534`.
- **`--rm` hides the OOM flag.** Name the container, `docker inspect` it, then
  remove it.
- **Exit code 137 is ambiguous** — SIGKILL from either the timeout or the OOM
  killer. The `inspect` result disambiguates.
- **Pre-pull runner images at worker startup** or the first run takes 20 s.

**Next.js static export**

- **No dynamic segments.** `/editor?id=…`, never `/editor/[id]`.
- **No `useSearchParams`.** React #412 on hydration. Use the `useQueryParam`
  helper.
- **`app/page.tsx` and `app/(app)/page.tsx` conflict.** Delete the old one.
- **`next/dynamic` with `ssr: false`** only inside a `"use client"` component.
- **A missing `NEXT_PUBLIC_API_BASE_URL` fails the build**, by design.

**Auth**

- **Use the access token, not the ID token.** The API rejects `token_use: id`.
- **Group changes need a fresh token.** After `admin-add-user-to-group` the
  user must sign out and back in — the claim is baked into the issued token.
- **CORS `*` plus a bearer token is a vulnerability.** Keep the explicit
  origin list.

---

## 10. What changes when the worker moves to Kubernetes

Written now so the seams stay honest. Nothing in this section is built yet.

| Component | Fate |
|---|---|
| Frontend, in full | unchanged |
| API HTTP contract | unchanged |
| DynamoDB model | unchanged |
| S3 layout | unchanged — and better than the `pods/log` design, which loses output when the Job is garbage-collected |
| Cognito auth, quota, admin panel | unchanged |
| `languages.py` registry | becomes a ConfigMap, same content |
| Runner image + entrypoint | unchanged, except the source arrives as a mounted ConfigMap instead of stdin — which also restores stdin for user programs |
| Sandbox flags | become `securityContext` + `NetworkPolicy` + `resources.limits`, per the §6 table |
| **SQS queue** | **deleted** — the Kubernetes API is the queue |
| **`worker/__main__.py`** | **deleted** — the API creates a Job directly |
| `worker/executor.py` | its logic becomes the Job's podSpec |
| Docker socket mount | **deleted** — this is the main security win |

Roughly 150 lines are discarded. Everything else is banked. Two controls have
no local equivalent and only become demonstrable after the move:
`automountServiceAccountToken: false` and `backoffLimit: 0`.

To keep that promise cheap, define the dispatch boundary as a Protocol in
Step 12 rather than calling `sqs.send_message` inline:

```python
class RunDispatcher(Protocol):
    def submit(self, message: RunMessage) -> None: ...
```

`SqsDispatcher` implements it today; `KubernetesJobDispatcher` implements it
later. If the seam is honest, that swap touches one module and no route.
