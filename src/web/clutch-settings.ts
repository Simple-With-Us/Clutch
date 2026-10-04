#!/usr/bin/env node
/**
 * clutch-settings — the admin surface for Clutch's Infisical-backed settings.
 *
 * Clutch is a single-user local tool, so the local machine user IS the admin
 * (documented no-op gate — see INFISICAL.md).  Reads come from the in-memory
 * cache populated at startup; `set` writes through to Infisical FIRST, then
 * updates the local cache.  Secret values are never printed.
 *
 *   clutch-settings list            show managed keys (values masked for secrets)
 *   clutch-settings get KEY         print one value (secrets print to stdout
 *                                   only when explicitly requested — pipe with care)
 *   clutch-settings set KEY VALUE   write-through save to Infisical
 *   clutch-settings reload          force a refresh from Infisical now
 */
import { initClutchSettings, CLUTCH_SETTINGS_SCHEMA, isSecretSetting } from "../shared/clutchSettings.ts";

function usage(): never {
  console.error(
    "usage: clutch-settings <list|get KEY|set KEY VALUE|reload>\n" +
      "  Admin surface for Clutch settings (Infisical sole source of truth).",
  );
  process.exit(2);
}

function mask(key: string, value: string): string {
  return isSecretSetting(key) ? "******" : value;
}

async function main(): Promise<void> {
  const [, , command, ...rest] = process.argv;
  if (command === undefined) usage();

  const settings = await initClutchSettings();
  try {
    if (command === "list") {
      const all = settings.getAll();
      for (const def of CLUTCH_SETTINGS_SCHEMA) {
        const value = all[def.key] ?? "";
        const shown = value.length > 0 ? mask(def.key, value) : "(unset)";
        console.log(`${def.key}=${shown}  # ${def.description}`);
      }
      console.log(`# source: ${settings.source}`);
    } else if (command === "get") {
      const [key] = rest;
      if (!key) usage();
      console.log(settings.get(key));
    } else if (command === "set") {
      const [key, ...valueParts] = rest;
      const value = valueParts.join(" ");
      if (!key || valueParts.length === 0) usage();
      await settings.set(key, value);
      // Names only — never the value.
      console.error(`clutch-settings: saved "${key}" (write-through to Infisical)`);
    } else if (command === "reload") {
      await settings.refresh();
      console.error("clutch-settings: refreshed from Infisical");
    } else {
      usage();
    }
  } finally {
    settings.stop();
  }
}

await main();
