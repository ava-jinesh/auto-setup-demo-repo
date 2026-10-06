const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { server } = require('../server');

let baseUrl;

before(async () => {
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://localhost:${server.address().port}`;
});

after(() => server.close());

for (const route of ['/', '/index.html']) {
  test(`GET ${route} returns the Hello World page`, async () => {
    const res = await fetch(`${baseUrl}${route}`);
    assert.strictEqual(res.status, 200);
    assert.match(res.headers.get('content-type'), /text\/html; charset=utf-8/);
    assert.match(await res.text(), /Hello, World!/);
  });
}

test('home page includes expected security headers', async () => {
  const res = await fetch(baseUrl);
  assert.strictEqual(res.headers.get('x-content-type-options'), 'nosniff');
  assert.strictEqual(res.headers.get('x-frame-options'), 'DENY');
  assert.strictEqual(res.headers.get('referrer-policy'), 'no-referrer');
  assert.match(res.headers.get('content-security-policy'), /default-src 'none'/);
});

test('HEAD / returns headers without a response body', async () => {
  const res = await fetch(baseUrl, { method: 'HEAD' });
  assert.strictEqual(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.strictEqual(await res.text(), '');
});

test('GET /health returns an OK JSON response', async () => {
  const res = await fetch(`${baseUrl}/health`);
  assert.strictEqual(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/json/);
  assert.deepStrictEqual(await res.json(), { status: 'ok' });
});

for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']) {
  test(`${method} / is rejected with 405`, async () => {
    const res = await fetch(baseUrl, { method });
    assert.strictEqual(res.status, 405);
    assert.strictEqual(res.headers.get('allow'), 'GET, HEAD');
    assert.strictEqual(await res.text(), '');
  });
}

for (const route of ['/missing', '/health/extra', '/favicon.ico']) {
  test(`GET ${route} returns 404`, async () => {
    const res = await fetch(`${baseUrl}${route}`);
    assert.strictEqual(res.status, 404);
    assert.strictEqual(await res.text(), 'Not Found');
  });
}
