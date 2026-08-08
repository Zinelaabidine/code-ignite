import { afterEach, describe, expect, it, vi } from "vitest";

const REQUIRED_ENV = {
  NEXT_PUBLIC_AWS_REGION: "us-east-1",
  NEXT_PUBLIC_USER_POOL_ID: "us-east-1_test",
  NEXT_PUBLIC_CLIENT_ID: "test-client-id",
};

function stubRequiredEnv(): void {
  vi.stubEnv("NEXT_PUBLIC_AWS_REGION", REQUIRED_ENV.NEXT_PUBLIC_AWS_REGION);
  vi.stubEnv("NEXT_PUBLIC_USER_POOL_ID", REQUIRED_ENV.NEXT_PUBLIC_USER_POOL_ID);
  vi.stubEnv("NEXT_PUBLIC_CLIENT_ID", REQUIRED_ENV.NEXT_PUBLIC_CLIENT_ID);
}

async function loadEnv() {
  vi.resetModules();
  const mod = await import("./env");
  return mod.env;
}

describe("env", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it("throws naming every missing required variable", async () => {
    // Simulate "unset" by stubbing to an empty string — required() treats
    // any falsy value as missing, so this exercises the same code path.
    vi.stubEnv("NEXT_PUBLIC_AWS_REGION", "");
    vi.stubEnv("NEXT_PUBLIC_USER_POOL_ID", "");
    vi.stubEnv("NEXT_PUBLIC_CLIENT_ID", "");

    vi.resetModules();
    await expect(import("./env")).rejects.toThrow(
      /NEXT_PUBLIC_AWS_REGION.*NEXT_PUBLIC_USER_POOL_ID.*NEXT_PUBLIC_CLIENT_ID/s,
    );
  });

  it("throws when only one required variable is missing", async () => {
    stubRequiredEnv();
    vi.stubEnv("NEXT_PUBLIC_CLIENT_ID", "");

    vi.resetModules();
    await expect(import("./env")).rejects.toThrow(/NEXT_PUBLIC_CLIENT_ID/);
  });

  it("resolves apiBaseUrl to null when unset, without failing the build", async () => {
    stubRequiredEnv();
    vi.stubEnv("NEXT_PUBLIC_API_BASE_URL", "");

    const env = await loadEnv();
    expect(env.apiBaseUrl).toBeNull();
    expect(env.region).toBe(REQUIRED_ENV.NEXT_PUBLIC_AWS_REGION);
    expect(env.userPoolId).toBe(REQUIRED_ENV.NEXT_PUBLIC_USER_POOL_ID);
    expect(env.userPoolClientId).toBe(REQUIRED_ENV.NEXT_PUBLIC_CLIENT_ID);
  });

  it("resolves apiBaseUrl to the configured string when set", async () => {
    stubRequiredEnv();
    vi.stubEnv("NEXT_PUBLIC_API_BASE_URL", "http://localhost:8000");

    const env = await loadEnv();
    expect(env.apiBaseUrl).toBe("http://localhost:8000");
  });
});
