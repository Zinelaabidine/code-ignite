## What changed

<!-- One or two sentences. What does this do, and why? -->

## Checklist

<!-- Delete the sections that do not apply. -->

### Terraform changes

- [ ] `terraform fmt -recursive infra/` and `terraform validate` pass
- [ ] `terraform plan` reviewed — the diff contains only expected changes
- [ ] **No unexpected `destroy` or `replace` actions** (CI blocks these; a manual
      `workflow_dispatch` with `allow_destroy` is required to override)
- [ ] IAM policies reviewed for wildcards — every remaining `"*"` has a comment
      saying why AWS offers no resource-level scope
- [ ] New S3 buckets have all four companion resources (public access block,
      ownership controls, encryption, versioning) plus a TLS-only policy
- [ ] New resources carry `Name`; the other three tags come from `default_tags`
- [ ] `.terraform.lock.hcl` updated and committed if provider versions changed

### Frontend changes

- [ ] `npm run build`, `npm run lint`, `npm run typecheck`, `npm run test` pass
- [ ] `npm run format:check` passes
- [ ] No hardcoded Cognito IDs or AWS endpoints
- [ ] No JWT or Cognito token written to `localStorage` / `sessionStorage`
- [ ] Auth-dependent UI defers until after hydration

### Security

- [ ] No secrets, keys, or account IDs added to the repo
- [ ] Trust policies and IAM grants unchanged, or explicitly called out below

<!-- If this touches infra/bootstrap or the deploy role's permissions, say so
     here and explain the blast radius. -->
