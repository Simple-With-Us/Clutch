import test from 'node:test';
import assert from 'node:assert/strict';
import { loadSigning } from './ios-signing-fetch.mjs';
const env = { INFISICAL_PROJECT_ID: 'clutch', INFISICAL_ASC_PROJECT_ID: 'fleet', INFISICAL_CLIENT_ID: 'id', INFISICAL_CLIENT_SECRET: 'secret', GITHUB_ENV: '/unused' };
const pem = '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----';
function mock({ certMissing = false, listStatus = 200 } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push([url, options]);
    if (url.endsWith('/login')) return { ok: true, json: async () => ({ accessToken: 'token' }) };
    const qs = new URL(url).searchParams;
    const asc = qs.get('workspaceId') === 'fleet';
    const data = asc ? { ASC_KEY_ID: 'key', ASC_ISSUER_ID: 'issuer', ASC_KEY_P8: pem } : { IOS_CERT_P12_BASE64: 'certificate', ...(certMissing ? {} : { IOS_CERT_PASSWORD: 'password' }) };
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
  assert.equal(Buffer.from(writes.find(e => e[1] === 'APPLE_API_KEY_P8_BASE64')[2], 'base64').toString(), pem);
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
