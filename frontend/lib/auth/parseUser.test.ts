import { describe, expect, it } from "vitest";

import { parseUser } from "@/lib/auth/parseUser";

describe("parseUser", () => {
  it("splits a dotted local part into first and last name", () => {
    expect(parseUser("ada.lovelace@example.com")).toEqual({
      displayName: "Ada Lovelace",
      initials: "AL",
    });
  });

  it("treats underscores and hyphens as separators", () => {
    expect(parseUser("grace_hopper@example.com").displayName).toBe(
      "Grace Hopper",
    );
    expect(parseUser("alan-turing@example.com").displayName).toBe(
      "Alan Turing",
    );
  });

  it("uses the middle segments only for the name, not the initials", () => {
    const { displayName, initials } = parseUser("jean.luc.picard@example.com");
    expect(displayName).toBe("Jean Picard");
    expect(initials).toBe("JL");
  });

  it("falls back to a single capitalised word", () => {
    expect(parseUser("root@example.com")).toEqual({
      displayName: "Root",
      initials: "R",
    });
  });

  it("handles a login ID with no domain", () => {
    expect(parseUser("solo").displayName).toBe("Solo");
  });

  // The regression guards: each of these used to throw on an index access.
  it("does not throw on an empty login ID", () => {
    expect(parseUser("")).toEqual({ displayName: "User", initials: "?" });
  });

  it("does not throw when the local part is empty", () => {
    expect(() => parseUser("@example.com")).not.toThrow();
    expect(parseUser("@example.com").initials).toBe("?");
  });

  it("does not throw on separators alone", () => {
    expect(() => parseUser("..._---@example.com")).not.toThrow();
    expect(parseUser("..._---@example.com").initials).toBe("?");
  });
});
