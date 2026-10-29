import assert from "node:assert/strict";
import test from "node:test";
import { collectSharedBuilds } from "./asc-api.mjs";
import { nextSharedBuild } from "./shared-build.mjs";

// The next-shared-build inventory: one app contributes its own IOS and MAC_OS
// builds; a paired app that resolves to a different app contributes both of
// its platforms too, so iosBuilds = IOS(app) + IOS(paired) and
// macBuilds = MAC_OS(app) + MAC_OS(paired).  Nothing here touches the
// network: fetchBuilds is a stub standing in for the paged builds query.
test("paired app joins as both platforms of both apps", async () => {
  const calls = [];
  const fetchBuilds = async (appId, platform) => {
    calls.push(`${appId}/${platform}`);
    return [`${platform}-${appId}`];
  };
  const out = await collectSharedBuilds({ fetchBuilds, appId: "app1", pairedAppId: "app2" });
  assert.deepEqual(calls.sort(), ["app1/IOS", "app1/MAC_OS", "app2/IOS", "app2/MAC_OS"]);
  assert.deepEqual(out, {
    iosBuilds: ["IOS-app1", "IOS-app2"],
    macBuilds: ["MAC_OS-app1", "MAC_OS-app2"]
  });
});

test("no paired app queries only the one app", async () => {
  const calls = [];
  const fetchBuilds = async (appId, platform) => {
    calls.push(`${appId}/${platform}`);
    return [];
  };
  const out = await collectSharedBuilds({ fetchBuilds, appId: "app1", pairedAppId: "" });
  assert.deepEqual(calls.sort(), ["app1/IOS", "app1/MAC_OS"]);
  assert.deepEqual(out, { iosBuilds: [], macBuilds: [] });
});

test("paired app equal to the app is not queried twice", async () => {
  const calls = [];
  const fetchBuilds = async (appId, platform) => {
    calls.push(`${appId}/${platform}`);
    return [];
  };
  await collectSharedBuilds({ fetchBuilds, appId: "app1", pairedAppId: "app1" });
  assert.deepEqual(calls.sort(), ["app1/IOS", "app1/MAC_OS"]);
});

test("the four inventories are fetched concurrently", { timeout: 10000 }, async () => {
  // Each stub waits on a gate the fourth call opens.  Serial awaits would
  // wait on the first call forever (the timeout fails the test instead of
  // hanging the suite); reaching the assertion proves all four were in
  // flight at once.
  const calls = [];
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const fetchBuilds = async (appId, platform) => {
    calls.push(`${appId}/${platform}`);
    if (calls.length === 4) release();
    await gate;
    return [];
  };
  const out = await collectSharedBuilds({ fetchBuilds, appId: "app1", pairedAppId: "app2" });
  assert.equal(calls.length, 4);
  assert.deepEqual(out, { iosBuilds: [], macBuilds: [] });
});

test("union feeds the shared counter from the highest build on either app", async () => {
  const versions = {
    "app1/IOS": ["1100"],
    "app1/MAC_OS": ["1200"],
    "app2/IOS": ["1400"],
    "app2/MAC_OS": ["1300"]
  };
  const fetchBuilds = async (appId, platform) => versions[`${appId}/${platform}`] || [];
  const out = await collectSharedBuilds({ fetchBuilds, appId: "app1", pairedAppId: "app2" });
  assert.deepEqual(nextSharedBuild({ ...out, complete: true }), { build: "1401", ignoredIos: 0 });
});
