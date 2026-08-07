/**
 * Build-time environment contract.
 *
 * Next.js inlines `process.env.NEXT_PUBLIC_*` at build time, so a missing value
 * does not fail the build — it produces a bundle with `undefined` baked in, and
 * the app breaks at runtime with nothing in CI to show for it. This module
 * turns that into a build failure instead.
 *
 * Values come from `.github/workflows/deploy.yml`, which reads them from
 * Terraform outputs. For local development they live in `frontend/.env.local`
 * (see `.env.example`).
 *
 * Each variable is read as a literal property access. `process.env[name]` is
 * NOT substituted by the Next.js compiler, so a dynamic lookup would always be
 * undefined in the browser bundle.
 */

export type PublicEnv = {
  readonly region: string;
  readonly userPoolId: string;
  readonly userPoolClientId: string;
};

const missing: string[] = [];

function required(name: string, value: string | undefined): string {
  if (!value) {
    missing.push(name);
    return "";
  }
  return value;
}

const region = required(
  "NEXT_PUBLIC_AWS_REGION",
  process.env.NEXT_PUBLIC_AWS_REGION,
);
const userPoolId = required(
  "NEXT_PUBLIC_USER_POOL_ID",
  process.env.NEXT_PUBLIC_USER_POOL_ID,
);
const userPoolClientId = required(
  "NEXT_PUBLIC_CLIENT_ID",
  process.env.NEXT_PUBLIC_CLIENT_ID,
);

if (missing.length > 0) {
  throw new Error(
    `Missing required environment variables: ${missing.join(", ")}. ` +
      "Copy frontend/.env.example to frontend/.env.local and fill it in from " +
      "`terraform output`, or check the build step in .github/workflows/deploy.yml.",
  );
}

export const env: PublicEnv = { region, userPoolId, userPoolClientId };
