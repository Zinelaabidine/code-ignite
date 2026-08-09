# Code playground — serverless API plan (worker stays on your machine)

Companion to `code-playground-implementation-plan.md`, which explicitly
deferred this: "A hosted API. ... That is a genuine design decision and it
belongs after stage 5, when there is something worth hosting." PRs 1–8 got
the API and worker running locally against real AWS SQS/S3. This plan closes
the gap that leaves `/playground` showing "not available in this
environment": only the **API** moves to AWS, and it moves to Lambda —
nothing persistent, nothing to patch. The **worker never runs in AWS**. It
stays exactly what stages 2–3 already built: a local process on your
machine, long-polling the real SQS queue, executing jobs through the
unmodified `LocalDockerRunner`, and writing results to the real S3 bucket.
Revised from an earlier draft of this plan (which proposed a persistent EC2
instance for both API and worker) after clarifying the actual requirement:
**no AWS compute runs untrusted code, ever** — not ECS, not EKS, not EC2.
Code execution happens on your machine or nowhere.

**Status:** implemented (PRs 10–12's Terraform, Lambda handler/build script,
and CI wiring all written), not yet applied or verified against real AWS —
this session has no AWS credentials and cannot run `terraform apply` or
exercise the deploy pipeline. See each PR's file list below for what landed.
PR 13 (flipping `vars.API_BASE_URL`) is a manual GitHub Actions variable
change, listed here for completeness but not something this session can do
on your behalf.

**Revised again after PR 10 was first built**: the initial implementation
packaged the API as a container image pushed to a new ECR repository. That
was reworked to a zip-packaged Lambda (Mangum, `build-lambda-zip.sh`) after
clarifying that this repo uses no ECR, ECS, or EKS anywhere, and that
container images are pointless without one — Lambda's container-image
support can only pull from ECR, never Docker Hub or any other registry,
regardless of where the image is built or pushed.

---

## 0. What actually needs to be built

Looking at what stages 1–3 already shipped, this is smaller than it first
looks:

| Piece | Status |
| --- | --- |
| Worker pulls jobs from SQS, runs them via `LocalDockerRunner`, writes results to S3 | **Already built** (PR 4) — runs locally today against real AWS resources |
| Local process gets AWS credentials via the local-dev IAM role | **Already built** (PR 3's `attach_runtime_policies_to_local_dev_role` flag) — currently `false` in `infra/envs/dev/main.tf`, just needs flipping to `true` |
| API verifies Cognito tokens, rate-limits, enqueues jobs, serves results | **Already built** (PR 5) — runs fine anywhere that can reach SQS/S3/Cognito's JWKS endpoint over plain HTTPS, which is everywhere; no code changes needed |
| Something in AWS reachable from the browser at `/runs*` | **Missing** — this plan |

So the only genuinely new work is: package the existing FastAPI app for
Lambda, and wire it into the existing CloudFront distribution. No new
runner, no new worker code, no VPC, no persistent server, no SSH/SSM story
to build.

---

## 1. Architecture

```
Browser
  |  HTTPS
  v
CloudFront (existing distribution — same domain, no new subdomain)
  |-- default behavior --------------> S3 (existing static site origin)
  '-- /runs*, /healthz behaviors -----> Lambda Function URL (new, OAC-protected)
                                              |
                                              v
                                    api/app.py's create_app(), unmodified
                                    (POST /runs, GET /runs/{id}, GET /healthz)
                                              |
                              SQS runs queue          S3 jobs bucket
                              (existing — infra/modules/run-pipeline)
                                    ^                        ^
                                    |  long-poll receive     |  get/put
                                    |                        |
                         worker/loop.py running on YOUR machine
                         (docker compose up worker, or
                          python -m codeignite.worker directly —
                          unchanged from stages 2-3)
                              |
                              v
                    LocalDockerRunner -> docker run (your local daemon)
```

The API is stateless and only ever talks to SQS, S3, and Cognito's public
JWKS endpoint — none of which need a VPC. Lambda runs outside any VPC here,
which is what keeps this genuinely serverless: no ENIs, no NAT, no subnets
to manage.

**Same-domain reuse, as before**: `frontend/lib/runs/client.ts` builds
requests as `${baseUrl}/runs`, so `NEXT_PUBLIC_API_BASE_URL` is simply the
site's own origin. No new subdomain, no new CloudFront-scoped ACM
certificate, no CORS configuration — same-origin request, no preflight.

---

## 2. Fronting Lambda: Function URL + CloudFront OAC, not API Gateway

A Lambda Function URL is the whole HTTP front end here — no API Gateway
resource needed. CloudFront already does path routing, TLS termination for
the browser, and (optionally) WAF; API Gateway would just be a second,
redundant layer in front of a Lambda that CloudFront already reaches
directly.

**Locked down the same way the S3 origin already is**: CloudFront's
existing distribution uses an Origin Access Control so only CloudFront can
read the site bucket directly (`s3-policy.tf`). The AWS provider (pinned
`~> 6.0` here, well past when this landed) supports the same pattern for
Lambda Function URLs — `origin_access_control_origin_type = "lambda"`. The
Function URL's own `authorization_type` is `AWS_IAM`; only CloudFront,
signing with that OAC, is allowed to invoke it. A request straight to the
Function URL's own domain gets an IAM auth rejection, never reaching
application code — the same shape of protection `/playground`'s static
assets already have.

---

## 3. Packaging the API for Lambda

**Zip-packaged Lambda with Mangum, not a container image.** This repo does
not use Amazon ECR, ECS, or EKS anywhere — and Lambda's container-image
support can only ever pull the image from ECR, regardless of where it's
built or pushed (Docker Hub is not an option for Lambda container images).
Once ECR was off the table entirely, a container image was never on the
table either, so the API deploys as a plain zip.

New `backend/src/codeignite/api/lambda_handler.py`, the only Lambda-specific
code in the whole application — `api/app.py`'s `create_app()` stays
completely unaware it exists:

```python
from mangum import Mangum

from codeignite.api.app import app

handler = Mangum(app, lifespan="off")
```

Mangum translates the Lambda Function URL's HTTP API v2 event into an ASGI
call against `app` directly, in-process — no server process, no adapter
binary, no container.

**`pyjwt[crypto]`'s compiled `cryptography` dependency** is the one real
wrinkle in zip packaging: it ships native extensions that must be built
against Amazon Linux's `manylinux2014` ABI, not whatever platform builds
the zip. `backend/scripts/build-lambda-zip.sh` handles this with:

```bash
pip install \
  --platform manylinux2014_x86_64 \
  --python-version 3.12 \
  --implementation cp \
  --only-binary=:all: \
  --target build/lambda \
  ".[lambda]"
```

— which resolves Lambda-compatible wheels regardless of what machine runs
the build (a developer's laptop or a GitHub Actions runner). The `lambda`
extra in `pyproject.toml` pulls in the base dependencies (pydantic, fastapi,
boto3, pyjwt[crypto]) plus `mangum`, deliberately excluding the `server`
extra's `uvicorn` stack — Lambda never runs a server process, so bundling
uvicorn/uvloop/httptools would be dead weight against the package size
limit. `infra/modules/run-api/lambda.tf`'s `aws_lambda_function.api` reads
the built zip directly via `filebase64sha256(var.lambda_package_path)` —
Terraform does not build it; the script must run first.

---

## 4. New Terraform module: `infra/modules/run-api/`

File-per-concern, same convention as `static-site` and `run-pipeline`:

| File | Contents |
| --- | --- |
| `versions.tf` | Provider constraints |
| `variables.tf` | `project_name`, `environment`, `aws_region`, `lambda_package_path` (path to the zip built by `backend/scripts/build-lambda-zip.sh`), `jobs_bucket_name`, `runs_queue_url`, Cognito pool/client IDs, `run_api_policy_arn` (from `run_pipeline`'s output) |
| `locals.tf` | `name_prefix`, name-derived Lambda function/role ARNs |
| `iam-lambda.tf` | Execution role: `AWSLambdaBasicExecutionRole`-equivalent (CloudWatch Logs, written out explicitly rather than the AWS managed policy, per this repo's no-wildcard-without-comment IAM standard) plus the existing `run-api` managed policy from `run_pipeline` — no new S3/SQS permissions written; that policy was already scoped exactly for this caller |
| `lambda.tf` | `aws_lambda_function` (`runtime = "python3.12"`, `handler = "codeignite.api.lambda_handler.handler"`, `filename`/`source_code_hash` from `var.lambda_package_path`), environment variables for the five `CODEIGNITE_*` settings, `aws_lambda_function_url` (`authorization_type = "AWS_IAM"`), `aws_lambda_permission` scoping invocation to CloudFront's service principal via `source_account` (not `source_arn` — the distribution ARN isn't known until `static-site` creates it, and `static-site` needs this module's outputs first, a genuine cross-module cycle; `source_account` restricts to any distribution in this account, acceptable since there's exactly one) |
| `oac.tf` | `aws_cloudfront_origin_access_control` (`origin_access_control_origin_type = "lambda"`) |
| `iam-deploy.tf` | GitHub deploy role gets `lambda:CreateFunction`/`UpdateFunctionCode`/`UpdateFunctionConfiguration`/`CreateFunctionUrlConfig`/`AddPermission` scoped to this function's name-derived ARN (same "build the ARN by name, not from the resource" pattern `run_pipeline/iam-deploy.tf` already uses, for the same chicken-and-egg reason), `iam:PassRole` scoped to the Lambda execution role's ARN only. No ECR statements — nothing here ever touches a container registry |
| `outputs.tf` | Function URL domain + the OAC ID (both consumed by `static-site`'s new CloudFront behavior) |

Wiring: `infra/envs/dev/main.tf` gets a new `module "run_api"` block, and
`module.static_site` gains a variable (`api_origin_domain_name`,
`api_origin_access_control_id` — both optional/nullable) so the CloudFront
`/runs*`/`/healthz` behaviors only get created once `run_api` exists.
Staging and prod stay untouched, matching how `run_pipeline` is dev-only
today.

**One existing flag flips**: `infra/envs/dev/main.tf`'s
`module.run_pipeline.attach_runtime_policies_to_local_dev_role` goes from
`false` to `true`. That's the entire "let my machine's worker touch the
real queue and bucket" story — the policy and the flag both already exist
(PR 3); nothing about this plan adds new permissions for the worker side,
because the worker isn't moving anywhere.

---

## 5. Running the worker against the dev environment

No code, no new infra — this is a documentation change plus the flag flip
in §4. Once `attach_runtime_policies_to_local_dev_role = true` is applied:

```bash
# assume the local-dev role (MFA, per CLAUDE.md's local developer access
# boundary) — same as any other local-dev workflow already documented
aws sso login   # or however you normally assume the local-dev role

cd backend
cp .env.example .env
# fill in CODEIGNITE_JOBS_BUCKET / CODEIGNITE_RUNS_QUEUE_URL from
# `terraform output` in infra/envs/dev — these now point at the real,
# internet-reachable dev resources, not a scratch local setup

docker compose up worker   # or: python -m codeignite.worker
```

That's the whole "docker on my machine picks up the SQS event" requirement
— it's already what `worker/loop.py` does; pointing it at `dev`'s queue and
bucket instead of a personal sandbox is a config change, not new code.

**The operational consequence, stated plainly**: the playground only
*finishes* jobs while this process is running on your machine. Submit a run
while it's stopped and the job sits on the queue — the frontend's poll
loop gives up after 60 seconds with "still running" (per PR 7), and the
job either gets picked up whenever the worker next starts (within SQS's
4-hour message retention, per `run_pipeline`'s `message_retention_seconds`)
or expires unclaimed. This is the explicit trade of the architecture you
asked for, not a bug to fix — worth saying once, clearly, rather than
leaving it implicit.

---

## 6. CI/CD changes

**`.github/workflows/deploy.yml`**, gated the same way as `infra`/`frontend`
today (add a `backend` output to the existing `changes` job):

1. `actions/setup-python` (3.12) + `backend/scripts/build-lambda-zip.sh`,
   producing `backend/dist/api.zip`. No Docker, no registry, no push step —
   just a local build artifact.
2. The existing IAM `-target` apply block gets three more targets:
   `module.run_api`'s deploy policy, its attachment, and its propagation
   `time_sleep` — same pattern every other module here already follows.
3. `terraform apply` (unchanged shape), with `TF_VAR_lambda_package_path`
   pointing at the zip just built, so the Lambda function is created/updated
   against it, and creating/updating the CloudFront behaviors.

No SSM, no instance to reach, no restart step, no container registry
anywhere — `terraform apply` updating `aws_lambda_function.source_code_hash`
*is* the deploy.

**`.github/dependabot.yml`** — no new ecosystem entry. The `docker`
ecosystem entry already covers `Dockerfile.api`/`Dockerfile.worker`; there
is no `Dockerfile.lambda` to add.

---

## 7. Definition of done

- [ ] `terraform plan` in `infra/envs/dev` shows only additions
- [ ] Trivy config scan passes on `run-api/` (fix findings; extending
      `.trivyignore` requires a written justification, per `CLAUDE.md`)
- [ ] A direct HTTPS request to the Function URL's own domain (bypassing
      CloudFront) is rejected — proves the OAC restriction actually holds
- [ ] `https://codeignite-dev.openspacenexus.store/playground` — signed-in
      user submits Python, job appears on the queue, `GET /runs/{id}`
      returns `202 pending`
- [ ] With `docker compose up worker` running locally against dev's `.env`,
      the same job completes and the UI shows the result — the full
      browser → Lambda → SQS → local worker → S3 → Lambda → browser loop
- [ ] Stopping the local worker and submitting a run shows the "still
      running" state at 60s, matching §5's documented behavior
- [ ] `ruff`/`mypy`/`pytest` all still pass unchanged — no application code
      was modified, only a new Dockerfile and Terraform

---

## 8. Suggested PR sequence

| # | Branch | Contents | Gate |
| --- | --- | --- | --- |
| 10 | `feat/run-api-lambda-infra` | `infra/modules/run-api/` (zip-packaged Lambda, Function URL, Lambda-type OAC, IAM) + dev wiring + flip `attach_runtime_policies_to_local_dev_role` | `plan` shows only adds; Trivy clean |
| 11 | `feat/hosted-api-cloudfront` | `static-site`'s new `/runs*`/`/healthz` CloudFront behaviors + `api_origin_domain_name`/`api_origin_access_control_id` variables | `plan` shows only adds |
| 12 | `feat/deploy-api-lambda` | `backend/src/codeignite/api/lambda_handler.py`, `backend/scripts/build-lambda-zip.sh`; `deploy.yml`: build-zip step, `backend` change detection | CI green; manual deploy verified against dev |
| 13 | `docs/hosted-api-live` | Set `vars.API_BASE_URL` (repo variable) to the CloudFront origin; document running the worker against dev in `backend/README.md`; update `CLAUDE.md` | end to end, with local worker running |

PR 13 stays a config-only PR, same reasoning as the earlier draft of this
plan: flipping `vars.API_BASE_URL` is the one change that actually turns
the playground on, worth its own reviewable diff.

---

## 9. Cost (dev environment, rough monthly)

| Item | Estimate |
| --- | --- |
| Lambda (per-request billing, dev traffic) | Low single dollars, likely within the always-free tier (1M requests + 400,000 GB-seconds/month) |
| Function URL | No separate charge — billed as Lambda invocations |
| **Total** | **A few dollars a month, likely near $0** |

No EC2, no ALB, no NAT gateway, no VPC, no container registry — this is the
actual cost benefit of keeping the worker off AWS entirely and the API
zip-packaged: the only thing running continuously is SQS/S3, which were
already there from PR 3.

---

## 10. What's deliberately not here

- **No worker in AWS, anywhere, ever** — the entire point of this revision.
  Not Lambda, not ECS, not EKS. Code execution stays exactly where
  `LocalDockerRunner` already runs it: a Docker daemon you control.
- **No change to `LocalDockerRunner`, `worker/loop.py`, the `Runner`
  Protocol, or any other application code.** Purely infrastructure (the
  Lambda-hosted API) plus one new Dockerfile.
- **No autoscaling story beyond what Lambda gives for free.** The API
  scales automatically with request volume; the *worker* does not scale at
  all — it's one process on one machine, by design. A burst of submitted
  jobs queues on SQS until that one worker works through them.
- **No staging/prod wiring.** Same posture `run_pipeline` already has:
  dev-only until there's a reason to run this anywhere else.
- **No provisioned concurrency.** Cold starts are possible on the first
  request after idle; acceptable for a dev/demo environment, revisit if it
  becomes annoying.
- **No secrets in the Lambda's environment variables.** Every value there
  (region, bucket name, queue URL, Cognito IDs) is a Terraform-known
  identifier already treated as non-sensitive elsewhere in this repo.
