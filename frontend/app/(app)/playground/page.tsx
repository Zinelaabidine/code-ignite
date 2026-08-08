import { ShieldAlert } from "lucide-react";

import PlaygroundShell from "@/components/playground/PlaygroundShell";
import { env } from "@/lib/env";

/**
 * `env.apiBaseUrl` is a build-time constant (inlined by Next.js the same way
 * on the server and the client), so this check is safe in a Server Component
 * with no hydration mismatch risk — unlike the auth status in `AuthGate`,
 * which genuinely differs between server and client and must defer past
 * hydration.
 */
export default function PlaygroundPage() {
  if (!env.apiBaseUrl) {
    return <ApiUnavailablePanel />;
  }
  return <PlaygroundShell apiBaseUrl={env.apiBaseUrl} />;
}

function ApiUnavailablePanel() {
  return (
    <main className="flex min-h-screen w-full items-center justify-center px-6 py-16">
      <div className="w-full max-w-md rounded-2xl border border-[var(--nord-hairline)] bg-[var(--nord-surface)] p-8 text-center shadow-[0_12px_32px_rgba(43,42,38,0.08)]">
        <span className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-[var(--nord-warning-tint)] text-[var(--nord-warning)]">
          <ShieldAlert className="h-6 w-6" />
        </span>
        <h1 className="mt-4 text-base font-semibold text-[var(--nord-ink)]">
          Playground not available in this environment
        </h1>
        <p className="mt-2 text-sm leading-relaxed text-[var(--nord-slate)]">
          No code-playground API is configured for this build. Set{" "}
          <code className="rounded bg-[var(--nord-bg-2)] px-1 py-0.5 font-mono text-xs">
            NEXT_PUBLIC_API_BASE_URL
          </code>{" "}
          (see <code className="font-mono text-xs">frontend/.env.example</code>)
          to point it at a running API.
        </p>
      </div>
    </main>
  );
}
