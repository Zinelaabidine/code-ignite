export type ParsedUser = {
  displayName: string;
  initials: string;
};

/** Uppercase the first character and leave the rest alone. */
function capitalise(word: string): string {
  if (word.length === 0) {
    return word;
  }
  return word.charAt(0).toUpperCase() + word.slice(1);
}

/**
 * Derive a display name and initials from a Cognito email or username.
 *
 * Handles the awkward inputs deliberately: an empty login ID, an address with
 * no local part, and separators that produce empty segments. A signed-in user
 * with a strange address should still get a sensible avatar rather than a
 * crash in the layout.
 */
export function parseUser(loginId: string): ParsedUser {
  const local = loginId.split("@")[0] ?? "";
  const parts = local.split(/[._-]/).filter((part) => part.length > 0);

  const first = parts[0];
  const last = parts[parts.length - 1];

  if (first === undefined) {
    // Nothing usable in the login ID at all.
    return { displayName: loginId || "User", initials: "?" };
  }

  const displayName =
    parts.length >= 2 && last !== undefined
      ? `${capitalise(first)} ${capitalise(last)}`
      : capitalise(first);

  const initials = parts
    .slice(0, 2)
    .map((part) => part.charAt(0).toUpperCase())
    .join("");

  return { displayName, initials: initials || "?" };
}
