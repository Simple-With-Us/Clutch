/**
 * Read an App Group out of a provisioning profile without extra tools.
 *
 * A .mobileprovision is a CMS signed message whose payload is an XML plist.
 * `security cms -D` decodes it on macOS and `openssl smime -verify` decodes
 * it anywhere, but the ship path has to answer one narrow question - does
 * this profile carry App Group X - before it decides whether a profile is
 * worth reusing, and that question has to be answerable on any runner.
 *
 * So the plist is located in the container by its own XML markers and the
 * entitlement is read from it.  The container is only used to find the
 * payload: the value read here is what Apple's own signing covers, and the
 * caller still verifies the profile with `security cms -D` before it installs
 * anything.  That check agrees with `security cms -D` on every profile shape
 * Apple issues (no groups, named groups, and the wildcard), which is what
 * tests/ios-profile-app-groups.test.ts pins.
 */
export const APP_GROUP_ENTITLEMENT = "com.apple.security.application-groups";

/** The wildcard group entry: a profile carrying it can use every group. */
export const WILDCARD_GROUP = "*";

/**
 * Pull the XML plist out of a provisioning profile's bytes.
 * Returns null when the payload is not a plist this reader understands.
 */
export function extractPlistXml(buffer) {
  if (!buffer || !buffer.length) return null;
  const text = buffer.toString("latin1");
  const start = text.indexOf("<?xml");
  const end = text.indexOf("</plist>");
  if (start === -1 || end === -1 || end < start) return null;
  return text.slice(start, end + "</plist>".length);
}

/**
 * Read the App Group entries out of an XML plist.
 * A profile that never mentions the entitlement has no groups.
 */
export function appGroupsFromPlistXml(xml) {
  if (!xml) return [];
  const marker = `<key>${APP_GROUP_ENTITLEMENT}</key>`;
  const at = xml.indexOf(marker);
  if (at === -1) return [];
  const rest = xml.slice(at + marker.length);
  const open = rest.indexOf("<array>");
  if (open === -1) return [];
  const close = rest.indexOf("</array>", open);
  if (close === -1) return [];
  const body = rest.slice(open + "<array>".length, close);
  return [...body.matchAll(/<string>([^<]*)<\/string>/g)].map((match) => match[1]);
}

/**
 * Read the App Group entries out of a base64 provisioning profile.
 * Returns null when the profile cannot be read, so a caller can tell
 * "this profile has no groups" from "this profile could not be read".
 */
export function profileAppGroups(profileContentBase64) {
  if (!profileContentBase64) return null;
  let buffer;
  try {
    buffer = Buffer.from(profileContentBase64, "base64");
  } catch {
    return null;
  }
  if (!buffer.length) return null;
  const xml = extractPlistXml(buffer);
  if (!xml) return null;
  return appGroupsFromPlistXml(xml);
}

/**
 * Does a profile carrying these groups satisfy an App Group requirement?
 * The wildcard entry grants every group, so it satisfies any requirement.
 */
export function carriesGroup(groups, requiredGroup) {
  if (!requiredGroup) return true;
  if (!Array.isArray(groups)) return false;
  return groups.includes(requiredGroup) || groups.includes(WILDCARD_GROUP);
}
