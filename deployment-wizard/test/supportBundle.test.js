'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const test = require('node:test');
const { after } = test;
const assert = require('node:assert/strict');

const {
  BUNDLE_DIR,
  NAME_RE,
  SINCE_CHOICES,
  parseBundleOutput,
  createBundle,
  resolveBundle,
  listBundles,
  isBundleRunning
} = require('../lib/supportBundle');

const tmpDirs = [];

function tmpDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'padsign-support-bundle-test-'));
  tmpDirs.push(dir);
  return dir;
}

after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true });
});

// Creating a symlink needs a privilege on Windows; where it is unavailable
// the symlink-escape tests are skipped rather than failed.
const SYMLINKS_UNAVAILABLE = (() => {
  const dir = tmpDir();
  try {
    fs.writeFileSync(path.join(dir, 't'), 'x');
    fs.symlinkSync(path.join(dir, 't'), path.join(dir, 'l'), 'file');
    return false;
  } catch (err) {
    return 'symlinks are not available on this platform/user';
  }
})();

const GOOD_NAME = 'padsign-support-padsign.example.com-20260929T100000Z.tar.gz';

// ---- parseBundleOutput ----

test('parseBundleOutput(): extracts checks and the BUNDLE path from a normal run', () => {
  const stdout = [
    '  OK   collected docker compose logs',
    '  WARN config/config.js: contains secrets, redacted',
    'BUNDLE /opt/padsign/support-bundles/padsign-support-padsign.example.com-20260929T100000Z.tar.gz'
  ].join('\n');
  const result = parseBundleOutput(stdout);
  assert.equal(result.path, '/opt/padsign/support-bundles/padsign-support-padsign.example.com-20260929T100000Z.tar.gz');
  assert.equal(result.checks.length, 2);
  assert.equal(result.checks[0].status, 'ok');
  assert.equal(result.checks[1].status, 'warn');
});

test('parseBundleOutput(): the BUNDLE line is not folded into the last check\'s message', () => {
  const result = parseBundleOutput(`  WARN config: redacted\nBUNDLE /x/${GOOD_NAME}\n`);
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].message, 'config: redacted');
  assert.equal(result.path, `/x/${GOOD_NAME}`);
});

test('parseBundleOutput(): handles CRLF line endings', () => {
  const stdout = '  OK   step one\r\nBUNDLE C:\\bundles\\padsign-support-h-20260929T100000Z.tar.gz\r\n';
  const result = parseBundleOutput(stdout);
  assert.equal(result.path, 'C:\\bundles\\padsign-support-h-20260929T100000Z.tar.gz');
  assert.equal(result.checks.length, 1);
});

test('parseBundleOutput(): keeps the LAST BUNDLE line when more than one appears', () => {
  const stdout = 'BUNDLE /first/one.tar.gz\nBUNDLE /second/one.tar.gz\n';
  const result = parseBundleOutput(stdout);
  assert.equal(result.path, '/second/one.tar.gz');
});

test('parseBundleOutput(): path is null when no BUNDLE line is present', () => {
  const result = parseBundleOutput('  OK   did a thing\n');
  assert.equal(result.path, null);
});

// ---- resolveBundle ----

test('resolveBundle(): rejects a relative traversal name', () => {
  assert.equal(resolveBundle('../x.tar.gz'), null);
});

test('resolveBundle(): rejects a name shaped to smuggle a traversal after a valid-looking prefix', () => {
  assert.equal(resolveBundle('padsign-support-a-20260929T100000Z.tar.gz/../..'), null);
});

test('resolveBundle(): rejects a name containing a backslash', () => {
  assert.equal(resolveBundle('padsign-support-a-20260929T100000Z.tar.gz\\..\\..\\etc'), null);
});

test('resolveBundle(): rejects a valid-looking name that does not exist', () => {
  const dir = tmpDir();
  assert.equal(resolveBundle('padsign-support-nope-20260929T100000Z.tar.gz', { dir }), null);
});

test('resolveBundle(): accepts an existing file matching NAME_RE inside dir', () => {
  const dir = tmpDir();
  const name = 'padsign-support-padsign.example.com-20260929T100000Z.tar.gz';
  fs.writeFileSync(path.join(dir, name), 'fake tarball contents');
  const resolved = resolveBundle(name, { dir });
  assert.ok(resolved);
  assert.equal(fs.realpathSync(resolved), fs.realpathSync(path.join(dir, name)));
});

test('resolveBundle(): a directory named like a bundle is not a bundle', () => {
  const dir = tmpDir();
  fs.mkdirSync(path.join(dir, GOOD_NAME));
  assert.equal(resolveBundle(GOOD_NAME, { dir }), null);
});

test('resolveBundle(): a symlink escaping dir is refused', { skip: SYMLINKS_UNAVAILABLE }, () => {
  const dir = tmpDir();
  const outside = tmpDir();
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'top secret');
  fs.symlinkSync(path.join(outside, 'secret.txt'), path.join(dir, GOOD_NAME), 'file');
  assert.equal(resolveBundle(GOOD_NAME, { dir }), null);
});

test('resolveBundle(): a symlink to a badly named file inside dir is refused', { skip: SYMLINKS_UNAVAILABLE }, () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'x');
  fs.symlinkSync(path.join(dir, 'notes.txt'), path.join(dir, GOOD_NAME), 'file');
  assert.equal(resolveBundle(GOOD_NAME, { dir }), null, 'the RESOLVED name must match NAME_RE too');
});

test('NAME_RE: sanity-checks a well-formed bundle name', () => {
  assert.match('padsign-support-padsign.example.com-20260929T100000Z.tar.gz', NAME_RE);
  assert.doesNotMatch('padsign-support-h-2026092T100000Z.tar.gz', NAME_RE); // short date
  assert.doesNotMatch('padsign-support-h-20260929T100000Z.tar', NAME_RE); // wrong extension
});

// ---- listBundles ----

test('listBundles(): missing directory yields an empty list, never throws', () => {
  const dir = path.join(tmpDir(), 'does-not-exist');
  assert.deepEqual(listBundles({ dir }), []);
});

test('listBundles(): orders newest first and ignores non-matching files', () => {
  const dir = tmpDir();
  const older = 'padsign-support-a-20260101T000000Z.tar.gz';
  const newer = 'padsign-support-a-20260201T000000Z.tar.gz';
  fs.writeFileSync(path.join(dir, older), 'x');
  fs.writeFileSync(path.join(dir, newer), 'yy');
  fs.writeFileSync(path.join(dir, 'not-a-bundle.txt'), 'ignored');

  const now = Date.now();
  fs.utimesSync(path.join(dir, older), new Date(now - 60000), new Date(now - 60000));
  fs.utimesSync(path.join(dir, newer), new Date(now), new Date(now));

  const list = listBundles({ dir });
  assert.equal(list.length, 2);
  assert.equal(list[0].name, newer);
  assert.equal(list[1].name, older);
  assert.equal(list[0].sizeBytes, 2);
  assert.equal(typeof list[0].createdAt, 'string');
  assert.ok(!isNaN(Date.parse(list[0].createdAt)));
});

test('listBundles(): ignores a directory named like a bundle', () => {
  const dir = tmpDir();
  fs.mkdirSync(path.join(dir, GOOD_NAME));
  assert.deepEqual(listBundles({ dir }), []);
});

test('listBundles(): ignores a symlink named like a bundle', { skip: SYMLINKS_UNAVAILABLE }, () => {
  const dir = tmpDir();
  const outside = tmpDir();
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'top secret');
  fs.symlinkSync(path.join(outside, 'secret.txt'), path.join(dir, GOOD_NAME), 'file');
  assert.deepEqual(listBundles({ dir }), []);
});

test('listBundles(): respects limit', () => {
  const dir = tmpDir();
  for (let i = 0; i < 5; i++) {
    fs.writeFileSync(path.join(dir, `padsign-support-a-2026010${i}T000000Z.tar.gz`), 'x');
  }
  assert.equal(listBundles({ dir, limit: 3 }).length, 3);
});

// ---- createBundle ----

test('createBundle(): rejects an invalid `since` with code BAD_SINCE', async () => {
  await assert.rejects(
    () => createBundle({ since: '9d', exec: async () => ({ stdout: '' }) }),
    (err) => {
      assert.equal(err.code, 'BAD_SINCE');
      return true;
    }
  );
});

test('createBundle(): rejects an invalid host with code BAD_HOST and never runs the script', async () => {
  let called = false;
  const exec = async () => { called = true; return { stdout: '' }; };
  for (const host of ['-x', 'a b', 'a/b', 'a;b', 'a\nb']) {
    await assert.rejects(() => createBundle({ host, exec, dir: tmpDir() }), (err) => {
      assert.equal(err.code, 'BAD_HOST');
      return true;
    }, host);
  }
  assert.equal(called, false);
  assert.equal(isBundleRunning(), false);
});

test('createBundle(): resolves { name, sizeBytes, checks } when the script reports a valid bundle', async () => {
  const dir = tmpDir();
  const name = 'padsign-support-padsign.example.com-20260929T100000Z.tar.gz';
  const bundlePath = path.join(dir, name);

  const exec = async () => {
    fs.writeFileSync(bundlePath, 'fake tarball contents, 22 bytes');
    return {
      stdout: `  OK   collected logs\nBUNDLE ${bundlePath}\n`,
      stderr: ''
    };
  };

  const result = await createBundle({ host: 'padsign.example.com', since: '24h', exec, dir });
  assert.equal(result.name, name);
  assert.ok(result.sizeBytes > 0);
  assert.equal(result.checks.length, 1);
  assert.equal(isBundleRunning(), false);
  assert.ok(resolveBundle(result.name, { dir }), 'a reported name must round-trip through resolveBundle');
});

test('createBundle(): rejects a reported path that is a symlink escaping dir', { skip: SYMLINKS_UNAVAILABLE }, async () => {
  const dir = tmpDir();
  const outside = tmpDir();
  const target = path.join(outside, 'secret.txt');
  const link = path.join(dir, GOOD_NAME);
  fs.writeFileSync(target, 'top secret');
  fs.symlinkSync(target, link, 'file');
  const exec = async () => ({ stdout: `BUNDLE ${link}\n`, stderr: '' });
  await assert.rejects(() => createBundle({ exec, dir }), /did not report a bundle/);
  assert.equal(isBundleRunning(), false);
});

test('createBundle(): rejects a reported path that is a directory', async () => {
  const dir = tmpDir();
  fs.mkdirSync(path.join(dir, GOOD_NAME));
  const exec = async () => ({ stdout: `BUNDLE ${path.join(dir, GOOD_NAME)}\n`, stderr: '' });
  await assert.rejects(() => createBundle({ exec, dir }), /did not report a bundle/);
});

test('createBundle(): rejects a file in a subdirectory of dir (must be directly inside)', async () => {
  const dir = tmpDir();
  fs.mkdirSync(path.join(dir, 'sub'));
  const nested = path.join(dir, 'sub', GOOD_NAME);
  fs.writeFileSync(nested, 'x');
  const exec = async () => ({ stdout: `BUNDLE ${nested}\n`, stderr: '' });
  await assert.rejects(() => createBundle({ exec, dir }), /did not report a bundle/);
});

test('createBundle(): rejects when the reported bundle path resolves outside `dir`', async () => {
  const dir = tmpDir();
  const outsideDir = tmpDir();
  const name = 'padsign-support-h-20260929T100000Z.tar.gz';
  const outsidePath = path.join(outsideDir, name);

  const exec = async () => {
    fs.writeFileSync(outsidePath, 'x');
    return { stdout: `BUNDLE ${outsidePath}\n`, stderr: '' };
  };

  await assert.rejects(
    () => createBundle({ exec, dir }),
    /did not report a bundle/
  );
  assert.equal(isBundleRunning(), false);
});

test('createBundle(): rejects with the script\'s ERROR:/stderr line when exec() rejects', async () => {
  const dir = tmpDir();
  const exec = async () => {
    const err = new Error('Command failed');
    err.code = 1;
    err.stderr = 'some noise\nERROR: disk full\n';
    throw err;
  };
  await assert.rejects(() => createBundle({ exec, dir }), /disk full/);
  assert.equal(isBundleRunning(), false);
});

test('createBundle(): a rejection with no stderr is reported without the command line', async () => {
  const exec = async () => {
    const err = new Error('Command failed: bash /opt/padsign/installation-scripts/support-bundle.sh --since 24h');
    err.code = 1;
    throw err;
  };
  await assert.rejects(() => createBundle({ exec, dir: tmpDir() }), (err) => {
    assert.equal(err.message, 'exited with code 1');
    return true;
  });
});

test('createBundle(): a second concurrent call rejects with BUNDLE_IN_PROGRESS; flag clears once the first settles', async () => {
  const dir = tmpDir();
  const name = 'padsign-support-h-20260929T100000Z.tar.gz';
  const bundlePath = path.join(dir, name);

  let releaseFirst;
  const gate = new Promise((resolve) => { releaseFirst = resolve; });

  const firstExec = async () => {
    await gate;
    fs.writeFileSync(bundlePath, 'x');
    return { stdout: `BUNDLE ${bundlePath}\n`, stderr: '' };
  };

  const firstPromise = createBundle({ exec: firstExec, dir });

  assert.equal(isBundleRunning(), true);
  await assert.rejects(
    () => createBundle({ exec: async () => ({ stdout: '' }), dir }),
    (err) => {
      assert.equal(err.code, 'BUNDLE_IN_PROGRESS');
      return true;
    }
  );

  releaseFirst();
  const result = await firstPromise;
  assert.equal(result.name, name);
  assert.equal(isBundleRunning(), false);
});

test('SINCE_CHOICES: matches the documented values', () => {
  assert.deepEqual(SINCE_CHOICES, ['1h', '6h', '24h', '72h', '168h']);
});

test('BUNDLE_DIR: points at support-bundles/ under the project root', () => {
  assert.ok(BUNDLE_DIR.endsWith(path.join('support-bundles')));
});
