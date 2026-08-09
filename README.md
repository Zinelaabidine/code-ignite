# App Template — Next.js + Cognito on AWS

A minimal, production-shaped starting point for a web app on AWS: a Next.js
static export served from S3 behind CloudFront, with sign-up and sign-in handled
by an Amazon Cognito User Pool. Infrastructure is Terraform; deployment is
GitHub Actions over OIDC with no long-lived AWS keys.

There is no backend API, no database, and no compute layer — add them when the
product needs them.

## What you get

```
Browser (Next.js static export)
  |  Cognito sign-up / sign-in  (AWS Amplify)
  v
Cognito User Pool
  ^
  |  IDs baked into the bundle at build time
CloudFront  ──►  S3 (private, Origin Access Control)
```

| Layer | What is provisioned |
|---|---|
| Hosting | Private S3 bucket + CloudFront distribution + OAC + `nextjs-url-rewrite` function |
| Security headers | CloudFront response headers policy: HSTS (preload), frame/MIME/referrer controls, Permissions-Policy. No CSP — see SECURITY.md |
| DNS / TLS | Route 53 A + AAAA alias records, ACM wildcard certificate (looked up, not managed) |
| Identity | Cognito User Pool + public SPA app client — email sign-up, optional TOTP MFA, optional threat protection, short token lifetimes |
| Observability | CloudFront standard access logs and S3 server access logs, with lifecycle expiry |
| Protection | Optional WAF (AWS managed rules + per-IP rate limit), `prevent_destroy` and deletion protection on stateful resources |
| CI/CD | GitHub OIDC provider, per-environment deploy roles, scoped managed policies, SHA-pinned actions |
| State | S3 remote state with native lockfile locking, versioned and TLS-only |

## Repository structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── ci.yml              # PR gate: lint, types, tests, build, tf validate, scans
│   │   ├── deploy.yml          # push: terraform apply + frontend deploy
│   │   ├── bootstrap.yml       # manual: state bucket, OIDC provider, IAM roles
│   │   └── codeql.yml          # SAST for the TypeScript
│   ├── dependabot.yml          # npm, github-actions, terraform
│   └── CODEOWNERS
├── frontend/                   # Next.js App Router, TypeScript, Tailwind 4
│   ├── app/                    # routes, root layout, globals.css
│   ├── components/             # AuthGate, AmplifyProvider, ui/ primitives
│   └── lib/
│       ├── env.ts              # build-time env contract (throws on missing)
│       └── auth/               # Amplify Cognito configuration
├── infra/
│   ├── common.tfvars            # project_name + shared values (gitignored)
│   ├── bootstrap/              # one-time: state bucket + OIDC + IAM roles
│   ├── envs/{dev,staging,prod}/  # one Terraform root per environment
│   └── modules/static-site/    # all AWS resources, one .tf file per service
└── scripts/                    # git hooks, pre-commit checks, local deploy
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

   Only set `HOSTED_ZONE_NAME` / `CERTIFICATE_DOMAIN_NAME` again at the
   environment level if a specific environment genuinely needs a different
   zone or certificate than the repository-level default.

6. **Turn on the protections the code cannot enforce** — see
   [SECURITY.md](SECURITY.md#required-repository-settings). At minimum: required
   reviewers on `prod` and `bootstrap`, and branch protection requiring the `ci`
   checks. **A push to `main` applies to production**; the `prod` environment's
   reviewer rule is the only thing that puts a human in front of that.

7. **Update [`.github/CODEOWNERS`](.github/CODEOWNERS)** with your GitHub handle.

8. **Push.** `dev` → dev, `staging` → staging, `main` → prod.

## Environments

| Environment | Branch | Terraform root |
|---|---|---|
| `dev` | `dev` | `infra/envs/dev` |
| `staging` | `staging` | `infra/envs/staging` |
| `prod` | `main` | `infra/envs/prod` |

`dev` also sets `attach_deploy_policies_to_local_dev_role = true`. That role is
account-global and shared by all three environments, so exactly one environment
should own its policy attachments.

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

# All checks at once (mirrors ci.yml)
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
`--assume-role`).

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

The browser holds the only credentials in this architecture, which shapes most
of the design decisions. See [SECURITY.md](SECURITY.md) for the security model,
the known limitations, and how to report a vulnerability.

Two things worth knowing up front:

- **There is no CSP.** It was removed because Next's App Router inlines its
  React Flight payload, which `script-src 'self'` blocks. Amplify's tokens are
  readable by any script on the origin and nothing now prevents an injected one
  from running, so vet every third-party script and dependency accordingly.
- **Destructive plans are blocked.** CI refuses to apply a plan containing a
  `delete`. Override deliberately with a `workflow_dispatch` run and the
  `allow_destroy` input.

## Adding a backend

This template deliberately ships without one. When you need server-side logic,
add a new `.tf` file per service under `infra/modules/static-site/` (the
file-per-concern convention), extend the deploy role's managed policies with
narrowly scoped statements, and wire the endpoint into `frontend/lib/auth/amplifyClient.ts` as an `API.REST`
entry.

## License

MIT — see [LICENSE](LICENSE).
