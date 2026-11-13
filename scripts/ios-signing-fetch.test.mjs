import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { loadSigning } from './ios-signing-fetch.mjs';
const fixtureToken = () => `st.${randomBytes(32).toString('hex')}`;
const expectedAuthorization = token => `Bearer ${token}`;
const env = { INFISICAL_PROJECT_ID: 'clutch', INFISICAL_ASC_PROJECT_ID: 'fleet', INFISICAL_TOKEN: fixtureToken(), INFISICAL_ASC_TOKEN: fixtureToken(), GITHUB_ENV: '/unused' };
const pem = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ format: 'pem', type: 'pkcs8' }).toString().trimEnd();
function mock({ certMissing = false, listStatus = 200, keyPem = pem, certPassword = 'password' } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push([url, options]);
    assert.ok([env.INFISICAL_TOKEN, env.INFISICAL_ASC_TOKEN].map(expectedAuthorization).includes(options.headers.authorization));
    assert.equal(options.redirect, 'error');
    if (new URL(url).pathname === '/api/v2/service-token') {
      const asc = options.headers.authorization === `Bearer ${env.INFISICAL_ASC_TOKEN}`;
      return {
        ok: true,
        status: 200,
        json: async () => ({
          projectId: asc ? 'fleet' : 'clutch',
          workspace: asc ? 'fleet' : 'clutch',
          scopes: [{ secretPath: asc ? '/asc' : '/', environment: 'prod' }],
          permissions: ['read'],
        }),
      };
    }
    const qs = new URL(url).searchParams;
    const asc = qs.get('workspaceId') === 'fleet';
    const data = asc ? { ASC_KEY_ID: 'key', ASC_ISSUER_ID: 'issuer', ASC_KEY_P8: keyPem } : { IOS_CERT_P12_BASE64: 'certificate', ...(certMissing ? {} : { IOS_CERT_PASSWORD: certPassword }) };
    return { ok: listStatus === 200, status: listStatus, json: async () => ({ secrets: Object.entries(data).map(([secretKey, secretValue]) => ({ secretKey, secretValue })) }) };
  };
  return { calls, fetchImpl };
}
test('maps exact two sources, base64 encodes PEM, masks before exporting', async () => {
  const { calls, fetchImpl } = mock(); const events = [];
  await loadSigning({ env, fetchImpl, log: value => events.push(['log', value]), write: (path, name, value) => events.push(['write', name, value]) });
  const secretReads = calls.filter(([url]) => new URL(url).pathname === '/api/v3/secrets/raw');
  assert.equal(secretReads.length, 2);
  assert.match(secretReads[0][0], /workspaceId=fleet.*secretPath=%2Fasc/);
  assert.match(secretReads[1][0], /workspaceId=clutch.*secretPath=%2F/);
  assert.equal(secretReads[0][1].headers.authorization, expectedAuthorization(env.INFISICAL_ASC_TOKEN));
  assert.equal(secretReads[1][1].headers.authorization, expectedAuthorization(env.INFISICAL_TOKEN));
  for (const [url] of secretReads) assert.equal(new URL(url).searchParams.get('include_imports'), 'false');
  const writes = events.filter(e => e[0] === 'write');
  assert.equal(writes.length, 5);
  assert.equal(Buffer.from(writes.find(e => e[1] === 'APPLE_API_KEY_P8_BASE64')[2], 'base64').toString(), `${pem}\n`);
  assert.ok(events.findIndex(e => e[0] === 'write') > events.findIndex(e => e[1] === '::add-mask::password'));
});
test('SENTRY_DSN and SENTRY_AUTH_TOKEN in Clutch prod are exported masked when present', async () => {
  const base = mock();
  const fetchImpl = async (url, options) => {
    const res = await base.fetchImpl(url, options);
    const qs = new URL(url).searchParams;
    if (qs.get('workspaceId') === 'clutch' && res.ok) {
      const body = await res.json();
      body.secrets.push({ secretKey: 'SENTRY_DSN', secretValue: 'https://fixture@o0.ingest.sentry.io/1' }, { secretKey: 'SENTRY_AUTH_TOKEN', secretValue: 'fixture-token' });
      return { ok: true, status: 200, json: async () => body };
    }
    return res;
  };
  const events = [];
  await loadSigning({ env, fetchImpl, log: value => events.push(['log', value]), write: (path, name, value) => events.push(['write', name, value]) });
  const writes = events.filter(e => e[0] === 'write');
  assert.equal(writes.find(e => e[1] === 'SENTRY_DSN')[2], 'https://fixture@o0.ingest.sentry.io/1');
  assert.ok(events.findIndex(e => e[0] === 'write' && e[1] === 'SENTRY_DSN') > events.findIndex(e => e[1] === '::add-mask::https://fixture@o0.ingest.sentry.io/1'));
});
test('empty CI input fails before requesting either project', async () => {
  let called = false;
  await assert.rejects(loadSigning({ env: { ...env, INFISICAL_ASC_TOKEN: '' }, fetchImpl: () => { called = true; } }), /INFISICAL_ASC_TOKEN is empty/);
  assert.equal(called, false);
});
test('missing certificate fails without any export', async () => {
  let written = false; const { fetchImpl } = mock({ certMissing: true });
  await assert.rejects(loadSigning({ env, fetchImpl, log: () => {}, write: () => { written = true; } }), /Clutch prod \/ missing.*IOS_CERT_PASSWORD/);
  assert.equal(written, false);
});
test('permission errors fail loudly, not silently empty', async () => {
  const { fetchImpl } = mock({ listStatus: 403 });
  await assert.rejects(loadSigning({ env, fetchImpl, log: () => {} }), /HTTP 403/);
});
test('PEM without a trailing newline gains one before base64 export', async () => {
  const { fetchImpl } = mock({ keyPem: pem });
  const writes = [];
  await loadSigning({ env, fetchImpl, log: () => {}, write: (_path, name, value) => writes.push([name, value]) });
  assert.equal(Buffer.from(writes.find(([name]) => name === 'APPLE_API_KEY_P8_BASE64')[1], 'base64').toString(), `${pem}\n`);
});
test('PEM that already ends with a newline is not doubled', async () => {
  const lined = `${pem}\n`;
  const { fetchImpl } = mock({ keyPem: lined });
  const writes = [];
  await loadSigning({ env, fetchImpl, log: () => {}, write: (_path, name, value) => writes.push([name, value]) });
  assert.equal(Buffer.from(writes.find(([name]) => name === 'APPLE_API_KEY_P8_BASE64')[1], 'base64').toString(), lined);
});
test('malformed private-key PEM is rejected without exposing it or exporting values', async () => {
  const malformedPem = pem.replace(/(?<=\n)[A-Za-z0-9+/=]+(?=\n)/, 'AAAAAAAA');
  assert.notEqual(malformedPem, pem);
  let written = false;
  const { fetchImpl } = mock({ keyPem: malformedPem });
  await assert.rejects(loadSigning({ env, fetchImpl, log: () => {}, write: () => { written = true; } }), error => {
    assert.match(error.message, /not a valid PEM private key/);
    assert.ok(!error.message.includes(malformedPem));
    return true;
  });
  assert.equal(written, false);
});
test('a value that is still a bare reference fails closed, naming the key only, with no export', async () => {
  let written = false; const { calls, fetchImpl } = mock({ certPassword: '${prod.global-api-keys.SENTINEL_REF_2d8f}' });
  await assert.rejects(loadSigning({ env, fetchImpl, log: () => {}, write: () => { written = true; } }), error => {
    assert.match(error.message, /IOS_CERT_PASSWORD/);
    assert.ok(!error.message.includes('SENTINEL_REF_2d8f'));
    return true;
  });
  assert.equal(written, false);
  const secretRead = calls.find(([url]) => new URL(url).pathname === '/api/v3/secrets/raw');
  assert.equal(new URL(secretRead[0]).searchParams.get('expandSecretReferences'), 'true');
});
