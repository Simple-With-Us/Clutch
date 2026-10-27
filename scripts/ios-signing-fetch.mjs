// Strict two-source iOS signing fetch. Never falls back to GitHub signing values.
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loginUniversalAuth, listSecretsRaw, maskValue, writeGithubEnvValue } from './infisical-fetch.mjs';

const UNRESOLVED_REFERENCE = /^\$\{[^}]+\}$/;

export async function loadSigning({ env = process.env, fetchImpl = fetch, log = console.log, write = writeGithubEnvValue } = {}) {
  for (const name of ['INFISICAL_PROJECT_ID', 'INFISICAL_ASC_PROJECT_ID', 'INFISICAL_CLIENT_ID', 'INFISICAL_CLIENT_SECRET', 'GITHUB_ENV']) {
    if (!env[name]?.trim()) throw new Error(`Required CI input ${name} is empty. Configure the Infisical CI machine identity before shipping.`);
  }
  const siteUrl = (env.INFISICAL_SITE_URL || 'https://app.infisical.com').replace(/\/+$/, '');
  const token = await loginUniversalAuth({ siteUrl, clientId: env.INFISICAL_CLIENT_ID, clientSecret: env.INFISICAL_CLIENT_SECRET, fetchImpl });
  const read = (projectId, secretPath) => listSecretsRaw({ siteUrl, token, projectId, environment: 'prod', secretPath, fetchImpl });
  const asc = await read(env.INFISICAL_ASC_PROJECT_ID, '/asc');
  const cert = await read(env.INFISICAL_PROJECT_ID, '/');
  const sources = [[asc, ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'], 'Fleet-OPS prod /asc'], [cert, ['IOS_CERT_P12_BASE64', 'IOS_CERT_PASSWORD'], 'Clutch prod /']];
  for (const [values, names, source] of sources) {
    const missing = names.filter(name => !values.get(name)?.trim());
    if (missing.length) throw new Error(`${source} missing required signing input(s): ${missing.join(', ')}. Verify project binding and machine identity read access.`);
    // OPS-818: Fleet-OPS values can be bare references such as ${prod.folder.NAME}. The reads ask Infisical to
    // expand them, so one that survives is unresolved (target missing, or no read access to the referenced
    // folder). Name the KEY only, never the value, and export nothing.
    const unresolved = names.filter(name => UNRESOLVED_REFERENCE.test(values.get(name).trim()));
    if (unresolved.length) throw new Error(`${source} signing input(s) are still unresolved Infisical secret references: ${unresolved.join(', ')}. Check the referenced targets exist and the machine identity can read their folders.`);
  }
  const rawPem = asc.get('ASC_KEY_P8');
  if (!rawPem.includes('-----BEGIN PRIVATE KEY-----') || !rawPem.includes('-----END PRIVATE KEY-----')) throw new Error('Fleet-OPS ASC_KEY_P8 is not a PEM private key.');
  // OpenSSL PEM parsers reject an END line that has no trailing newline.
  const pem = rawPem.endsWith('\n') ? rawPem : `${rawPem}\n`;
  const values = {
    APPLE_API_KEY_ID: asc.get('ASC_KEY_ID'),
    APPLE_API_ISSUER_ID: asc.get('ASC_ISSUER_ID'),
    APPLE_API_KEY_P8_BASE64: Buffer.from(pem).toString('base64'),
    IOS_CERT_P12_BASE64: cert.get('IOS_CERT_P12_BASE64'),
    IOS_CERT_PASSWORD: cert.get('IOS_CERT_PASSWORD'),
  };
  // C-102: Sentry is optional until its project/DSN exist.  Export it when
  // Clutch prod / carries it so the archive gets a live DSN and the ship
  // can upload dSYMs; when absent, say so by name and ship without it.
  for (const name of ['SENTRY_DSN', 'SENTRY_AUTH_TOKEN']) {
    const value = cert.get(name)?.trim();
    if (value && !UNRESOLVED_REFERENCE.test(value)) values[name] = value;
  }
  for (const value of [...asc.values(), ...Object.values(values)]) maskValue(value, log);
  for (const [name, value] of Object.entries(values)) write(env.GITHUB_ENV, name, value);
  log('Loaded shared ASC credentials from Fleet-OPS prod /asc and certificate from Clutch prod /.');
  for (const name of ['SENTRY_DSN', 'SENTRY_AUTH_TOKEN']) {
    if (!values[name]) log(`::warning::${name} not set in Clutch prod /; Sentry stays inert for this ship until it is provisioned.`);
  }
}

try {
  if (realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    loadSigning().catch(error => { console.error(`::error::${error.message}`); process.exitCode = 1; });
  }
} catch { /* Imported module has no CLI entry. */ }
