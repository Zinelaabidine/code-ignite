"use client";

import type { ReactNode } from "react";

// Importing for the side effect is the point: the module configures Amplify at
// load time. Doing it here, in a client component at the root of the tree,
// guarantees configuration completes before any descendant's auth hook runs —
// and before React renders anything, so StrictMode's double render cannot
// repeat it.
import "@/lib/auth/amplifyClient";

type AmplifyProviderProps = {
  children: ReactNode;
};

export default function AmplifyProvider({ children }: AmplifyProviderProps) {
  return <>{children}</>;
}
