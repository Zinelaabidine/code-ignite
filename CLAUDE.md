# CLAUDE.md — App Template System Instructions

> Authoritative architectural memory and coding-session contract for AI
> assistants working in this repository. Read it in full before writing any
> code or infrastructure changes.
>
> **Token tip:** Scoped, shorter rules live in `.cursor/rules/*.mdc` (loaded by
> file path). You can replace this file with a brief index once those rules are
> trusted, and rely on `project-core.mdc` plus folder rules instead.

---

## 1. Architecture Overview

A Next.js static export served from a private S3 bucket through CloudFront,
with authentication handled by an Amazon Cognito User Pool. **This is the base
template's architecture — a fresh fork with no features added.** There is no
backend API, no database, and no compute layer in that state, by design.

```
Browser (Next.js static export)
  |  Cognito sign-up / sign-in  (AWS Amplify)
  v
Cognito User Pool
  ^
  |  pool + client IDs baked into the bundle at build time
CloudFront  ──►  S3 (private, Origin Access Control)
```

**This repository has since grown one feature on top of that template: the
code playground** (`backend/`, `infra/modules/run-pipeline`,
`infra/modules/run-api`) — sandboxed code execution behind Cognito, SQS, and
S3, with its API hosted on Lambda and its worker running on a developer's own
machine (deliberately never in AWS — see
`docs/code-playground-hosted-api-plan.md` §0). See
`docs/code-playground-plan.md` for that feature's architecture and
`docs/code-playground-implementation-plan.md` /
`docs/code-playground-hosted-api-plan.md` for how it was built, stage by
stage. The "no server by default" principle below still describes how to
*add* features to this template; the code playground is the one place so far
where a feature genuinely needed a server (a Docker daemon for the worker)
and Terraform reflects that explicitly rather than pretending otherwise.
Section 2's repository structure and this section's diagram describe the
template in its unmodified state; a full rewrite reflecting the code
playground's addition is tracked as its own step
(`docs/code-playground-implementation-plan.md` PR 9,
`docs/update-architecture`) rather than folded into this note.

### Core design principles

- **No server by default.** Amplify talks straight to Cognito. Do not introduce
  a Lambda, API Gateway, or database "just in case" — add them when a feature
  needs them, one `.tf` file per service.
- **Zero standing credentials.** GitHub Actions deploys via OIDC; there are no
  long-lived AWS keys anywhere in CI.
- **Infrastructure as Code.** The entire AWS stack is Terraform, with `dev`,
  `staging`, and `prod` environment roots sharing one module.
- **Bootstrap is separate from deploy.** The trust chain that lets CI
  authenticate lives in `infra/bootstrap` behind a manual, human-approved
  workflow. A workflow must never manage its own trust chain.

### Environments

| Environment | Branch | Terraform root |
|---|---|---|
| `dev` | `dev` | `infra/envs/dev` |
| `staging` | `staging` | `infra/envs/staging` |
| `prod` | `main` | `infra/envs/prod` |

`dev` sets `attach_deploy_policies_to_local_dev_role = true`. That role is
account-global, so exactly one environment may own its policy attachments.

---

## 2. Repository Structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── ci.yml              # PR gate; also called by deploy.yml (workflow_call)
│   │   ├── deploy.yml          # on push: terraform apply + frontend deploy
│   │   ├── bootstrap.yml       # manual only: state bucket, OIDC, IAM roles
│   │   └── codeql.yml          # SAST for the TypeScript
│   ├── dependabot.yml          # npm, github-actions, terraform
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── frontend/                   # Browser app (Next.js static export)
│   ├── app/                    # App Router routes, root layout, globals.css
│   ├── components/
│   │   ├── layout/             # AuthGate, AmplifyProvider, BrandMark
│   │   ├── home/               # authenticated placeholder
│   │   └── ui/                 # shadcn/ui primitives
│   └── lib/                    # env contract, auth config, cn() helper
├── backend/                    # Server-side app code when added (empty in template)
├── infra/                      # ALL infrastructure lives here (Terraform only)
│   ├── bootstrap/              # one-time state bucket + OIDC + IAM roles
│   ├── envs/{dev,staging,prod}/
│   └── modules/static-site/    # one .tf file per AWS service
└── scripts/                    # git hooks, pre-commit checks, local deploy
```

### Hard boundary rules

- **Infrastructure changes belong exclusively in `infra/`.** Never edit a `.tf`
  file to work around an application bug — fix the application.
- **Client application logic belongs in `frontend/`.** **Server-side logic belongs
  in `backend/`** when present. Never embed logic in `user_data`, inline Lambda
  code, or Terraform `local-exec` provisioners.
- **Secrets never enter the repo.** Cognito IDs are public build-time values
  and are fine; anything else belongs in GitHub environment secrets.
- **Nothing identifying is committed.** Domain, GitHub owner, project slug and
  state bucket come from gitignored `terraform.tfvars` locally and `TF_VAR_*`
  (sourced from GitHub Actions variables) in CI. Only `.example` files are
  tracked. A fork needs configuration, not a find-and-replace.

---

## 3. Tech Stack

### Frontend — `frontend/`

| Item | Version / detail |
|---|---|
| Framework | Next.js `16.3.0` — App Router exclusively, static export |
| Language | TypeScript `5.9.3`, `strict: true` |
| React | `19.2.4` |
| Styling | Tailwind CSS `^4`, `tw-animate-css` |
| UI primitives | `shadcn/ui ^4.7` |
| Auth | AWS Amplify `^6.17`, `@aws-amplify/ui-react ^6.15` |
| Icons | `lucide-react ^1.16` |
| Class utilities | `clsx`, `tailwind-merge`, `class-variance-authority` |
| Linting | `eslint ^9`, `eslint-config-next 16.3.0`, `eslint-config-prettier` |
| Formatting | `prettier ^3.9` — `format:check` is a CI gate |
| Testing | `vitest ^3.2` |
| Node | `>=24` (`.nvmrc`, `engines`) — matches CI |

### Infrastructure — `infra/`

| Item | Version / detail |
|---|---|
| Terraform | `>= 1.10.0` |
| AWS provider | `hashicorp/aws ~> 6.0` |
| Time provider | `hashicorp/time ~> 0.12` |
| Primary region | `us-east-1` |
| Remote state | S3 with native lockfile (`use_lockfile = true`) |

### AWS services in use

S3 (static site + Terraform state), CloudFront + Origin Access Control,
CloudFront Functions, Cognito User Pool, ACM (looked up, not managed),
Route 53, IAM (GitHub OIDC provider, deploy roles, managed policies).

---

## 4. Local Development & Commands

```bash
# Frontend
cd frontend
npm ci
cp .env.example .env.local        # all three vars required — lib/env.ts throws
npm run dev                       # http://localhost:3000
npm run build                     # static export to out/ — must pass before merge
npm run lint
npm run typecheck
npm run test
npm run format:check              # npm run format to fix

# Terraform (replace <env> with dev | staging | prod)
cd infra/envs/<env>
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl          # bucket MUST match terraform.tfvars
terraform init -backend-config=backend.hcl
terraform fmt -recursive ../../
terraform validate
terraform plan
terraform apply                   # never -auto-approve in prod

# Regenerate provider lock hashes after a version bump
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64

# Pre-commit checks (mirrors .github/workflows/ci.yml)
./scripts/install-git-hooks.sh    # once per clone
./scripts/pre-commit-check.sh

# Full local deploy, no GitHub involved (mirrors .github/workflows/deploy.yml)
./scripts/deploy-local.sh <dev|staging|prod> [--help]
```

> **Never use local state.** Every root uses a *partial* S3 backend: the bucket
> is supplied at init time via `-backend-config` so it has exactly one source of
> truth. An S3 backend block cannot interpolate variables, so hardcoding the
> bucket in four `backend.tf` files lets it drift from
> `var.terraform_state_bucket` — which is what grants the deploy role access to
> it. When those disagree, CI fails with an `AccessDenied` that points nowhere
> near the cause. `pre-commit-check.sh` asserts they match.

> **Commit `.terraform.lock.hcl`.** It pins provider versions and records their
> checksums, which is what makes a CI apply reproducible and verifies the
> integrity of a binary that runs with your AWS credentials.

---

## 5. TypeScript / Frontend Standards

### TypeScript

- `strict: true` plus `noUncheckedIndexedAccess`, `noImplicitOverride`,
  `noFallthroughCasesInSwitch`, `noUnusedLocals`, `noUnusedParameters`.
  **Never use `any`** — use `unknown` and narrow explicitly. Indexed access
  yields `T | undefined`; handle it rather than asserting.
- Prefer `type` over `interface` for props and function signatures unless
  declaration merging is genuinely required.
- Use `satisfies` to validate object literals without widening. Avoid `!`
  non-null assertions; use optional chaining and explicit null checks.
- Declare shared response and domain types in `types/`, not inline in
  component files.

### Framework conventions

- Use the App Router (`app/`) exclusively. Never add a `pages/` directory.
- Server Components are the default. Add `"use client"` only for hooks, refs,
  event handlers, or browser APIs.
- The build is a **static export** (`output: "export"`). Server Actions, route
  handlers, ISR, and `next/image` optimization are unavailable — anything
  dynamic must run in the browser or in a service you add deliberately.
- Lazy-load heavy client-only components with `next/dynamic` and `{ ssr: false }`.

### Authentication

- All Amplify configuration goes through `lib/auth/amplifyClient.ts`, which runs
  at module load — never from a component render body.
- Read every environment value through `lib/env.ts`, never
  `process.env.NEXT_PUBLIC_*` directly. It validates at build time and throws,
  so a missing Cognito ID fails the build instead of shipping `undefined`.
- **Never store JWTs or Cognito tokens in `localStorage` or `sessionStorage`.**
  Note that Amplify's *default* store is `localStorage`, so this requires an
  explicit override: `amplifyClient.ts` calls
  `cognitoUserPoolsTokenProvider.setKeyValueStorage(new CookieStorage(...))`
  with `secure` + `SameSite=Strict`. Those cookies still are not `HttpOnly` —
  Amplify must read them.
- **There is no Content-Security-Policy.** It was removed deliberately: the App
  Router inlines its React Flight payload into every exported HTML file, which
  a strict `script-src 'self'` blocks — the browser refuses the inline scripts,
  `self.__next_f` stays empty, and hydration dies with React error #412. The
  only fixes were `'unsafe-inline'` or a per-build hash allowlist that couples
  the CSP to every frontend deploy; neither was wanted. Consequence: nothing
  stops an injected script from reading the Cognito tokens, so treat every new
  third-party script and dependency as a token-exfiltration risk. The removed
  policy is in the git history of `cloudfront-headers.tf` and `locals.tf` if it
  is ever reinstated.
- Gate authenticated UI with `<AuthGate>`; keep `<AmplifyProvider>` at the root
  layout so `configureAmplify()` runs before any auth hook.
- Amplify resolves cached sessions on the client only. Any auth-dependent
  render must defer until after hydration or the first client paint will not
  match the server HTML.

### Component quality

- Build on `components/ui/` primitives. Do not re-implement buttons, dialogs,
  inputs, or progress bars from scratch.
- Tailwind utility classes only — no raw inline styles for anything themeable.
  Compose conditional classes with `cn()` from `lib/utils.ts`.
- Colors come from the `--nord-*` custom properties in `app/globals.css`. Add
  new tokens there rather than scattering hex values through components.

---

## 6. Terraform & IaC Standards

### File-per-concern layout

Never put unrelated resource types in one file. Adding a new AWS service means
adding a new `.tf` file. Current layout under `infra/modules/static-site/`:

| File | Responsibility |
|---|---|
| `main.tf` | Shared data sources (hosted zone, caller identity, canonical user) |
| `locals.tf` | Computed name prefixes, account ID, custom response headers |
| `acm.tf` | ACM certificate lookup |
| `auth.tf` | Cognito User Pool + app client |
| `cloudfront.tf` | CloudFront distribution, OAC, URL-rewrite function, cache policy |
| `cloudfront-headers.tf` | Response headers policy (HSTS, frame/MIME/referrer) |
| `waf.tf` | Optional WAF web ACL (managed rules + rate limit) |
| `route53.tf` | A / AAAA alias records |
| `s3.tf` | Static site bucket, its four required companions, lifecycle, logging |
| `s3-logs.tf` | Access log bucket and its policy |
| `s3-policy.tf` | Site bucket policy (CloudFront OAC read, TLS-only deny) |
| `iam-github-oidc.tf` | Deploy-role managed policies and propagation sleeps |
| `variables.tf` | All input variable declarations |
| `outputs.tf` | All output declarations |
| `versions.tf` | Provider and Terraform version constraints |

`infra/bootstrap/` follows the same rule: `s3-state.tf`, `iam-oidc.tf`,
`iam-deploy-roles.tf`, `iam-local-dev.tf`, `iam-bootstrap-ci.tf`. Each
environment root has `versions.tf`, `providers.tf`, `variables.tf`, `main.tf`,
`backend.tf`, `outputs.tf`.

### Naming and tagging

- Resource names use `local.name_prefix` = `"${var.project_name}-${var.environment}"`.
  Do not add a separate `name` variable that duplicates it — two sources of
  truth for one string will drift.
- snake_case for Terraform labels; kebab-case for AWS resource names.
- `Environment`, `Project` and `ManagedBy` come from `default_tags` on the
  provider in each environment root, so they cannot be forgotten. Resources
  declare their own `Name`:

  ```hcl
  tags = {
    Name = "<descriptive-kebab-case-name>"
  }
  ```

  Resources inside `modules/static-site` still set all four explicitly, because
  a module cannot rely on the caller having configured `default_tags`.

### Variables and outputs

- Every `variable` requires `description` and `type`; include a `default` or a
  comment explaining why there isn't one.
- Use `validation` blocks for constrained values (see `environment`).
- Every `output` requires a `description`.

### IAM least privilege — non-negotiable

- **No wildcard `"*"` in `actions`.**
- **No wildcard `"*"` in `resources`** when a specific ARN is determinable at
  plan time. Where AWS genuinely offers no resource-level scope, add a comment
  saying so on that statement — every existing `"*"` in this repo has one.
- Never hardcode an account ID. Use `local.account_id`, which derives from
  `data.aws_caller_identity.current`.
- Use `data "aws_iam_policy_document"` with discrete `statement {}` blocks
  grouped by service, each with a unique CamelCase `sid`.
- Deploy-role trust must pin `token.actions.githubusercontent.com:sub` to the
  exact `repo:<owner>/<repo>:environment:<env>` value.
- Never attach `AdministratorAccess` or `PowerUserAccess` to any role.

### IAM propagation

Policy changes take seconds to propagate. Resources whose create permission
lives in a given policy must `depends_on` that policy's `time_sleep`. Each
`time_sleep` uses a `triggers` map keyed on the policy hash so it re-fires on
policy changes, not just on first create — without that, later applies race.

### S3 — private by default

Every `aws_s3_bucket` must be accompanied by all four of:

```hcl
aws_s3_bucket_public_access_block                    # all four block_* = true
aws_s3_bucket_ownership_controls                     # BucketOwnerEnforced
aws_s3_bucket_server_side_encryption_configuration   # AES256 (or aws:kms in prod)
aws_s3_bucket_versioning                             # Enabled
```

### Environment rules

- Always remote state. Never local state.
- Do not hardcode account IDs, regions, domains, or GitHub owners — use data
  sources and variables.
- `lifecycle { prevent_destroy = true }` is already applied to the stateful
  resources (site bucket, Cognito User Pool, Terraform state bucket) in **every**
  environment, plus AWS-side `deletion_protection` on the User Pool. Keep it
  that way: guidance to "remember to add this before the first prod apply" is
  guidance that eventually gets forgotten.
- Treat any unexpected `destroy` in a plan as a **blocker**. `deploy.yml`
  enforces this — it inspects `terraform show -json` and refuses to apply a plan
  containing a `delete` unless a manual run sets `allow_destroy`.

### HCL quality

- Complete blocks only. No `# TODO`, no `"REPLACE_ME"`. Everything must be
  deployable as written.
- Use `locals {}` for computed prefixes; never repeat interpolations inline.
- Run `terraform fmt -recursive` before every commit.

---

## 7. Post-Change Checklist

### Terraform changes

```
- [ ] terraform fmt -recursive && terraform validate (all four roots)
- [ ] terraform plan — diff contains only expected changes
- [ ] No unexpected destroy or replace actions
- [ ] IAM policies reviewed for wildcards — every "*" has a comment saying why
      AWS offers no resource-level scope for that action
- [ ] New S3 buckets have all four companion resources plus a TLS-only deny
- [ ] New resources carry Name (the other three tags come from default_tags)
- [ ] .terraform.lock.hcl regenerated and committed if versions changed
```

### Frontend changes

```
- [ ] cd frontend && npm run build — zero TypeScript errors
- [ ] cd frontend && npm run lint — clean
- [ ] cd frontend && npm run typecheck — clean
- [ ] cd frontend && npm run test — passing
- [ ] cd frontend && npm run format:check — clean
- [ ] No hardcoded Cognito IDs or AWS endpoints; new env vars go through lib/env.ts
- [ ] No JWT/token storage in localStorage or sessionStorage
- [ ] Auth-dependent UI defers until after hydration
```

### CI/CD changes

```
- [ ] Every action pinned to a full commit SHA with a trailing version comment
- [ ] id-token: write granted only to jobs that assume an AWS role
- [ ] cancel-in-progress stays false on any job that runs terraform apply
```

### Commit message format

```
feat(infra): <subject>        # new Terraform resource or module
fix(infra): <subject>         # policy correction, security fix
refactor(infra): <subject>    # restructure, plan is a no-op
feat(frontend): <subject>     # new component, page, or hook
fix(frontend): <subject>      # bug fix in the UI layer
feat(backend): <subject>      # API, worker, or server-side module
fix(backend): <subject>       # server-side bug fix
chore(ci): <subject>          # workflow change
chore: <subject>              # fmt, version bump, comment update
```
