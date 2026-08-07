import type { NextConfig } from "next";
import path from "node:path";

const nextConfig: NextConfig = {
  // `output: 'export'` is only valid for `next build` (static S3 + CloudFront
  // deploy), not for `next dev` — applying it in dev causes the server to hang.
  ...(process.env.NODE_ENV === "production"
    ? { output: "export" as const }
    : {}),
  turbopack: {
    // Pin the workspace root to frontend/ so a sibling package-lock.json in the
    // repo root cannot confuse module resolution during HMR.
    root: path.resolve(__dirname),
  },
  devIndicators: false,
};

export default nextConfig;
