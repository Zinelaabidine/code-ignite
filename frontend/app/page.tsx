import AuthGate from "@/components/layout/AuthGate";
import SignedInHome from "@/components/home/SignedInHome";

/**
 * The whole site is a single gated route: unauthenticated visitors get the
 * Cognito sign-in / sign-up shell, authenticated ones get `SignedInHome`.
 *
 * To add real pages, create them under `app/` and wrap the shared segment in
 * `<AuthGate>` via a route-group layout (e.g. `app/(app)/layout.tsx`).
 */
export default function RootPage() {
  return (
    <AuthGate>
      <SignedInHome />
    </AuthGate>
  );
}
