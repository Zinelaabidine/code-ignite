"use client";

import { Amplify } from "aws-amplify";
import { cognitoUserPoolsTokenProvider } from "aws-amplify/auth/cognito";
import { CookieStorage } from "aws-amplify/utils";

import { env } from "@/lib/env";

/**
 * Configure Amplify Auth against the Cognito User Pool created by Terraform.
 *
 * Runs once, at module load, rather than during a component render — calling it
 * from a render body is a side effect that React may repeat (StrictMode renders
 * twice) and that is not guaranteed to complete before a child's auth hook
 * first runs.
 *
 * This template has no backend API — Amplify talks straight to Cognito. If you
 * add an API later, extend this config with an `API.REST` block.
 */

/**
 * Tokens go in cookies, not localStorage.
 *
 * Amplify's default browser store is localStorage, which is readable by any
 * script running on this origin. Since the browser holds the only credentials
 * in this architecture — there is no server session to fall back on — an XSS
 * would be a full account takeover.
 *
 * These cookies are still not HttpOnly (Amplify needs to read them from JS to
 * attach and refresh tokens), so this narrows the exposure rather than closing
 * it. `sameSite: "strict"` blocks cross-site sends and `secure` keeps them off
 * plaintext connections, but no Content-Security-Policy is served, so any
 * script that executes on this origin can read them.
 */
function configureTokenStorage(): void {
  cognitoUserPoolsTokenProvider.setKeyValueStorage(
    new CookieStorage({
      domain: window.location.hostname,
      // `secure` must be false on http://localhost or the cookie is dropped
      // and sign-in silently fails in local development.
      secure: window.location.protocol === "https:",
      path: "/",
      sameSite: "strict",
      // Matches refresh_token_validity in infra/modules/static-site/auth.tf.
      expires: 7,
    }),
  );
}

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: env.userPoolId,
      userPoolClientId: env.userPoolClientId,
      loginWith: {
        email: true,
      },
    },
  },
});

if (typeof window !== "undefined") {
  configureTokenStorage();
}
