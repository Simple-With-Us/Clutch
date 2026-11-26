import { describe, expect, it } from "vitest";
import {
  APP_GROUP_ENTITLEMENT,
  WILDCARD_GROUP,
  appGroupsFromPlistXml,
  carriesGroup,
  extractPlistXml,
  profileAppGroups
} from "../scripts/ios-fleet/mobileprovision.mjs";

const REQUIRED_GROUP = "group.codes.clutch.ios";

function plistXml(entitlementsXml: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AppIDName</key><string>Clutch iOS</string>
    <key>application-identifier</key><string>TEAMID.codes.clutch.ios</string>
    ${entitlementsXml}
</dict>
</plist>`;
}

function groupsXml(groups: string[]): string {
  return `<key>com.apple.security.application-groups</key>
    <array>
        ${groups.map((g) => `<string>${g}</string>`).join("\n        ")}
    </array>`;
}

function base64Profile(xml: string): string {
  return Buffer.from(xml, "utf8").toString("base64");
}

const NO_GROUPS = base64Profile(plistXml(""));
const NAMED_GROUP = base64Profile(plistXml(groupsXml([REQUIRED_GROUP])));
const WILDCARD = base64Profile(plistXml(groupsXml(["*"])));
const MULTIPLE_GROUPS = base64Profile(plistXml(groupsXml([REQUIRED_GROUP, "group.other"])));

describe("mobileprovision.mjs — App Group extraction", () => {
  describe("extractPlistXml", () => {
    it("extracts the XML plist from profile bytes", () => {
      const buf = Buffer.from(plistXml(""), "utf8");
      const result = extractPlistXml(buf);
      expect(result).toContain("<?xml");
      expect(result).toContain("</plist>");
      expect(result).toContain("Clutch iOS");
    });

    it("returns null for empty input", () => {
      expect(extractPlistXml(Buffer.alloc(0))).toBeNull();
      expect(extractPlistXml(null as unknown as Buffer)).toBeNull();
    });

    it("returns null when no plist markers are present", () => {
      expect(extractPlistXml(Buffer.from("not a plist", "utf8"))).toBeNull();
    });
  });

  describe("appGroupsFromPlistXml", () => {
    it("returns empty array when no application-groups entitlement", () => {
      const xml = plistXml("");
      expect(appGroupsFromPlistXml(xml)).toEqual([]);
    });

    it("reads a single named group", () => {
      const xml = plistXml(groupsXml([REQUIRED_GROUP]));
      expect(appGroupsFromPlistXml(xml)).toEqual([REQUIRED_GROUP]);
    });

    it("reads multiple groups", () => {
      const xml = plistXml(groupsXml([REQUIRED_GROUP, "group.other"]));
      expect(appGroupsFromPlistXml(xml)).toEqual([REQUIRED_GROUP, "group.other"]);
    });

    it("reads the wildcard group", () => {
      const xml = plistXml(groupsXml(["*"]));
      expect(appGroupsFromPlistXml(xml)).toEqual(["*"]);
    });

    it("returns empty array for null input", () => {
      expect(appGroupsFromPlistXml(null as unknown as string)).toEqual([]);
    });
  });

  describe("profileAppGroups", () => {
    it("returns null for empty base64", () => {
      expect(profileAppGroups("")).toBeNull();
      expect(profileAppGroups(null as unknown as string)).toBeNull();
    });

    it("returns null for invalid base64", () => {
      expect(profileAppGroups("!!!not-base64!!!")).toBeNull();
    });

    it("returns empty array when profile has no groups", () => {
      expect(profileAppGroups(NO_GROUPS)).toEqual([]);
    });

    it("reads a single named group from base64 profile", () => {
      expect(profileAppGroups(NAMED_GROUP)).toEqual([REQUIRED_GROUP]);
    });

    it("reads the wildcard group from base64 profile", () => {
      expect(profileAppGroups(WILDCARD)).toEqual(["*"]);
    });

    it("reads multiple groups from base64 profile", () => {
      expect(profileAppGroups(MULTIPLE_GROUPS)).toEqual([REQUIRED_GROUP, "group.other"]);
    });
  });

  describe("carriesGroup", () => {
    it("returns true when no required group is set", () => {
      expect(carriesGroup([], "")).toBe(true);
      expect(carriesGroup([REQUIRED_GROUP], "")).toBe(true);
    });

    it("returns false for null/undefined groups", () => {
      expect(carriesGroup(null as unknown as string[], REQUIRED_GROUP)).toBe(false);
      expect(carriesGroup(undefined as unknown as string[], REQUIRED_GROUP)).toBe(false);
    });

    it("returns true when the group is present", () => {
      expect(carriesGroup([REQUIRED_GROUP], REQUIRED_GROUP)).toBe(true);
      expect(carriesGroup([REQUIRED_GROUP, "group.other"], REQUIRED_GROUP)).toBe(true);
    });

    it("returns false when the group is absent", () => {
      expect(carriesGroup([], REQUIRED_GROUP)).toBe(false);
      expect(carriesGroup(["group.other"], REQUIRED_GROUP)).toBe(false);
    });

    it("wildcard satisfies any required group", () => {
      expect(carriesGroup(["*"], REQUIRED_GROUP)).toBe(true);
      expect(carriesGroup(["*"], "group.anything.else")).toBe(true);
      expect(carriesGroup([REQUIRED_GROUP, "*"], REQUIRED_GROUP)).toBe(true);
    });

    it("exposes the WILDCARD_GROUP constant", () => {
      expect(WILDCARD_GROUP).toBe("*");
    });

    it("exposes the APP_GROUP_ENTITLEMENT constant", () => {
      expect(APP_GROUP_ENTITLEMENT).toBe("com.apple.security.application-groups");
    });
  });
});
