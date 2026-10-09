/**
 * Engine plugins — drop-in engine definitions discovered at runtime.
 *
 * An engine is a file, not a code change: `engines/<id>.engine.json` (the
 * declarative tier, mapped onto `AcpSupport` without executing anything) or
 * `engines/<id>.engine.mjs` (the programmatic tier, exporting an `AcpSupport`).
 * Shipped plugins live in the package's `engines/` directory; per-machine
 * drop-ins live in `$CLUTCH_HOME/engines` and override shipped ones by id.
 *
 * Start with {@link loadEnginePlugins}.  Authoring guide: `docs/engine-plugins.md`.
 */

export {
  ENGINE_MANIFEST_SCHEMA,
  ENGINE_MANIFEST_SUFFIX,
  ENGINE_MODULE_SUFFIX,
  engineSupportFromManifest,
  validateEngineManifest,
  type EngineManifest,
  type EngineManifestAuthenticated,
  type EngineManifestErrorRule,
  type EngineManifestInstall,
  type EngineManifestSelectModel,
  type EngineManifestSpawn,
  type EnginePromptText,
} from "./manifest.ts";

export {
  bundledEngineDir,
  enginePluginDirs,
  loadEnginePlugins,
  userEngineDir,
  validateAcpSupport,
  type EnginePlugin,
  type EnginePluginKind,
  type EnginePluginLoadResult,
  type EnginePluginOptions,
  type EnginePluginOrigin,
  type EnginePluginProblem,
} from "./discover.ts";