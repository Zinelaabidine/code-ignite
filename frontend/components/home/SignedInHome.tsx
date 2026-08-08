"use client";

import { useAuthenticator } from "@aws-amplify/ui-react";
import { LogOut, TerminalSquare } from "lucide-react";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { parseUser } from "@/lib/auth/parseUser";

/**
 * Placeholder for whatever the authenticated app becomes. It exists to prove
 * the Cognito session is live and to give `signOut` a home — replace the body
 * with the real application shell.
 */
export default function SignedInHome() {
  const { user, signOut } = useAuthenticator((ctx) => [ctx.user]);

  const loginId = user?.signInDetails?.loginId ?? user?.username ?? "";
  const { displayName, initials } = parseUser(loginId);

  return (
    <main className="flex min-h-screen w-full items-center justify-center px-6 py-16">
      <div className="w-full max-w-md rounded-2xl border border-[var(--nord-hairline)] bg-[var(--nord-surface)] p-8 shadow-[0_12px_32px_rgba(43,42,38,0.08)]">
        <div className="flex items-center gap-4">
          <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-[var(--nord-pine)] text-sm font-semibold text-[var(--nord-cta-fg)]">
            {initials}
          </span>
          <div className="min-w-0">
            <p className="truncate text-base font-semibold text-[var(--nord-ink)]">
              {displayName}
            </p>
            <p className="truncate text-sm text-[var(--nord-slate)]">
              {loginId}
            </p>
          </div>
        </div>

        <p className="mt-6 text-sm leading-relaxed text-[var(--nord-slate)]">
          You are signed in. This page is the template&apos;s authenticated
          placeholder — start building here.
        </p>

        <Button
          className="mt-6 w-full"
          nativeButton={false}
          render={<Link href="/playground" />}
        >
          <TerminalSquare className="h-4 w-4" />
          Open playground
        </Button>

        <Button onClick={signOut} className="mt-3 w-full" variant="outline">
          <LogOut className="h-4 w-4" />
          Sign out
        </Button>
      </div>
    </main>
  );
}
