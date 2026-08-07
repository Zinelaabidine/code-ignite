# Frontend

Next.js 16 (App Router) + TypeScript + Tailwind 4, with AWS Cognito
authentication via Amplify. Builds to a static export (`out/`) that is synced to
S3 and served through CloudFront.

## Commands

```bash
npm install
npm run dev      # http://localhost:3000
npm run build    # static export to out/ (must pass before any merge)
npm run lint
```

## Environment

Copy `.env.example` to `.env.local` and fill in the two Cognito values from
`terraform output` in `infra/envs/dev`. In CI, `deploy.yml` injects them from
Terraform outputs at build time.

## Layout

| Path                                    | Purpose                                               |
| --------------------------------------- | ----------------------------------------------------- |
| `app/page.tsx`                          | Single gated route — auth shell or `SignedInHome`     |
| `app/layout.tsx`                        | Root layout, fonts, `AmplifyProvider`                 |
| `app/globals.css`                       | Tailwind entry, `--nord-*` palette, Amplify overrides |
| `components/layout/AuthGate.tsx`        | Amplify `<Authenticator>` shell (sign in / sign up)   |
| `components/layout/AmplifyProvider.tsx` | Calls `configureAmplify()` on the client              |
| `components/home/SignedInHome.tsx`      | Authenticated placeholder — replace this              |
| `components/ui/`                        | shadcn/ui primitives                                  |
| `lib/auth/amplifyClient.ts`             | Amplify Cognito configuration                         |

## Conventions

- `strict: true`; never use `any` — narrow from `unknown`.
- Server Components by default; add `"use client"` only for hooks, refs,
  event handlers, or browser APIs.
- Never store JWTs or Cognito tokens in `localStorage`/`sessionStorage` —
  rely on Amplify's managed session storage.
- Tailwind utilities only; compose conditional classes with `cn()`.
- Build shared UI from `components/ui/` primitives rather than re-implementing
  buttons, dialogs, or inputs.
