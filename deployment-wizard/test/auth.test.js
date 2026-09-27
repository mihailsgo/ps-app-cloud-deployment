'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { checkToken, getAccessToken } = require('../lib/auth');
const ACCESS_TOKEN = getAccessToken();

test('checkToken() accepts the exact token', () => {
  assert.equal(checkToken(ACCESS_TOKEN), true);
});

test('checkToken() forgives whitespace a copy-paste adds around the token', () => {
  assert.equal(checkToken(`  ${ACCESS_TOKEN}\n`), true);
});

test('checkToken() rejects empty, blank, wrong and non-string input', () => {
  assert.equal(checkToken(''), false);
  assert.equal(checkToken('   '), false);
  assert.equal(checkToken(ACCESS_TOKEN.slice(1)), false);
  assert.equal(checkToken(undefined), false);
  assert.equal(checkToken(['x']), false);
});
