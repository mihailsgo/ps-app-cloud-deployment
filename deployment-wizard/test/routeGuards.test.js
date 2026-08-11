'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { requireReached, STEP_URL } = require('../routes/wizardSteps');

function mockReq(furthestStepReached) {
  return { session: { wizard: { furthestStepReached } } };
}

function mockRes() {
  const res = { redirectedTo: null };
  res.redirect = (url) => { res.redirectedTo = url; };
  return res;
}

test('STEP_URL(): step 1 is the root path, all others are /wizard/step/N', () => {
  assert.equal(STEP_URL(1), '/');
  assert.equal(STEP_URL(2), '/wizard/step/2');
  assert.equal(STEP_URL(7), '/wizard/step/7');
});

test('requireReached(step): redirects back to the furthest reached step when the operator is behind', () => {
  const req = mockReq(2);
  const res = mockRes();
  let nextCalled = false;
  requireReached(4)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, false);
  assert.equal(res.redirectedTo, '/wizard/step/2');
});

test('requireReached(step): lets the request through once furthestStepReached has caught up', () => {
  const req = mockReq(4);
  const res = mockRes();
  let nextCalled = false;
  requireReached(4)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
  assert.equal(res.redirectedTo, null);
});

test('requireReached(step): also lets the request through when the operator is further ahead (e.g. clicked a done step-dot)', () => {
  const req = mockReq(7);
  const res = mockRes();
  let nextCalled = false;
  requireReached(4)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
});

// Steps 6 and 7 are reached via a redirect right after their own POST
// succeeds (POST /api/deploy bumps furthestStepReached to 6; step 7's own
// GET handler bumps it to 7 once rendered) — so the GET guard for step N
// must check against furthest >= N-1, not furthest >= N, or the very
// redirect that's supposed to land the operator on the page would bounce
// them straight back (the chicken-egg bug fixed during the nav/UX pass).
test('requireReached(6, 5): step 6 is reachable as soon as furthest is 5 — before anything has bumped it to 6', () => {
  const req = mockReq(5);
  const res = mockRes();
  let nextCalled = false;
  requireReached(6, 5)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
});

test('requireReached(7, 6): blocked while furthest is still 5 (deploy has not completed yet)', () => {
  const req = mockReq(5);
  const res = mockRes();
  let nextCalled = false;
  requireReached(7, 6)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, false);
  assert.equal(res.redirectedTo, '/wizard/step/5');
});

test('requireReached(7, 6): reachable once furthest is 6', () => {
  const req = mockReq(6);
  const res = mockRes();
  let nextCalled = false;
  requireReached(7, 6)(req, res, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
});
