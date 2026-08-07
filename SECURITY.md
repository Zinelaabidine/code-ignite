# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Report it privately through GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
(Security tab → Report a vulnerability), or email the repository owner.

Expect an acknowledgement within a few days. Please include what you did, what
happened, and what you expected — a proof of concept is welcome but not
required.

## Security model

This template has no backend. The browser holds the only credentials, which
shapes everything below.

| Boundary | What enforces it |
|---|---|
| Who can sign in | Cognito User Pool password policy, optional TOTP MFA, optional threat protection |
| Token theft via XSS | Cookie token storage with `SameSite=Strict` only. **No CSP is sent** — see Known limitations |
| Token lifetime | Access/ID tokens 60 min, refresh tokens 7 days — all configurable per environment |
| Who can read the S3 bucket | Bucket is private; only the CloudFront distribution's ARN is allowed, via Origin Access Control |
| Transport | `redirect-to-https` on CloudFront, TLS 1.2+ only, HSTS with preload, and an explicit `aws:SecureTransport` deny on every bucket |
| Who can deploy | GitHub OIDC only. No long-lived AWS keys exist. Per-environment roles, trust pinned to `repo:<owner>/<repo>:environment:<env>` |
| Who can change the trust chain | Only `bootstrap.yml` on `main`, via a role pinned to that exact `job_workflow_ref`, behind a required-reviewer environment |
| Local developer access | A separate role requiring MFA no older than one hour |

### Known limitations

These are deliberate trade-offs, not oversights:

- **Cognito tokens are readable by JavaScript.** Amplify must read them to
  attach and refresh them, so they cannot be `HttpOnly`. Moving them from
  `localStorage` to `SameSite=Strict` cookies narrows the exposure but does not
  remove it.
- **No Content-Security-Policy is sent.** It was removed because Next.js App
  Router inlines its React Flight payload into every exported HTML file, which
  a strict `script-src 'self'` blocks — hydration fails with React error #412.
  The alternatives were `'unsafe-inline'`, which defeats the point, or a
  per-build SHA-256 allowlist that ties the CloudFront policy to every frontend
  deploy. Neither was adopted. The consequence is direct: any script that
  executes on this origin can read the Cognito tokens, and there is no second
  line of defence. Vet every dependency and never inject unescaped user content
  into the DOM.
- **Cognito IDs are public.** The User Pool ID and the SPA client ID are baked
  into the bundle by design. They are identifiers, not secrets — the pool's
  password policy and token settings are what protect accounts.
- **The log bucket has ACLs enabled.** CloudFront standard logging cannot be
  authorised with a bucket policy. Only the AWS log-delivery canonical user is
  granted access. Set `enable_access_logging = false` to opt out.
- **WAF and Cognito threat protection are off by default.** Both are billed per
  use. Turn them on per environment with `enable_waf` and
  `advanced_security_mode` — recommended for anything with real users.

## Required repository settings

The code cannot enforce these; configure them in GitHub:

- Branch protection on `main`, `staging` and `dev`: require the `ci` checks,
  require review, disallow force pushes.
- Environment protection on `prod`: **required reviewers**. A push to `main`
  applies to production, and this is the only thing that puts a human in front
  of it.
- Environment protection on `bootstrap`: required reviewers. That workflow
  manages the trust chain.
- Secret scanning and push protection: on.
