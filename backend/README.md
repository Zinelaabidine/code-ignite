# Backend

Reserved for server-side application code when the product needs it (API,
workers, shared domain logic). The template ships without a backend: the
browser talks to Cognito via Amplify and static assets come from S3/CloudFront.

## Boundaries

- **Application logic** lives here (not in Terraform `user_data`, inline Lambda
  strings, or `local-exec` provisioners).
- **AWS resources** for that logic are defined in `infra/`, one `.tf` file per
  service, wired through the existing environment roots.
- **Browser UI** stays in `frontend/`.

## When you add a backend

Choose a stack (e.g. Lambda + API Gateway, container service) and add the
matching module under `infra/modules/`. Keep secrets in GitHub environment
secrets / SSM — never in the repo.

See `.cursor/rules/backend.mdc` for AI coding conventions in this folder.
