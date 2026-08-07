"use client";

import {
  Authenticator,
  ThemeProvider,
  useAuthenticator,
  type Theme,
} from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import { Boxes } from "lucide-react";
import React, { useState, useSyncExternalStore } from "react";

import BrandMark from "@/components/layout/BrandMark";

/**
 * Theme override for the Amplify Authenticator so it inherits the app palette
 * (see `--nord-*` in app/globals.css) instead of Amplify's default AWS look.
 */
const authenticatorTheme: Theme = {
  name: "app-template",
  tokens: {
    colors: {
      brand: {
        primary: {
          10: { value: "#e7ede9" },
          20: { value: "#cfdcd4" },
          40: { value: "#4e827c" },
          60: { value: "#3f6b66" },
          80: { value: "#23433a" },
          90: { value: "#1c382f" },
          100: { value: "#14261f" },
        },
      },
      font: {
        interactive: { value: "#23433a" },
        primary: { value: "#1c1f21" },
        secondary: { value: "#45494c" },
      },
      background: {
        primary: { value: "#fefefd" },
        secondary: { value: "#fbfaf8" },
      },
      border: {
        primary: { value: "rgba(52, 56, 59, 0.14)" },
        secondary: { value: "rgba(52, 56, 59, 0.10)" },
        focus: { value: "#4e827c" },
      },
    },
    radii: {
      small: { value: "0.5rem" },
      medium: { value: "0.75rem" },
      large: { value: "1rem" },
    },
    shadows: {
      small: { value: "0 1px 2px rgba(43, 42, 38, 0.06)" },
      medium: { value: "0 4px 12px rgba(43, 42, 38, 0.08)" },
      large: { value: "0 12px 32px rgba(43, 42, 38, 0.10)" },
    },
    components: {
      authenticator: {
        router: {
          borderColor: { value: "{colors.border.secondary.value}" },
          boxShadow: { value: "{shadows.large.value}" },
        },
      },
      button: {
        primary: {
          backgroundColor: { value: "{colors.brand.primary.80.value}" },
          color: { value: "#f4f2ec" },
          _hover: {
            backgroundColor: { value: "{colors.brand.primary.90.value}" },
          },
          _focus: {
            backgroundColor: { value: "{colors.brand.primary.90.value}" },
          },
        },
        link: {
          color: { value: "{colors.brand.primary.80.value}" },
          _hover: {
            color: { value: "{colors.brand.primary.90.value}" },
            backgroundColor: { value: "transparent" },
          },
        },
      },
      fieldcontrol: {
        borderColor: { value: "{colors.border.primary.value}" },
        _focus: {
          borderColor: { value: "{colors.brand.primary.60.value}" },
          boxShadow: { value: "0 0 0 3px rgba(78, 130, 124, 0.18)" },
        },
      },
      tabs: {
        item: {
          color: { value: "{colors.font.secondary.value}" },
          _hover: { color: { value: "{colors.font.primary.value}" } },
          _active: {
            color: { value: "{colors.brand.primary.80.value}" },
            borderColor: { value: "{colors.brand.primary.80.value}" },
          },
        },
      },
    },
  },
};

type AuthGateProps = {
  children: React.ReactNode;
};

/**
 * Reads `?authTab=signup` so an external link can land directly on the
 * registration tab. Read straight off `window.location.search` instead of
 * `next/navigation`'s `useSearchParams` — that hook forces a Suspense
 * boundary that needs to re-resolve during static export, and this app has
 * no server to stream a resolution to. That combination crashed hydration
 * with React error #412 ("Connection closed"). A plain `useState` lazy
 * initializer reads the same value on the client with no such boundary.
 */
function readInitialAuthTab(): "signIn" | "signUp" {
  if (typeof window === "undefined") return "signIn";
  return new URLSearchParams(window.location.search).get("authTab") === "signup"
    ? "signUp"
    : "signIn";
}

function AuthGateRouter({ children }: AuthGateProps) {
  const [initialState] = useState(readInitialAuthTab);
  const { authStatus } = useAuthenticator((ctx) => [ctx.authStatus]);
  const isHydrated = useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );

  // Amplify resolves cached Cognito sessions on the client only, so authStatus
  // is always "configuring" during SSR while the client may already be
  // "authenticated". Defer auth-dependent UI until after hydration so the first
  // client paint matches the server HTML.
  if (!isHydrated || authStatus === "configuring") {
    return (
      <div className="auth-gate flex min-h-screen w-full items-center justify-center bg-[var(--nord-bg)] antialiased">
        <AuthFallback />
      </div>
    );
  }

  if (authStatus === "authenticated") {
    return <>{children}</>;
  }

  return (
    <div className="auth-gate min-h-screen w-full bg-[var(--nord-bg)] antialiased">
      <div className="grid min-h-screen lg:grid-cols-2">
        <div className="flex flex-col px-5 py-6 sm:px-8">
          <BrandMark />
          <div className="flex flex-1 items-center justify-center py-10">
            <Authenticator
              initialState={initialState}
              signUpAttributes={["email"]}
              loginMechanisms={["email"]}
            />
          </div>
        </div>

        <LoginVisualPanel />
      </div>
    </div>
  );
}

/**
 * Wraps its children in an Amplify `<Authenticator>`. Unauthenticated visitors
 * get a split-screen sign-in / sign-up shell; authenticated ones get `children`
 * with full access to `useAuthenticator()`.
 */
export default function AuthGate({ children }: AuthGateProps) {
  return (
    <ThemeProvider theme={authenticatorTheme}>
      <Authenticator.Provider>
        <AuthGateRouter>{children}</AuthGateRouter>
      </Authenticator.Provider>
    </ThemeProvider>
  );
}

function AuthFallback() {
  return (
    <div className="w-full max-w-sm animate-pulse rounded-2xl border border-[var(--nord-hairline)] bg-[var(--nord-bg)] p-8">
      <div className="h-5 w-32 rounded bg-[var(--nord-tint)]" />
      <div className="mt-6 h-10 w-full rounded bg-[var(--nord-tint)]" />
      <div className="mt-3 h-10 w-full rounded bg-[var(--nord-tint)]" />
      <div className="mt-6 h-10 w-full rounded bg-[var(--nord-tint)]" />
    </div>
  );
}

/** Decorative right-hand panel for the login shell. Replace or delete freely. */
function LoginVisualPanel() {
  return (
    <div className="relative hidden overflow-hidden border-l border-[var(--nord-hairline)] lg:block">
      <div
        className="absolute inset-0"
        style={{
          backgroundColor: "#eee9e0",
          backgroundImage:
            "linear-gradient(rgba(52,56,59,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(52,56,59,0.05) 1px, transparent 1px)",
          backgroundSize: "48px 48px",
        }}
      />
      <div
        className="absolute inset-0 opacity-80"
        style={{
          backgroundImage:
            "radial-gradient(45% 45% at 30% 30%, rgba(78,130,124,.20), transparent 65%), radial-gradient(40% 40% at 75% 65%, rgba(35,67,58,.16), transparent 65%)",
        }}
      />

      <div className="relative flex h-full flex-col items-center justify-center gap-8 px-12 text-center">
        <span className="flex h-20 w-20 items-center justify-center rounded-3xl border border-[var(--nord-hairline)] bg-[var(--nord-tint)] text-[var(--nord-teal)] backdrop-blur-sm">
          <Boxes className="h-9 w-9" strokeWidth={1.5} />
        </span>
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-[var(--nord-ink)]">
            Sign in to continue.
          </h2>
          <p className="mt-2 max-w-sm text-sm leading-relaxed text-[var(--nord-slate)]">
            Accounts are managed by Amazon Cognito. Create one in seconds and
            confirm it with the code sent to your email.
          </p>
        </div>
      </div>
    </div>
  );
}
