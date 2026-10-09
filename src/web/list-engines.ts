#!/usr/bin/env node
/**
 * clutch-engines — list and verify the engine plugins Clutch can load.
 *
 * Engines are drop-in files, so the thing an operator needs is a way to see
 * what was actually found, where it came from, and what is wrong with the rest.
 * This is also the check a plugin author runs after writing one.
 *
 *   clutch-engines list             show every discovered engine
 *   clutch-engines list --json      machine-readable output
 *   clutch-engines list --dir DIR   also scan DIR (repeatable), for authoring
 *   clutch-engines paths            show the search path only
 *
 * Exits 1 when any plugin failed to load, so a broken drop-in is visible in
 * scripts and CI rather than silently absent from the picker.
 */
import { enginePluginDirs, loadEnginePlugins } from "../shared/engines/index.ts";

function usage(): never {
  console.error(
    "usage: clutch-engines <list|paths> [--json] [--dir DIR]\n" +
      "  list    show every discovered engine plugin\n" +
      "  paths   show the plugin search path (bundled, then per-machine)",
  );
  process.exit(2);
}

function collectDirs(argv: string[]): string[] {
  const dirs: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dir") {
      const value = argv[i + 1];
      if (value === undefined) usage();
      dirs.push(value);
      i++;
    }
  }
  return dirs;
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const command = argv[0] ?? "list";
  const json = argv.includes("--json");
  const extraDirs = collectDirs(argv);

  if (command === "paths") {
    const dirs = [...enginePluginDirs(), ...extraDirs];
    if (json) console.log(JSON.stringify({ dirs }, null, 2));
    else dirs.forEach((dir) => console.log(dir));
    return;
  }
  if (command !== "list") usage();

  const { plugins, problems, superseded } = await loadEnginePlugins({
    ...(extraDirs.length > 0 ? { dirs: [...enginePluginDirs(), ...extraDirs] } : {}),
  });

  if (json) {
    console.log(
      JSON.stringify(
        {
          engines: plugins.map((plugin) => ({
            id: plugin.id,
            displayName: plugin.support.displayName,
            driverKind: plugin.support.driverKind,
            nativeSource: plugin.support.nativeSource,
            defaultCli: plugin.support.defaultCli,
            origin: plugin.origin,
            kind: plugin.kind,
            file: plugin.file,
            models: plugin.support.models.options.map((option) => option.id),
            defaultModel: plugin.support.models.default,
          })),
          problems: problems.map((problem) => ({
            file: problem.file,
            ...(problem.id === undefined ? {} : { id: problem.id }),
            origin: problem.origin,
            problems: problem.problems,
          })),
          superseded,
        },
        null,
        2,
      ),
    );
  } else {
    if (plugins.length === 0) console.log("no engine plugins found");
    for (const plugin of plugins) {
      const { support } = plugin;
      console.log(`${plugin.id}  (${support.displayName})`);
      console.log(`  driver      ${support.driverKind}`);
      console.log(`  source      ${support.nativeSource}`);
      console.log(`  cli         ${support.defaultCli}`);
      console.log(`  origin      ${plugin.origin} ${plugin.kind} — ${plugin.file}`);
      console.log(
        `  models      ${support.models.options.length} (default ${support.models.default}): ` +
          `${support.models.options.map((option) => option.id).join(", ")}`,
      );
      console.log("");
    }
    for (const file of superseded) console.log(`superseded  ${file}`);
    for (const problem of problems) {
      console.log(`PROBLEM  ${problem.file}${problem.id ? ` [${problem.id}]` : ""}`);
      for (const message of problem.problems) console.log(`  - ${message}`);
    }
  }

  if (problems.length > 0) process.exit(1);
}

await main();