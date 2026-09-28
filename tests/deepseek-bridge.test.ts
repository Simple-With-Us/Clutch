import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The macOS shell is one Swift file compiled straight to a binary, so these
 *  assert on the source.  The credential reader is the part with real risk —
 *  it parses a live secrets file — so the parsing rules are pinned here even
 *  though the parser itself is Swift. */

const SWIFT = readFileSync(
  join(__dirname, "..", "src", "web", "dock-app", "HarnessWindow.swift"),
  "utf8",
);

describe("DeepSeek model bridge", () => {
  it("reads only the requested ref out of the credential store", () => {
    const body = swiftBody("static func credential(");
    expect(body).toContain("credentialRef");
    // The scan must key on the ref name, not take the first value it sees:
    // the same file also holds the browser-session secret.
    expect(body).toMatch(/guard name == credentialRef else \{ continue \}/);
  });

  it("stops at the end of the refs block instead of reading records", () => {
    // `records:` holds a different shape; a reader that kept going would pick
    // up `secret:` values.
    const body = swiftBody("static func credential(");
    expect(body).toContain("inRefs = trimmed == \"refs:\"");
    expect(body).toMatch(/if !line\.hasPrefix\(" "\)/);
  });

  it("unquotes a quoted scalar and rejects an empty one", () => {
    const body = swiftBody("static func credential(");
    expect(body).toContain("hasPrefix(\"\\\"\")");
    expect(body).toContain("dropFirst().dropLast()");
    expect(body).toContain("return value.isEmpty ? nil : value");
  });

  it("never puts the credential in the reply", () => {
    // The page only ever needs ids; a key in page JavaScript would be a leak
    // into a context that logs, screenshots, and runs injected script.
    const listing = swiftBody("static func listing(");
    expect(listing).toContain('["ok": true, "models": ids]');
    expect(listing).not.toContain("key]");
    expect(listing).not.toContain("key,");
  });

  it("uses the owner's endpoint", () => {
    expect(SWIFT).toContain('static let modelsURL = "https://api.deepseek.com/models"');
    expect(SWIFT).toContain('static let credentialRef = "DEEPSEEK_API_KEY"');
  });

  it("is wired to a script message handler the page can actually call", () => {
    expect(SWIFT).toContain("class DeepSeekModelsMessageHandler: NSObject, WKScriptMessageHandler");
    expect(SWIFT).toContain('static let name = "harnessDeepSeekModels"');
    expect(SWIFT).toMatch(/userContent\.add\(modelsHandler, name: DeepSeekModelsMessageHandler\.name\)/);
    expect(SWIFT).toContain("window.webkit.messageHandlers.harnessDeepSeekModels.postMessage");
  });

  it("mounts the affordance in the Models section, guarded against re-mounting", () => {
    expect(SWIFT).toContain("const mountDeepSeekModelsButton = () =>");
    expect(SWIFT).toContain('section[aria-label="Models"]');
    expect(SWIFT).toContain('button.dataset.harnessDsModels = \'1\'');
    // A missing target must be a no-op, never a throw: this runs inside a
    // MutationObserver, and a throw there would break every other patch.
    expect(SWIFT).toMatch(/if \(!section\) return;/);
  });

  it("maps auth failures to a message rather than a silent empty list", () => {
    const listing = swiftBody("static func listing(");
    expect(listing).toMatch(/status == 401 \|\| status == 403/);
    expect(listing).toContain("DeepSeek did not answer with a model list.");
  });
});

/** Pull a Swift function body by brace counting from its signature. */
function swiftBody(signature: string): string {
  const start = SWIFT.indexOf(signature);
  if (start === -1) throw new Error(`${signature} not found in HarnessWindow.swift`);
  let depth = 0;
  for (let i = SWIFT.indexOf("{", start); i < SWIFT.length; i++) {
    const ch = SWIFT[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return SWIFT.slice(start, i + 1);
    }
  }
  throw new Error(`${signature}: unbalanced braces`);
}
