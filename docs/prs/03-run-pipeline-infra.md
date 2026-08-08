# PR 3 — `run-pipeline` Terraform module (SQS, DLQ, jobs bucket, IAM)

**Branch:** `feat/run-pipeline-infra`
**Commit:** `feat(infra): add run pipeline module with sqs queue, dlq and jobs bucket`
**Stage:** 2a of `docs/code-playground-implementation-plan.md`.
**Status:** done. `terraform fmt`, `terraform validate` (all four roots), and
a Trivy config scan verified locally — see "Verification" below. No `apply`
was run against real AWS from this environment; that's still yours to do.

## What this is

Pure infrastructure, no application code changes. A new Terraform module,
`infra/modules/run-pipeline`, providing the queue and storage half of the
async pipeline described in `docs/code-playground-plan.md`'s "flow" section:
an SQS queue carrying job IDs, a dead-letter queue, and a private S3 bucket
holding `jobs/{job_id}/input.json` and `.../result.json`. Wired into
`infra/envs/dev` only — staging and prod don't get it yet, matching phase 1's
local-first scope.

The next PR (`feat/async-runs`) is what actually uses this: the storage
layer, the worker process, and the async `POST`/`GET /runs` endpoints. This
PR is the infrastructure they'll build on, landing first so its own
correctness (IAM scoping, lifecycle rules, the deploy pipeline) gets reviewed
on its own.

## Files

### Added — `infra/modules/run-pipeline/`

| File | Contents |
| --- | --- |
| `versions.tf` | Provider constraints — `aws.this` only (no `us_east_1`; nothing here is CloudFront-related), plus `time` for the propagation sleep |
| `main.tf` | Shared data sources: account ID, the per-env GitHub deploy role (looked up, not created), the local-dev role (looked up when either attachment flag is set) |
| `locals.tf` | `name_prefix`, `account_id`, and three **name-constructed** ARNs (`runs_queue_arn`, `runs_dlq_arn`, `jobs_bucket_arn`) — see "The dependency cycle" below for why these exist instead of reading the resources' own attributes |
| `variables.tf` | `project_name`, `environment`, `aws_region`, the two local-dev attachment flags, and the SQS/S3 tuning knobs (visibility timeout, max receive count, retention, jobs TTL) — all validated |
| `sqs.tf` | The runs queue: 60s visibility timeout, 20s long-polling wait, SSE, redrive policy to the DLQ |
| `sqs-dlq.tf` | The dead-letter queue (14-day retention) plus an explicit `aws_sqs_queue_redrive_allow_policy` naming the one queue allowed to redrive into it |
| `s3-jobs.tf` | The jobs bucket and all four required companions (public access block, ownership controls, SSE, versioning) plus a 7-day lifecycle expiration on `jobs/` |
| `s3-jobs-policy.tf` | TLS-only deny — no CloudFront/OAC allow statement, since nothing serves this bucket publicly |
| `iam-deploy.tf` | The deploy-time managed policy (create/manage the queue, DLQ, bucket, and the two runtime policies below), attached to the GitHub deploy role and, conditionally, the local-dev role |
| `iam-runtime.tf` | The `run-api` and `run-worker` runtime managed policies — genuinely different rights, attached only to the local-dev role, gated by their own flag |
| `outputs.tf` | Queue URL/ARN, DLQ URL/ARN, bucket name/ARN, both runtime policy ARNs |
| `docs/prs/03-run-pipeline-infra.md` | This file |

### Modified

| Path | Change |
| --- | --- |
| `infra/envs/dev/main.tf` | New `module "run_pipeline"` call, both local-dev attachment flags left `false` to match `static_site`'s existing default (flip both once `local_dev_iam_users` is configured in bootstrap) |
| `infra/envs/dev/outputs.tf` | New `runs_queue_url` and `jobs_bucket_name` outputs — the two values `backend/.env` will need in the next PR |
| `.github/workflows/deploy.yml` | Added three `-target=module.run_pipeline.*` lines to the "Terraform Apply deploy IAM policies" step — **required**, not optional; see "Why deploy.yml had to change" below |
| `.trivyignore` | Updated the `AVD-AWS-0089` and `AVD-AWS-0132` comments to also cover the new jobs bucket, so the suppression stays honest about what it now applies to |

## Why deploy.yml had to change

`infra/envs/dev` is applied automatically by `deploy.yml` on every push to
`dev` that touches `infra/**`, using the per-environment GitHub deploy role.
That role starts with zero SQS/S3-jobs/IAM-runtime-policy permissions — this
module's own `iam-deploy.tf` is what grants them, which means the same
chicken-and-egg problem `static-site` already solves applies here too: the
role needs the policy attached *before* it can create the resources the
policy authorizes.

`deploy.yml` already handles this for `static_site` with a dedicated
`-target`ed apply step that runs before the main plan/apply, followed by a
credential refresh. This PR adds the equivalent three targets for
`run_pipeline`. Skipping this step would not have failed anything in this PR
— it would have failed on the *next* push to `dev`, with a full
`terraform apply` in CI throwing `AccessDenied` on `sqs:CreateQueue`. I'm
flagging this prominently because it's the kind of gap that's invisible in a
local `terraform validate` and only surfaces in CI.

## The dependency cycle (and why three locals exist)

The first version of `iam-deploy.tf` scoped its SQS and S3 statements to
`aws_sqs_queue.runs.arn` / `aws_sqs_queue.runs_dlq.arn` / `aws_s3_bucket.jobs.arn`
— the real resource attributes, exactly like `static-site`'s storage policy
does for the site bucket. `terraform validate` caught a real cycle:

```
Cycle: module.run_pipeline.aws_s3_bucket.jobs,
       module.run_pipeline.time_sleep.run_pipeline_iam_propagation,
       module.run_pipeline.aws_sqs_queue.runs_dlq,
       module.run_pipeline.aws_sqs_queue.runs,
       module.run_pipeline.data.aws_iam_policy_document.github_deploy_run_pipeline_policy,
       module.run_pipeline.aws_iam_policy.github_deploy_run_pipeline_policy,
       module.run_pipeline.aws_iam_role_policy_attachment.github_deploy_run_pipeline
```

The queue and bucket `depends_on` the propagation sleep (so they aren't
created before the role has permission); the policy document referenced
their ARNs (so the policy can't render before they exist). Both directions
can't hold at once.

The fix: `locals.tf` builds `runs_queue_arn`, `runs_dlq_arn`, and
`jobs_bucket_arn` **by name** (`arn:aws:sqs:${var.aws_region}:${account_id}:${name}`,
`arn:aws:s3:::${name}`) instead of reading them off the resources. This is
valid specifically because SQS and S3 resource names in this module are
chosen by Terraform, not assigned by AWS after creation — the same reasoning
`static-site` already uses for `CreateDistribution` and `CreateFunction`,
which are scoped to account-wide wildcard patterns rather than a specific
not-yet-existing ID. Constructing the ARN by name is actually *tighter* than
a wildcard, and it's what let this module avoid the cycle outright rather
than relying on implicit apply ordering the way `static-site`'s storage
policy does. This added the `aws_region` variable, which the module
otherwise wouldn't have needed.

## Design notes worth flagging on review

- **Two runtime policies, not one.** `run-api` gets `PutObject`/`GetObject`
  on `jobs/*` and `SendMessage`/`GetQueueUrl`; `run-worker` gets
  `GetObject`/`PutObject` on `jobs/*` and `ReceiveMessage`/`DeleteMessage`/
  `ChangeMessageVisibility`/`GetQueueAttributes`/`GetQueueUrl`. Both scoped
  to the exact queue ARN and `jobs/*` — no `s3:*`, no `sqs:*`, no
  bucket-level delete. Splitting them now, even though both currently attach
  to the same local-dev role, is what makes the eventual ECS/EKS task roles
  correct later instead of a shared, overbroad one.
- **Neither runtime policy attaches to the GitHub deploy role.** CI deploys
  infrastructure; it never runs the API or worker. Only `iam-deploy.tf`'s
  policy touches the deploy role.
- **No `prevent_destroy` on the jobs bucket**, unlike the site bucket and
  Cognito pool. Every object in it expires within `jobs_retention_days` (7,
  by default) — there's no durable state a destroy could take by surprise.
- **Versioning is still enabled**, despite the bucket being ephemeral.
  `CLAUDE.md` requires it on every `aws_s3_bucket` unconditionally, and the
  lifecycle rule's `noncurrent_version_expiration` uses the same retention
  window, so it costs nothing extra here.
- **`max_receive_count` defaults to 2`,** matching the architecture doc
  exactly ("a dead-letter queue after 2 receives, so a job that crashes the
  worker isn't redelivered forever").
- **Long polling (`receive_wait_time_seconds = 20`) is hardcoded, not a
  variable** — there's no scenario in this project where short polling is
  the right call, so it isn't exposed as a knob to get wrong.
- **Both local-dev attachment flags default to `false` in `infra/envs/dev`**,
  matching `static_site`'s own `attach_deploy_policies_to_local_dev_role`
  default. I did not flip them to `true` — that depends on whether
  `local_dev_iam_users` is already configured in your `infra/bootstrap`,
  which I can't see from here. Flip both once it is (see the comment left in
  `infra/envs/dev/main.tf`).

## Verification

Ran against Terraform 1.15.8 (matching `ci.yml`'s `TF_VERSION`) and the AWS
provider resolved fresh (`~> 6.0` → 6.58.0, no lock file changes needed —
same major/minor range already pinned):

```bash
terraform fmt -check -recursive infra/     # clean after two alignment fixes
terraform -chdir=infra/bootstrap    init -backend=false && terraform validate   # Success
terraform -chdir=infra/envs/dev     init -backend=false && terraform validate   # Success
terraform -chdir=infra/envs/staging init -backend=false && terraform validate   # Success
terraform -chdir=infra/envs/prod    init -backend=false && terraform validate   # Success
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore infra/          # 0 misconfigurations
```

**Not verified here:** an actual `terraform plan`/`apply` against real AWS —
this sandbox has no AWS credentials. Before merging, please run `terraform
plan` in `infra/envs/dev` and confirm it shows only additions (no
`prevent_destroy` resources, nothing unexpected touched in `static_site`).

## What's deliberately not here

- No `backend/` changes — `LocalDockerRunner` still runs synchronously.
  Nothing in the backend reads `runs_queue_url` or `jobs_bucket_name` yet.
- Not wired into staging or prod. Phase 1 is dev-only, per
  `docs/code-playground-plan.md`.
- No `docker-compose.yml` — that's `feat/async-runs`, once there's a worker
  to compose alongside the API.

## Next

PR 4 (`feat/async-runs`): `codeignite.storage.objects` /
`codeignite.storage.queue`, the worker loop, and the async
`POST`/`GET /runs` endpoints, consuming this PR's `runs_queue_url` and
`jobs_bucket_name` outputs via new required fields in `config.py` (the first
ones without a default — see that module's docstring).
