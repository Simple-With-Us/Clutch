import test from 'node:test';
import assert from 'node:assert/strict';
import { loadSigning } from './ios-signing-fetch.mjs';
const env = { INFISICAL_PROJECT_ID: 'clutch', INFISICAL_ASC_PROJECT_ID: 'fleet', INFISICAL_CLIENT_ID: 'id', INFISICAL_CLIENT_SECRET: 'secret', GITHUB_ENV: '/unused' };
const pem = '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----';
function mock({ certMissing = false, listStatus = 200, keyPem = pem, certPassword = 'password' } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push([url, options]);
    if (url.endsWith('/login')) return { ok: true, json: async () => ({ accessToken: 'token' }) };
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
  assert.equal(calls.length, 3);
  assert.match(calls[1][0], /workspaceId=fleet.*secretPath=%2Fasc/);
  assert.match(calls[2][0], /workspaceId=clutch.*secretPath=%2F/);
  for (const [url] of calls.slice(1)) assert.equal(new URL(url).searchParams.get('include_imports'), 'false');
  const writes = events.filter(e => e[0] === 'write');
  assert.equal(writes.length, 5);
  assert.equal(Buffer.from(writes.find(e => e[1] === 'APPLE_API_KEY_P8_BASE64')[2], 'base64').toString(), `${pem}\n`);
  assert.ok(events.findIndex(e => e[0] === 'write') > events.findIndex(e => e[1] === '::add-mask::password'));
});
test('empty CI input fails before login', async () => {
  let called = false;
  await assert.rejects(loadSigning({ env: { ...env, INFISICAL_CLIENT_ID: '' }, fetchImpl: () => { called = true; } }), /INFISICAL_CLIENT_ID is empty/);
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
test('a value that is still a bare reference fails closed, naming the key only, with no export', async () => {
  let written = false; const { calls, fetchImpl } = mock({ certPassword: '${prod.global-api-keys.SENTINEL_REF_2d8f}' });
  await assert.rejects(loadSigning({ env, fetchImpl, log: () => {}, write: () => { written = true; } }), error => {
    assert.match(error.message, /IOS_CERT_PASSWORD/);
    assert.ok(!error.message.includes('SENTINEL_REF_2d8f'));
    return true;
  });
  assert.equal(written, false);
  assert.equal(new URL(calls[1][0]).searchParams.get('expandSecretReferences'), 'true');
});
