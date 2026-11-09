# Code Ignite

A Next.js + Cognito app template on AWS that has grown one real feature on
top of its "no server by default" base: an authenticated, sandboxed
code-execution playground. Sign in with Cognito, pick a language, and run
untrusted code inside a locked-down, ephemeral Docker container — Python,
JavaScript, TypeScript, Go, and Rust today. Hosting is S3 + CloudFront,
identity is a Cognito User Pool, the playground's API is a Lambda behind the
same CloudFront distribution, and the worker that actually executes code
deliberately never runs inside AWS. Infrastructure is Terraform; deployment
is GitHub Actions over OIDC with no long-lived AWS keys.

## Architecture

```
Browser (Next.js static export)
  |  Cognito sign-up / sign-in  (AWS Amplify)
  v
Cognito User Pool
  ^
  |  pool + client IDs baked into the bundle at build time
  |
CloudFront
  |-- default behavior --------> S3 (private, OAC)        static site
  '-- /runs*, /healthz --------> Lambda Function URL       code-playground API
                                    (OAC-protected)         verifies the
                                        |                   Cognito token
                                        v
                     SQS runs queue (+ DLQ)   <---->   S3 jobs bucket
                     {job_id}                          input.json / result.json
                                        ^
                                        |  long-poll receive, get/put
                                        |
                     worker  —  never runs in AWS
                     (your machine, or your own k8s cluster: infra/k8s/worker/)
                     python -m codeignite.worker  ->  LocalDockerRunner
                                        |
                                        v
                     docker run --network none --read-only --user 65534 ...
                     one pinned image per language (python / node / golang / rust)
```

## What you get

| Layer | What is provisioned |
|---|---|
| Hosting | Private S3 bucket + CloudFront distribution + OAC + `nextjs-url-rewrite` function |
| Security headers | CloudFront response headers policy: HSTS (preload), frame/MIME/referrer controls, Permissions-Policy. No CSP — see SECURITY.md |
| DNS / TLS | Route 53 A + AAAA alias records, ACM wildcard certificate (looked up, not managed) |
| Identity | Cognito User Pool + public SPA app client — email sign-up, optional TOTP MFA, optional threat protection, short token lifetimes |
| Code playground API | Zip-packaged Lambda (FastAPI via Mangum) behind the same CloudFront distribution at `/runs*` and `/healthz`, through an OAC-protected Function URL — no ECR, no persistent server |
| Run pipeline | SQS runs queue + dead-letter queue, a private S3 jobs bucket, and the scoped runtime IAM the API and the worker each need |
| Sandboxed execution | A locked-down, ephemeral `docker run` per job — no network, read-only root filesystem, memory/CPU limits, non-root user, hard timeout. The worker that runs it deliberately never runs inside AWS |
| Observability | CloudFront standard access logs and S3 server access logs, with lifecycle expiry |
| Protection | Optional WAF (AWS managed rules + per-IP rate limit), `prevent_destroy` and deletion protection on stateful resources |
| CI/CD | GitHub OIDC provider, per-environment deploy roles, scoped managed policies, SHA-pinned actions, path-based frontend/backend/infra change detection |
| State | S3 remote state with native lockfile locking, versioned and TLS-only |

## Supported languages

The code playground (`backend/` + `frontend/components/playground/`) runs
submitted code inside a locked-down, ephemeral Docker container per
language. The registry lives in
[`backend/src/codeignite/domain/languages.py`](backend/src/codeignite/domain/languages.py)
and pins each image by digest; the playground UI's dropdown
(`frontend/types/runs.ts`) is kept in sync with it by hand.

| Language | Version | Base image |
|---|---|---|
| Python | 3.12 | `python:3.12-alpine` |
| JavaScript (Node.js) | 22 | `node:22-alpine` |
| TypeScript | Node 22's `--experimental-strip-types` (type stripping, not type-checked) | `node:22-alpine` |
| Go | 1.27 | `golang:1.27-alpine` |
| Rust | 1.98 | `rust:1.98` |

Adding a language means one new entry in `LANGUAGES`
(`languages.py`) and one in `SUPPORTED_LANGUAGES`
(`frontend/types/runs.ts`), then re-running
`backend/scripts/pull-images.sh` to pre-pull its image.

## How the code playground works

`POST /runs` verifies the caller's Cognito access token, rate-limits on its
`sub`, writes `{code, language, user_sub}` to
`jobs/{job_id}/input.json` in the jobs S3 bucket, sends `{job_id}` to the SQS
runs queue, and returns `202 {job_id}` immediately. A separate worker
process — never the API — long-polls that queue, pulls the job, executes it,
and writes `jobs/{job_id}/result.json` back to S3. `GET /runs/{job_id}`
returns `202 {"status":"pending"}` until that result exists, then `200` with
`{stdout, stderr, exit_code, duration_ms, status, truncated}`; the playground
UI polls this every few hundred milliseconds and gives up after 60 seconds.

Execution itself happens behind a single `Runner` protocol, so nothing else
in the system knows what sits underneath it. Today that's
`LocalDockerRunner`, which shells out to `docker run` with flags chosen to
map almost one-to-one onto Kubernetes Job fields, so a future
`KubernetesJobRunner` is a mechanical swap rather than a rewrite:

| Docker flag | What it does | Kubernetes equivalent |
|---|---|---|
| `--network none` | No network access from inside the sandbox | NetworkPolicy (deny all) |
| `--memory 256m --cpus 0.5` | Hard resource ceiling | `resources.limits` |
| `--read-only --tmpfs /tmp` | Root filesystem read-only; one writable scratch dir | `readOnlyRootFilesystem: true` |
| `--user 65534` | Runs as an unprivileged, non-root UID | `securityContext.runAsUser` |
| `timeout N` | Hard wall-clock limit (`CODEIGNITE_MAX_EXECUTION_SECONDS`) | `activeDeadlineSeconds` |
| `-v .../sandbox:ro` | Code mounted read-only; Go and Rust compile into `/tmp` and run from there | Read-only volume mount |

**No AWS compute ever runs untrusted code.** The API is a Lambda, but it only
enqueues jobs and reads/writes small S3 objects — it never touches Docker.
The worker is the one process that holds a Docker socket, and it
deliberately runs outside AWS entirely: either as a local process on a
developer's machine (`docker compose up worker`, or
`python -m codeignite.worker`, authenticated via the local-dev IAM role), or
as a long-running Deployment on your own Kubernetes cluster
(`infra/k8s/worker/` — plain manifests, not Terraform; the worker image is
built and imported directly into each node's containerd, never pulled from a
registry). See `docs/code-playground-plan.md` and
`docs/code-playground-hosted-api-plan.md` for the full reasoning, and
[`backend/README.md`](backend/README.md) for how to run the API and worker
locally.

## Repository structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── ci.yml              # PR gate: frontend, backend, terraform, security jobs
│   │   ├── deploy.yml          # push: terraform apply + lambda zip build + frontend deploy
│   │   ├── bootstrap.yml       # manual: state bucket, OIDC provider, IAM roles
│   │   └── codeql.yml          # SAST for the TypeScript
│   ├── dependabot.yml          # npm, github-actions, terraform
│   └── CODEOWNERS
├── frontend/                   # Next.js App Router, TypeScript, Tailwind 4
│   ├── app/(app)/playground/   # the code playground route
│   ├── components/
│   │   ├── layout/              # AuthGate, AmplifyProvider, BrandMark
│   │   └── playground/          # EditorPane, LanguageSelect, RunButton, OutputPane, StatusBadge
│   ├── lib/
│   │   ├── env.ts               # build-time env contract (throws on missing)
│   │   └── auth/                # Amplify Cognito configuration
│   └── types/runs.ts           # SUPPORTED_LANGUAGES + request/response types
├── backend/                    # The code playground's API and worker (FastAPI + boto3)
│   ├── src/codeignite/
│   │   ├── api/                 # FastAPI app, /runs routes, the Lambda handler
│   │   ├── worker/               # the SQS poll loop
│   │   ├── runner/               # the Runner protocol + LocalDockerRunner
│   │   ├── domain/languages.py   # the language registry
│   │   └── storage/              # S3 + SQS clients
│   └── scripts/                 # pull-images.sh, build-lambda-zip.sh
├── infra/                       # ALL infrastructure lives here (Terraform + plain k8s manifests)
│   ├── common.tfvars              # project_name + shared values (gitignored)
│   ├── bootstrap/                # one-time: state bucket + OIDC + IAM roles
│   ├── envs/{dev,staging,prod}/  # one Terraform root per environment
│   ├── modules/
│   │   ├── static-site/          # S3 + CloudFront + Cognito + WAF, one .tf file per service
│   │   ├── run-pipeline/         # SQS + DLQ + jobs S3 bucket + runtime IAM
│   │   └── run-api/              # the hosted Lambda API + its CloudFront OAC
│   └── k8s/worker/               # optional: run the worker as a Deployment on your own cluster
├── docs/                        # architecture + stage-by-stage build plans for the playground
└── scripts/                     # git hooks, pre-commit checks, local deploy
```

## Forking this template

Nothing in the repository identifies a project or a domain — all of it comes
from variables, so a fork only needs configuration.

1. **Issue a wildcard ACM certificate** for your domain in `us-east-1` and make
   sure its Route 53 hosted zone exists. The module looks the certificate up by
   domain rather than managing it, so one certificate serves all three
   environments.

2. **Fill in the shared config, once** — copy `infra/common.tfvars.example` to
   `infra/common.tfvars` and set `project_name`, `aws_account_id`, GitHub,
   region, and DNS zone fields. That one file feeds every Terraform root via
   the committed `common.auto.tfvars` symlink.

   ```bash
   cp infra/common.tfvars.example infra/common.tfvars   # set project_name once
   ```

   **Do not** set the state bucket or per-env hostnames by hand. They are derived
   from `project_name` (and the AWS account at init/plan time).

   Per-env `terraform.tfvars` files hold hardening knobs only; bootstrap-only
   values (`create_oidc_provider`, `local_dev_iam_users`, …) stay in
   `infra/bootstrap/terraform.tfvars`.

3. **Bootstrap the account** (once):

   ```bash
   cd infra/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # bootstrap-only values
   terraform init -backend=false
   terraform apply                                # creates state bucket + roles
   terraform init -backend-config="bucket=$(../../scripts/state-bucket-name.sh)" -migrate-state
   ```

4. **Set the repository variables** (Settings → Secrets and variables → Actions
   → Variables → Repository variables). These are the CI-side equivalent of
   `infra/common.tfvars` — set once, shared by every environment because a
   GitHub environment variable falls back to the repository variable of the
   same name when the environment doesn't override it:

   | Variable | Example |
   |---|---|
   | `AWS_ACCOUNT_ID` | `123456789012` |
   | `AWS_REGION` | `us-east-1` |
   | `PROJECT_NAME` | `myapp` |
   | `HOSTED_ZONE_NAME` | `example.com` |
   | `CERTIFICATE_DOMAIN_NAME` | `*.example.com` |
   | `LOCAL_DEV_IAM_USERS` | `["arn:aws:iam::123456789012:user/you"]` (optional) |

5. **Create the GitHub environments** `dev`, `staging`, `prod` and `bootstrap`.
   Repository variables above supply `HOSTED_ZONE_NAME` and
   `CERTIFICATE_DOMAIN_NAME` to every deploy; each environment's site hostname
   is derived as `{PROJECT_NAME}-dev|staging.{HOSTED_ZONE_NAME}` for dev/staging
   and `{PROJECT_NAME}.{HOSTED_ZONE_NAME}` for prod. Set optional hardening
   overrides per environment if you want them to differ from the defaults:

   | Variable | Example |
   |---|---|
   | `DOMAIN_NAME_OVERRIDE` | `www.example.com` (optional; non-standard hostname) |
   | `MFA_CONFIGURATION` | `OPTIONAL` (optional) |
   | `ADVANCED_SECURITY_MODE` | `AUDIT` (optional, billed per MAU) |
   | `ENABLE_WAF` | `true` (optional, billed) |
   | `API_BASE_URL` | `https://myapp-dev.example.com` (optional; see step 6) |

   Only set `HOSTED_ZONE_NAME` / `CERTIFICATE_DOMAIN_NAME` again at the
   environment level if a specific environment genuinely needs a different
   zone or certificate than the repository-level default.

6. **Decide whether this environment gets the code playground.** `run_pipeline`
   and `run_api` are already wired into `dev` and `prod` (see
   `infra/envs/<env>/main.tf`) — copy those two `module` blocks into
   `staging` if you want it there too. Either way the `/playground` route
   always ships; leave `API_BASE_URL` unset for an environment and it just
   renders a "not available in this environment" panel instead of erroring.
   Once `run_api` is deployed for an environment, set that environment's
   `API_BASE_URL` to the site's own origin — same-origin on purpose, so no
   CORS configuration is needed.

7. **Turn on the protections the code cannot enforce** — see
   [SECURITY.md](SECURITY.md#required-repository-settings). At minimum: required
   reviewers on `prod` and `bootstrap`, and branch protection requiring the `ci`
   checks. **A push to `main` applies to production**; the `prod` environment's
   reviewer rule is the only thing that puts a human in front of that.

8. **Update [`.github/CODEOWNERS`](.github/CODEOWNERS)** with your GitHub handle.

9. **Push.** `dev` → dev, `staging` → staging, `main` → prod.

10. **Run a worker.** Deploying `run_api` gets you an API, but nothing
    finishes a job until a worker is polling the queue — see "Running the
    code playground locally" below, or deploy it to your own Kubernetes
    cluster with `infra/k8s/worker/`.

## Environments

| Environment | Branch | Terraform root | Code playground wired in? |
|---|---|---|---|
| `dev` | `dev` | `infra/envs/dev` | Yes — also where the worker's local-dev role gets runtime access by default |
| `staging` | `staging` | `infra/envs/staging` | Not yet — `static-site` only |
| `prod` | `main` | `infra/envs/prod` | Yes |

`dev` also sets `attach_deploy_policies_to_local_dev_role = true` and, for
`run_pipeline`, `attach_runtime_policies_to_local_dev_role = true` so a
local worker can reach the real dev queue and bucket. Both are account-global
roles shared by all three environments, so exactly one environment should
own each attachment.

## Running the code playground locally

```bash
cd backend
python3.12 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev,server]"
cp .env.example .env       # fill the 5 required CODEIGNITE_* values from terraform output

docker compose up --build  # API on :8000 + worker — needs an active AWS SSO
                            # session mounted from ~/.aws
```

or run the two processes directly:

```bash
uvicorn codeignite.api.app:app --reload --port 8000   # terminal 1
python -m codeignite.worker                            # terminal 2 — needs a local Docker daemon
```

Point the frontend at it (`NEXT_PUBLIC_API_BASE_URL=http://localhost:8000` in
`frontend/.env.local`) and open `/playground`, or try the API directly:

```bash
job_id=$(curl -sX POST localhost:8000/runs \
  -H 'content-type: application/json' \
  -d '{"language": "python", "code": "print(\"hi\")"}' | jq -r .job_id)

curl -s "localhost:8000/runs/$job_id"
```

Full setup, the Docker Compose topology, and how to run just the worker
against the real hosted `dev` queue and bucket are in
[`backend/README.md`](backend/README.md).

## Local development

```bash
# Frontend
cd frontend
npm ci
cp .env.example .env.local     # fill in from terraform output — all three required
npm run dev                    # http://localhost:3000

npm run lint
npm run typecheck
npm run test
npm run format                 # or format:check
npm run build                  # static export to out/

# Backend — see "Running the code playground locally" above for full setup
cd backend
ruff format --check .          # ruff format . to fix
ruff check .
mypy --strict src
pytest -m "not docker"         # full suite needs no AWS creds and no network (moto + pytest-env)

# Terraform — shared config, once (see "Forking this template")
cp infra/common.tfvars.example infra/common.tfvars   # set project_name here only

# Terraform (per environment; AWS creds required for init)
cd infra/envs/dev
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config="bucket=$(../../scripts/state-bucket-name.sh)"
terraform fmt -recursive ../../
terraform validate
terraform plan
terraform apply                                  # never -auto-approve in prod

# All checks at once (mirrors ci.yml's frontend + backend + terraform + security jobs)
./scripts/install-git-hooks.sh   # once per clone
./scripts/pre-commit-check.sh
```

### Deploying without GitHub

`scripts/deploy-local.sh` runs the same job as `.github/workflows/deploy.yml`
end to end, from your own machine: ci-equivalent checks, an IaC/secret scan
plus `npm audit`, targeted IAM → ECR → Lambda image push → `terraform apply`
(with the same destructive-plan guard), then the frontend build, S3 sync, and
CloudFront invalidation. It uses whatever AWS credentials `aws` already
resolves in your shell (profile, env vars, SSO, or an assumed role via
`--assume-role`). The worker is never built or deployed by this script either
— it runs on a developer's own machine, never in AWS.

```bash
./scripts/deploy-local.sh dev                       # full deploy
./scripts/deploy-local.sh prod --frontend-only       # skip terraform
./scripts/deploy-local.sh staging --profile my-sso   # explicit AWS profile
./scripts/deploy-local.sh dev --skip-backend-image   # infra without rebuilding Lambda
./scripts/deploy-local.sh dev --help                 # all options
```

Deploying to `prod` always requires typing `prod` to confirm, even with
`--yes`. A destructive plan is blocked unless you pass `--allow-destroy`.

### Provider lock files

`.terraform.lock.hcl` is committed in every root, covering `linux_amd64`
(CI), `darwin_arm64`, `darwin_amd64` and `linux_arm64`. After changing a
provider version:

```bash
terraform -chdir=infra/envs/dev providers lock \
  -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
```

## Security

See [SECURITY.md](SECURITY.md) for the full security model, the known
limitations, and how to report a vulnerability. Three things worth knowing
up front:

- **There is no CSP.** It was removed because Next's App Router inlines its
  React Flight payload, which `script-src 'self'` blocks. Amplify's tokens are
  readable by any script on the origin and nothing now prevents an injected one
  from running, so vet every third-party script and dependency accordingly.
- **Untrusted code never runs inside AWS.** Sandboxing is enforced by `docker
  run` flags (no network, read-only filesystem, non-root, hard timeout) on
  whichever machine hosts the worker — your laptop or your own cluster — not
  by AWS IAM. Treat that host accordingly.
- **Destructive plans are blocked.** CI refuses to apply a plan containing a
  `delete`. Override deliberately with a `workflow_dispatch` run and the
  `allow_destroy` input.

## Extending further

The code playground is what "no server by default" looks like in practice —
the base template still ships with no backend, and this is the one feature
that has been added since, one file-per-concern Terraform module and one
registry entry at a time. Follow the same shape for the next one:
infrastructure goes in its own module under `infra/modules/`, application
logic goes in `backend/` (or a new package beside it) or `frontend/`, and a
new endpoint gets wired into the frontend the same way
`NEXT_PUBLIC_API_BASE_URL` is today. `docs/code-playground-implementation-plan.md`
and `docs/prs/` walk through exactly that process, stage by stage, for this
one.

## License

MIT — see [LICENSE](LICENSE).
