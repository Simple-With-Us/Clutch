#!/usr/bin/env node
/**
 * Sync tracked profiles from src/profiles/ to $CLUTCH_HOME/dsh/profiles/
 * (default ~/.clutch/dsh/profiles/), Clutch's own engine home.  The vanilla
 * ~/.dsh is never touched.
 *
 * Tracked patch files name their settings file as
 * `__DSH_HOME__/settings-<name>.yaml` so they stay machine-independent; the
 * placeholder is replaced with the real engine home on copy.
 *
 * Idempotent.  Run via `npm run sync` after every `npm ci` and every
 * profile change.  Per-machine overrides (local.patch.yml) are preserved.
 */
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { initClutchSettings } from "../src/shared/clutchSettings.ts";

// Infisical is the sole source of truth for app settings (see INFISICAL.md).
await initClutchSettings();

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
const SRC_PROFILES = join(ROOT, "src", "profiles");
const SRC_PRESETS = join(ROOT, "src", "presets");
const CLUTCH_HOME = process.env.CLUTCH_HOME || join(homedir(), ".clutch");
/** Clutch's engine home.  Always $CLUTCH_HOME/dsh, never an inherited DSH_HOME. */
const ENGINE_HOME = join(CLUTCH_HOME, "dsh");
const DST_PROFILES = join(ENGINE_HOME, "profiles");
const DST_PRESETS = join(ENGINE_HOME, ".agent-presets");
const DST_SETTINGS = ENGINE_HOME;
/** Placeholder the tracked patch files use for the engine home. */
const DSH_HOME_PLACEHOLDER = "__DSH_HOME__";

interface SyncResult {
  readonly profile: string;
  readonly filesCopied: readonly string[];
  readonly localOverride: boolean;
}

function log(line: string): void {
  process.stdout.write(`sync-profiles: ${line}\n`);
}

function listProfiles(): readonly string[] {
  if (!existsSync(SRC_PROFILES)) return [];
  return readdirSync(SRC_PROFILES).filter((entry) => {
    const full = join(SRC_PROFILES, entry);
    return statSync(full).isDirectory();
  });
}

function copyDir(srcDir: string, dstDir: string): string[] {
  mkdirSync(dstDir, { recursive: true });
  const copied: string[] = [];
  for (const entry of readdirSync(srcDir)) {
    const srcFile = join(srcDir, entry);
    const stat = statSync(srcFile);
    if (!stat.isFile()) continue;
    if (entry === "local.patch.yml") continue; // never overwrite a local override
    const dstFile = join(dstDir, entry);
    if (entry.endsWith(".yml") || entry.endsWith(".yaml")) {
      const text = readFileSync(srcFile, "utf8");
      writeFileSync(dstFile, text.split(DSH_HOME_PLACEHOLDER).join(ENGINE_HOME));
    } else {
      copyFileSync(srcFile, dstFile);
    }
    copied.push(entry);
  }
  return copied;
}

function copySettingsFile(name: string): boolean {
  const src = join(SRC_PROFILES, name, `settings-${name}.yaml`);
  if (!existsSync(src)) return false;
  const dst = join(DST_SETTINGS, `settings-${name}.yaml`);
  copyFileSync(src, dst);
  return true;
}

function syncOne(name: string): SyncResult {
  const srcDir = join(SRC_PROFILES, name);
  const dstDir = join(DST_PROFILES, name);
  const localOverridePath = join(dstDir, "local.patch.yml");
  const localExists = existsSync(localOverridePath);

  // Remove tracked files (anything except local.patch.yml) before re-copying,
  // so a deleted tracked file actually disappears at the destination.
  //
  // Directories are left alone: the engine creates runtime trees inside a
  // profile directory (`.dsh-module-fallback/`, `node_modules/`), and a bare
  // rmSync on one of those throws ERR_FS_EISDIR, which used to abort the whole
  // sync before any profile or preset was copied.  Tracked profiles ship files
  // only, so nothing tracked is ever skipped.
  if (existsSync(dstDir)) {
    for (const entry of readdirSync(dstDir)) {
      if (entry === "local.patch.yml") continue;
      const dstEntry = join(dstDir, entry);
      if (statSync(dstEntry).isDirectory()) continue;
      rmSync(dstEntry, { force: true });
    }
  }

  const copied = copyDir(srcDir, dstDir);
  copySettingsFile(name);

  return {
    profile: name,
    filesCopied: copied,
    localOverride: localExists,
  };
}

function copyDirRecursive(srcDir: string, dstDir: string): string[] {
  mkdirSync(dstDir, { recursive: true });
  const copied: string[] = [];
  for (const entry of readdirSync(srcDir)) {
    const srcPath = join(srcDir, entry);
    const dstPath = join(dstDir, entry);
    const stat = statSync(srcPath);
    if (stat.isDirectory()) {
      const nested = copyDirRecursive(srcPath, dstPath);
      copied.push(...nested.map((p) => join(entry, p)));
    } else if (stat.isFile()) {
      if (entry.endsWith(".yml") || entry.endsWith(".yaml")) {
        const text = readFileSync(srcPath, "utf8");
        writeFileSync(dstPath, text.split(DSH_HOME_PLACEHOLDER).join(ENGINE_HOME));
      } else {
        copyFileSync(srcPath, dstPath);
      }
      copied.push(entry);
    }
  }
  return copied;
}

function listPresets(): readonly string[] {
  if (!existsSync(SRC_PRESETS)) return [];
  return readdirSync(SRC_PRESETS).filter((entry) => {
    const full = join(SRC_PRESETS, entry);
    return statSync(full).isDirectory();
  });
}

function syncPresets(): void {
  const presets = listPresets();
  if (presets.length === 0) return;
  mkdirSync(DST_PRESETS, { recursive: true, mode: 0o700 });
  log(`syncing ${presets.length} agent preset(s) to ${DST_PRESETS}`);
  for (const name of presets) {
    const srcDir = join(SRC_PRESETS, name);
    const dstDir = join(DST_PRESETS, name);
    if (existsSync(dstDir)) {
      rmSync(dstDir, { recursive: true, force: true });
    }
    const copied = copyDirRecursive(srcDir, dstDir);
    log(`  preset ${name}: ${copied.join(", ") || "(empty)"}`);
  }
}

async function main(): Promise<void> {
  const profiles = listProfiles();
  if (profiles.length === 0) {
    log(`no profiles in ${SRC_PROFILES}`);
  } else {
    mkdirSync(DST_PROFILES, { recursive: true, mode: 0o700 });
    log(`syncing ${profiles.length} profile(s) to ${DST_PROFILES}`);
    for (const name of profiles) {
      const result = syncOne(name);
      const overrideNote = result.localOverride ? " (local.patch.yml preserved)" : "";
      log(`  ${name}: ${result.filesCopied.join(", ") || "(empty)"}${overrideNote}`);
    }
  }
  syncPresets();
  log(`done. restart any pm2 job that uses a synced profile to pick up changes.`);
}
await main();
