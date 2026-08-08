import type { ReactNode } from "react";

import AuthGate from "@/components/layout/AuthGate";

/**
 * Shared layout for the authenticated app segment. `<AuthGate>` moves here
 * (rather than living inside each page, the way `app/page.tsx` still does)
 * so it mounts once per segment instead of once per route — see stage 5 of
 * `docs/code-playground-implementation-plan.md`. `app/page.tsx` is
 * deliberately left as-is: it's the landing route, outside this group.
 */
export default function AppLayout({ children }: { children: ReactNode }) {
  return <AuthGate>{children}</AuthGate>;
}
