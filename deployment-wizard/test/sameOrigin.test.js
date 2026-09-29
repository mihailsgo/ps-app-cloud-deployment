'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');

const { refuseCrossSite, isCrossSiteRequestAllowed } = require('../lib/sameOrigin');

const HOST = 'padsign.example.com:8443';
const post = (extra) => isCrossSiteRequestAllowed({ method: 'POST', secFetchSite: undefined, origin: undefined, host: HOST, ...extra });

test('isCrossSiteRequestAllowed(): same-origin and typed-URL requests pass, other Sec-Fetch-Site values do not', () => {
  assert.equal(post({ secFetchSite: 'same-origin' }), true);
  assert.equal(post({ secFetchSite: 'none' }), true);
  assert.equal(post({ secFetchSite: 'same-site' }), false, 'the portal on :443 is same-site, not same-origin');
  assert.equal(post({ secFetchSite: 'cross-site' }), false);
  assert.equal(post({ secFetchSite: '' }), false);
});

test('isCrossSiteRequestAllowed(): Sec-Fetch-Site wins over Origin when both are present', () => {
  assert.equal(post({ secFetchSite: 'same-origin', origin: 'https://proxy.example.net' }), true);
  assert.equal(post({ secFetchSite: 'cross-site', origin: `https://${HOST}` }), false);
});

test('isCrossSiteRequestAllowed(): without Sec-Fetch-Site the Origin host must equal the Host header', () => {
  assert.equal(post({ origin: `https://${HOST}` }), true);
  assert.equal(post({ origin: 'https://padsign.example.com' }), false, 'the port is part of the host');
  assert.equal(post({ origin: 'https://evil.example.net' }), false);
  assert.equal(post({ origin: 'null' }), false);
  assert.equal(post({ origin: 'not a url' }), false);
});

test('isCrossSiteRequestAllowed(): no headers (curl, tests, scripts) passes; safe methods are never checked', () => {
  assert.equal(post({}), true);
  for (const method of ['GET', 'HEAD', 'OPTIONS', 'get']) {
    assert.equal(post({ method, secFetchSite: 'cross-site', origin: 'https://evil.example.net' }), true, method);
  }
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    assert.equal(post({ method, secFetchSite: 'cross-site' }), false, method);
  }
});

// ---------------------------------------------------------------------------
// As Express middleware, over real HTTP (http.request: fetch() will not let a
// script set Origin or Sec-Fetch-Site)
// ---------------------------------------------------------------------------

function makeApp() {
  const app = express();
  app.use(express.urlencoded({ extended: false }));
  app.use(refuseCrossSite);
  app.all('/thing', (req, res) => res.json({ reached: true, method: req.method, body: req.body || null }));
  return app;
}

function call(port, { method = 'POST', headers = {}, body, path = '/thing' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method, headers }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (err) { /* a redirect or an HTML page */ }
        resolve({ status: res.statusCode, json });
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function withServer(fn) {
  const server = http.createServer(makeApp());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    return await fn(server.address().port);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

const FORM = { 'Content-Type': 'application/x-www-form-urlencoded' };

test('middleware: a same-origin browser POST (form or JSON) reaches the route', async () => {
  await withServer(async (port) => {
    const host = `127.0.0.1:${port}`;
    const viaFetchMetadata = await call(port, { headers: { ...FORM, Host: host, 'Sec-Fetch-Site': 'same-origin' }, body: 'a=1' });
    assert.equal(viaFetchMetadata.status, 200);
    assert.deepEqual(viaFetchMetadata.json.body, { a: '1' });
    const viaOrigin = await call(port, { headers: { ...FORM, Host: host, Origin: `http://${host}` }, body: 'a=1' });
    assert.equal(viaOrigin.status, 200);
  });
});

test('middleware: a cross-site Sec-Fetch-Site is a 403 with the JSON sentence, and the route is not reached', async () => {
  await withServer(async (port) => {
    for (const site of ['cross-site', 'same-site']) {
      const res = await call(port, { headers: { ...FORM, 'Sec-Fetch-Site': site }, body: 'service=ps-server' });
      assert.equal(res.status, 403, site);
      assert.deepEqual(res.json, { error: 'Cross-site request refused.' });
    }
  });
});

test('middleware: an Origin that differs from Host is a 403', async () => {
  await withServer(async (port) => {
    const res = await call(port, { headers: { ...FORM, Origin: 'https://evil.example.net' }, body: 'service=ps-server' });
    assert.equal(res.status, 403);
    assert.deepEqual(res.json, { error: 'Cross-site request refused.' });
  });
});

test('middleware: a request with neither header passes, and GET is never checked', async () => {
  await withServer(async (port) => {
    assert.equal((await call(port, { headers: FORM, body: 'a=1' })).status, 200);
    const get = await call(port, { method: 'GET', headers: { 'Sec-Fetch-Site': 'cross-site', Origin: 'https://evil.example.net' } });
    assert.equal(get.status, 200);
    assert.equal(get.json.reached, true);
  });
});

// ---------------------------------------------------------------------------
// Wiring in the real app: the login POST is covered too, and a same-origin
// login attempt still gets its normal answer.
// ---------------------------------------------------------------------------

test('createApp(): a cross-site POST is refused before any route, a same-origin one reaches it', async () => {
  const { createApp } = require('../app');
  const server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const port = server.address().port;
    const host = `127.0.0.1:${port}`;
    const cross = await call(port, { path: '/api/auth', headers: { ...FORM, Host: host, 'Sec-Fetch-Site': 'same-site' }, body: 'token=x' });
    assert.equal(cross.status, 403);
    assert.deepEqual(cross.json, { error: 'Cross-site request refused.' });
    const same = await call(port, { path: '/api/auth', headers: { ...FORM, Host: host, 'Sec-Fetch-Site': 'same-origin' }, body: 'token=x' }).catch(() => ({ status: 0, json: {} }));
    assert.notEqual(same.status, 403);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
