# Pre-push audit — security, Terraform, CI/CD, frontend

> **Status: all 30 findings have been addressed.** This document is kept as the
> record of *why* the code looks the way it does — the reasoning behind a
> control is the part that gets lost first. Each finding below describes the
> original problem and the fix that was applied.
>
> Verified locally: `terraform fmt -check -recursive` and `terraform validate`
> pass in all four roots; `npm run lint`, `typecheck`, `test` (8 passing),
> `format:check` and `build` all pass; a build with missing Cognito
> environment variables now fails fast with a clear error.

Reviewed against `CLAUDE.md` and general AWS/Terraform/GitHub Actions/Next.js
best practice. Nothing secret was committed (no keys, no `.tfvars`, no `.env`)
— the `.gitignore` was sound on that front.

Findings are ordered by severity. Each has the file, the problem, and the fix.

---

## P0 — Blockers (will break or expose the deploy)

### 1. Terraform state bucket name is inconsistent — deploy role cannot read state

| Location | Value |
|---|---|
| `infra/envs/{dev,staging,prod}/backend.tf` | `apptemplate-terraform-state` |
| `infra/bootstrap/backend.tf` | `apptemplate-terraform-state` |
| `infra/bootstrap/terraform.tfvars.example` | `apptemplate-terraform-state` |
| `infra/envs/*/main.tf` → `terraform_state_bucket` | **a different bucket entirely** |

That module input is what builds the `S3TerraformStateBackend` statement in
`iam-github-oidc.tf`. The deploy role is therefore granted S3 access to a bucket
that isn't the one the backend actually uses → `AccessDenied` on
`terraform init` in CI, for every environment.

**Fix:** pick one name and use it in all four places. Because the S3 backend
block cannot interpolate variables, add a comment in each `backend.tf` pointing
at `terraform_state_bucket` as the value that must match.

### 2. `.terraform.lock.hcl` is gitignored

`.gitignore:16`. HashiCorp's guidance is the opposite: the dependency lock file
**must be committed**. Without it:

- CI re-resolves provider versions on every run — `~> 6.0` silently pulls a new
  minor into a production apply.
- Provider checksum verification is lost entirely, which is the supply-chain
  control for a binary that holds your AWS credentials.

**Fix:** remove the line, run `terraform init` in `infra/bootstrap` and each
`infra/envs/*`, commit the resulting lock files. Add
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64` so the
lock covers both CI and workstations.

### 3. Third-party action runs in a job holding `id-token: write`

`.github/workflows/deploy.yml:36-38` sets `permissions: id-token: write` at the
**workflow** level, so every job inherits it — including `changes`, which runs
`dorny/paths-filter@v3` (a mutable tag on a third-party repo). A compromised
release of that action can mint an OIDC token and assume your deploy role.

**Fix:**

```yaml
permissions:
  contents: read          # workflow default

jobs:
  changes:
    permissions:
      contents: read      # no id-token here
  deploy:
    permissions:
      contents: read
      id-token: write     # only where it's needed
```

### 4. No `prevent_destroy` on stateful resources

`infra/envs/prod/main.tf:1-7` leaves this as a comment telling a future
maintainer to add it. `CLAUDE.md` §6 forbids exactly that ("no `# TODO`").
Right now a `terraform destroy` — or an unnoticed replacement triggered by a
plan diff — deletes the Cognito User Pool and every registered account
irreversibly, plus the site bucket.

**Fix:** add now, in the module, not as a note:

```hcl
# auth.tf
resource "aws_cognito_user_pool" "this" {
  deletion_protection = "ACTIVE"
  lifecycle { prevent_destroy = true }
}
# s3.tf, and bootstrap/main.tf for the state bucket
lifecycle { prevent_destroy = true }
```

If you need dev to stay disposable, gate it on a
`variable "enable_deletion_protection"` — but `prevent_destroy` itself cannot
take a variable, so the cleaner route is to keep it hard-on everywhere and
accept that tearing down dev requires a deliberate code edit.

---

## P1 — Security gaps

### 5. No HTTP security headers on CloudFront

`infra/modules/static-site/cloudfront.tf` attaches no
`response_headers_policy_id`. The site serves no HSTS, no CSP, no
`X-Content-Type-Options`, no `Referrer-Policy`, no frame-ancestors control.

This matters more than usual here: Amplify v6 stores Cognito ID/access/refresh
tokens in **`localStorage` by default**. `CLAUDE.md` §5 says "never store JWTs
in localStorage… rely on Amplify's managed session storage" — but Amplify's
managed storage *is* localStorage unless you override it. So any XSS is full
account takeover, and a CSP is the compensating control.

**Fix:** add `infra/modules/static-site/cloudfront-headers.tf`:

```hcl
resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.this
  name     = "${local.name_prefix}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options { override = true }
    frame_options { frame_option = "DENY", override = true }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      override = true
      content_security_policy = join("; ", [
        "default-src 'self'",
        "connect-src 'self' https://cognito-idp.${var.aws_region}.amazonaws.com",
        "img-src 'self' data:",
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self'",
        "font-src 'self' data:",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "object-src 'none'",
      ])
    }
  }
}
```

Then set `response_headers_policy_id` in `default_cache_behavior`. Start the
CSP in `content_security_policy_report_only` if you want to validate it against
the Amplify UI bundle first. Note `next/font/google` self-hosts fonts at build
time, so `'self'` is sufficient for `font-src`.

Consider also switching Amplify to `cognitoUserPoolsTokenProvider.setKeyValueStorage(new CookieStorage({ secure: true, sameSite: "strict" }))` so tokens leave `localStorage` entirely.

### 6. Neither S3 bucket denies non-TLS access

`infra/modules/static-site/s3-policy.tf` and `infra/bootstrap/main.tf`. Standard
CIS/Foundational-Security-Best-Practices control `S3.5`.

**Fix:** add to each bucket policy:

```hcl
statement {
  sid       = "DenyInsecureTransport"
  effect    = "Deny"
  actions   = ["s3:*"]
  resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
  principals { type = "AWS", identifiers = ["*"] }
  condition {
    test     = "Bool"
    variable = "aws:SecureTransport"
    values   = ["false"]
  }
}
```

The bootstrap state bucket has **no** bucket policy at all today — it needs one
for this.

### 7. Cognito User Pool is under-hardened

`infra/modules/static-site/auth.tf`:

- `minimum_length = 8` — NIST 800-63B and AWS both point at 12+ for
  human-chosen passwords.
- No MFA (`mfa_configuration` unset → `OFF`), no software-token config.
- No `user_pool_add_ons { advanced_security_mode = "ENFORCED" }` (threat
  protection: compromised-credential detection, adaptive auth). Costs money —
  reasonable to enable in prod only.
- No explicit token validity. Defaults are 60 min access/ID and **30 days**
  refresh; a stolen refresh token in `localStorage` is good for a month.
- No `temporary_password_validity_days`, no `password_history_size`.

**Fix:** at minimum raise to 12, set `deletion_protection = "ACTIVE"`, set
`refresh_token_validity = 7` (days) on the client, and make MFA/advanced
security an environment-driven variable so prod can turn them on.

### 8. No CloudFront access logs, no WAF

`cloudfront.tf` has neither `logging_config` nor `web_acl_id`. There is
currently no way to answer "who hit this site and when", and no rate limiting
in front of the Cognito hosted flows. Also no S3 server access logging on the
site bucket or the state bucket.

**Fix:** a logs bucket in the module (with its own four companion resources,
per your §6 rule) wired to `logging_config`; WAF is optional for a static site
but worth a `variable "enable_waf"` defaulting to `true` in prod.

### 9. `local-dev-role` trust has no MFA condition — and an empty default breaks apply

`infra/bootstrap/main.tf`, `data.aws_iam_policy_document.local_dev_trust`. That
role receives *all three* deploy managed policies (when
`attach_deploy_policies_to_local_dev_role = true`, which dev sets). Anyone
holding one of those IAM users' long-lived access keys gets the full deploy
surface with no second factor.

Separately: `local_dev_iam_users` defaults to `[]`, which renders a
`principals` block with an empty `identifiers` list — IAM rejects that, so a
default-values apply fails.

**Fix:**

```hcl
condition {
  test     = "Bool"
  variable = "aws:MultiFactorAuthPresent"
  values   = ["true"]
}
```

plus a `validation` block requiring at least one ARN, or `count` the role out
when the list is empty.

### 10. GitHub Actions are tag-pinned, not SHA-pinned

`actions/checkout@v4`, `aws-actions/configure-aws-credentials@v4`,
`hashicorp/setup-terraform@v3`, `actions/setup-node@v4`,
`dorny/paths-filter@v3`. Tags are mutable. At minimum pin the third-party one
(`dorny/paths-filter`) to a full commit SHA; ideally pin all of them and let
Dependabot bump them.

```yaml
uses: dorny/paths-filter@de90cc6fb38fc0963ad72b210f1f284cd68cea36 # v3.0.2
```

---

## P2 — Terraform correctness and hygiene

### 11. Environment roots have no `versions.tf`

`infra/envs/*/` declare `terraform { backend "s3" {} }` but no
`required_version` and no `required_providers`. Provider constraints leak in
from the module, which works, but the root is where they belong — and the
Terraform CLI version is unconstrained. Note `use_lockfile = true` *requires*
≥ 1.10, so a developer on 1.9 gets a confusing failure.

Also: the `provider "aws"` blocks live inline in `main.tf`, while
`infra/bootstrap` correctly separates them into `providers.tf`. Your own
file-per-concern rule (§6) should apply to the env roots too.

**Fix:** add `infra/envs/<env>/versions.tf` and `providers.tf`, and put
`default_tags` on the provider so the four mandatory tags stop being
copy-pasted onto every resource:

```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "dev"
      Project     = "apptemplate"
      ManagedBy   = "terraform"
    }
  }
}
```

### 12. Environment config is hardcoded in `main.tf`

`infra/envs/*/main.tf` baked in a personal domain, GitHub handle and project
slug. For a repo published as a template this both leaks the domain into git
history and forces a five-file edit per fork.

**Fix:** move to `variables.tf` + a gitignored `terraform.tfvars` per env, with
a committed `terraform.tfvars.example` (the pattern `infra/bootstrap` already
uses). Fed in CI via `-var-file` or `TF_VAR_*`.

### 13. Deprecated `forwarded_values` in the cache behavior

`cloudfront.tf:78-85`. The AWS provider has deprecated this in favour of cache
policies; it also forces a legacy behavior that can't do origin-request
policies or Brotli tuning.

**Fix:**

```hcl
cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # Managed-CORS-S3Origin
```

or look them up with `data "aws_cloudfront_cache_policy"`.

### 14. Versioning enabled with no lifecycle rule

Both the site bucket (`s3.tf`) and the state bucket (`bootstrap/main.tf`) have
versioning on and no `aws_s3_bucket_lifecycle_configuration`. Every deploy's
`s3 sync --delete` creates delete markers and noncurrent versions that are kept
forever; the state bucket accumulates a version per apply.

**Fix:** `noncurrent_version_expiration { noncurrent_days = 30 }` on the site
bucket, `90` on state, plus
`abort_incomplete_multipart_upload { days_after_initiation = 7 }` on both.

### 15. Inconsistent explicit `provider` arguments inside the module

Most resources set `provider = aws.this`, but
`aws_iam_role_policy_attachment.*` (six of them) and
`data.aws_iam_policy_document.*` do not — they silently fall back to the
inherited default provider. It works today only because the root passes
`aws.this = aws`. Make it explicit everywhere, or drop
`aws.this` and use the default provider consistently.

### 16. Redundant module inputs invite drift

- `var.name` is always `"${var.project_name}-${var.environment}"`, which
  `local.name_prefix` already computes. Two sources of truth for the same
  string; `auth.tf` uses `var.name` while everything else uses
  `local.name_prefix`. Delete the variable.
- `var.aws_region` defaults to `us-east-1` and is used to build the Cognito ARN
  in `iam-github-oidc.tf`, but the provider's region comes from a hardcoded
  literal in the env root. Set the region once and derive both, or the IAM
  policy will silently scope to the wrong region the day you move.
- `local.bucket_name = replace(var.domain_name, ".", "-")` ignores
  `name_prefix`, so the bucket doesn't follow the documented naming convention.

### 17. Minor

- `s3-policy.tf` has no trailing newline.
- `.DS_Store` sits in the working tree (gitignored, but delete it before the
  initial push).
- OIDC `thumbprint_list` is vestigial — the comment says so; you can drop the
  field entirely on modern provider versions.

---

## P3 — CI/CD

### 18. No `pull_request` trigger — CI never gates a merge

`deploy.yml` runs `on: push` to `dev`/`staging`/`main` only. Lint, `fmt -check`
and the build therefore run *after* the code has already landed on a deploy
branch. You can't configure a meaningful branch-protection required check.

**Fix:** split a `ci.yml` that runs on `pull_request` with lint + `npm run
build` + `terraform fmt -check` + `terraform validate` (and `terraform plan`
against the target env, posted as a PR comment). Keep `deploy.yml` for
deployment only.

### 19. `terraform validate` never runs in CI

The `ci` job only does `fmt -check`. `scripts/pre-commit-check.sh` runs
`validate` locally, but the hook is opt-in per clone — it's not a guarantee.

### 20. `cancel-in-progress: true` on the deploy concurrency group

`deploy.yml:44-47`. The comment already admits this can strand a state lock.
Cancelling mid-`apply` is materially worse than queuing.

**Fix:** `cancel-in-progress: false` for the deploy group. Keep `true` only on
the PR-CI workflow.

### 21. `prod` applies straight from a push to `main`

`deploy.yml` runs `terraform plan -out=tfplan && terraform apply -auto-approve
tfplan` with no human in the loop. `CLAUDE.md` §4 says "never `-auto-approve`
in prod". Using a saved plan file is the right mechanic, but nothing reviews
that plan.

**Fix:** configure the `prod` GitHub environment with required reviewers (the
`bootstrap` workflow already documents this pattern for itself) and document it
in the README — an environment protection rule is the only thing standing
between a merge and a production apply. Optionally fail the job when the plan
contains a `destroy` (`terraform show -json tfplan | jq` on
`.resource_changes[].change.actions`), matching your §6 "treat any unexpected
destroy as a blocker".

### 22. Upload has no cache-control strategy, and ordering risks a broken window

```yaml
aws s3 sync ./out "s3://$BUCKET" --delete
```

Everything gets default headers, so hashed immutable assets under
`_next/static/` are not marked `immutable`, and HTML inherits CloudFront's
default TTL. You compensate with a `/*` invalidation on every deploy — free for
the first 1,000 paths per month, billed after.

Also `--delete` runs before the invalidation, so for the invalidation window
CloudFront can serve cached HTML that references objects already removed.

**Fix:** three-pass upload:

```bash
# 1. immutable assets first, no --delete
aws s3 sync ./out "s3://$BUCKET" --exclude "*.html" \
  --cache-control "public,max-age=31536000,immutable"
# 2. HTML last, always revalidated
aws s3 sync ./out "s3://$BUCKET" --exclude "*" --include "*.html" \
  --cache-control "public,max-age=0,must-revalidate"
# 3. now prune
aws s3 sync ./out "s3://$BUCKET" --delete
```

and narrow the invalidation to `/ /index.html /*.html`.

### 23. `paths-filter` base on a new branch

`base: ${{ github.event.before }}` is `0000000…` on the first push to a branch,
which `dorny/paths-filter` cannot diff against. Add a fallback to the merge base
or to `github.event.repository.default_branch`.

### 24. Missing repository-level supply-chain hygiene

None of these exist yet:

- `.github/dependabot.yml` — `npm`, `github-actions`, and `terraform` ecosystems
- `.github/workflows/codeql.yml` or equivalent SAST for the TS
- IaC scanning (`tfsec`, `checkov`, or `trivy config`) in PR CI
- secret scanning in CI (`gitleaks`) — belt and braces alongside GitHub's own
- `SECURITY.md`, `CODEOWNERS`, PR template
- Branch protection on `main`/`staging`/`dev` (required checks, no force-push,
  required review) — repo settings, not a file, but document it in the README

---

## P4 — Frontend

### 25. Missing env vars degrade silently

`lib/auth/amplifyClient.ts:29-34` logs to `console.error` and returns. The build
succeeds, the deploy succeeds, and the app is simply broken at runtime with no
signal in CI.

**Fix:** validate at module load and `throw` in development while keeping the
production path graceful, or better, validate in a small `lib/env.ts` that the
build imports so `next build` fails fast on a missing value.

### 26. `configureAmplify()` is called in the render body

`components/layout/AmplifyProvider.tsx:11`. A side effect during render — it
happens to be idempotent via the `configured` flag, but it violates React's
rules and will run twice under StrictMode.

**Fix:** call it at module scope (it already guards on
`typeof window === "undefined"`), which also guarantees it runs before any child
hook rather than merely in the same pass.

### 27. No formatter, and quote style is already inconsistent

`amplifyClient.ts` and `AmplifyProvider.tsx` use single quotes; everything else
uses double. There's no Prettier config and no `format:check` in CI, so this
diverges further with every commit.

**Fix:** add `.prettierrc`, `eslint-config-prettier`, a `format` script, and a
`prettier --check` step in PR CI.

### 28. `tsconfig.json` is looser than `CLAUDE.md` claims

`strict: true` is on, but these are worth adding given the "never use `any`"
posture:

- `noUncheckedIndexedAccess` — `lib/auth/parseUser.ts` indexes `parts[0][0]`
  and `local.split("@")[0]` without it; those are unchecked today.
- `noImplicitOverride`, `noFallthroughCasesInSwitch`
- `target: "ES2017"` is the Next default but dated — `ES2022` is safe for the
  browsers Next 16 supports.
- `allowJs: true` with no `.js` files in the repo — drop it.

### 29. `shadcn` is a runtime dependency

`package.json`. It's a CLI scaffolding tool; it belongs in `devDependencies`.
Also `@base-ui/react` is a dependency but appears in neither `CLAUDE.md`'s tech
stack table nor the README — keep the docs in sync or remove the package.

### 30. No tests, no Node version pin

There is no test framework and no `.nvmrc`/`engines` field, while CI pins
`NODE_VERSION: 24`. A contributor on Node 20 gets a different lockfile
resolution than CI.

**Fix:** `.nvmrc` with `24`, `"engines": { "node": ">=24" }`, and at least
Vitest + one smoke test so `npm test` exists as a CI gate.

---

## Suggested order of work before the first push

1. Fix the state bucket name (P0 #1) — nothing deploys until this is right.
2. Commit `.terraform.lock.hcl` (P0 #2).
3. Scope `id-token: write` per job and SHA-pin `dorny/paths-filter` (P0 #3).
4. Add `prevent_destroy` + `deletion_protection` (P0 #4).
5. Add the response-headers policy and the TLS-only bucket policies (P1 #5, #6).
6. Parameterise the env roots so your domain isn't in the template (P2 #12).
7. Split a `pull_request` CI workflow and add Dependabot (P3 #18, #24).

Everything below that is quality-of-life and can land incrementally.
