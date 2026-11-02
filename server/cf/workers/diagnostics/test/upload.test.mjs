import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
let mf;
before(() => {
  mf = new Miniflare(convertV4MiniflareOptions({ modules: true, scriptPath: 'dist/index.js', compatibilityDate: '2026-11-02', r2Buckets: ['DIAGNOSTICS'], ratelimits: { UPLOAD_LIMITER: { namespace_id: '1001', simple: { limit: 5, period: 60 } } } }));
});
after(async () => { await mf.dispose(); });
function upload(body = 'synthetic 日志', extra = {}) {
  return mf.dispatchFetch('http://localhost/v1/diagnostics', { method: 'POST', headers: { 'Content-Type': 'text/plain', 'Content-Length': String(Buffer.byteLength(body)), 'X-App-Version': '0.6.1', 'X-Platform': 'macos', 'CF-Connecting-IP': '192.0.2.1', ...extra }, body });
}
test('stores original bytes privately and creates distinct reports', async () => {
  const first = await upload(); const second = await upload();
  assert.equal(first.status, 201); assert.equal(second.status, 201);
  assert.notEqual((await first.json()).upload_id, (await second.json()).upload_id);
  const bucket = await mf.getR2Bucket('DIAGNOSTICS');
  const objects = await bucket.list();
  assert.equal(objects.objects.length, 2);
  assert.equal(await (await bucket.get(objects.objects[0].key)).text(), 'synthetic 日志');
  const get = await mf.dispatchFetch('http://localhost/' + objects.objects[0].key);
  assert.equal(get.status, 404);
});
test('rejects unsupported types and invalid metadata without storing', async () => {
  assert.equal((await upload('x', { 'Content-Type': 'text/html' })).status, 415);
  assert.equal((await upload('x', { 'X-Platform': 'unknown' })).status, 400);
  assert.equal((await upload('')).status, 413);
});
test('rejects declared oversized requests before reading the body', async () => {
  const response = await mf.dispatchFetch('http://localhost/v1/diagnostics', { method: 'POST', headers: { 'Content-Type': 'text/plain', 'Content-Length': String(50 * 1024 * 1024 + 1), 'X-App-Version': '0.6.1', 'X-Platform': 'macos' }, body: new Uint8Array(50 * 1024 * 1024 + 1) });
  assert.equal(response.status, 413);
});
test('sixth upload from an IP is limited', async () => {
  for (let i = 0; i < 5; i++) {
    assert.equal((await upload('rate test', { 'CF-Connecting-IP': '192.0.2.2' })).status, 201);
  }
  assert.equal((await upload('rate test', { 'CF-Connecting-IP': '192.0.2.2' })).status, 429);
});
