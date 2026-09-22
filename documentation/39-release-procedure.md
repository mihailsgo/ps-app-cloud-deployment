# 39. Release Procedure

How a new `ps-client` / `ps-server` image gets built, published, and pinned here.

## What is authoritative

**This repository's `docker-compose.yml` is the source of truth for released image tags.** The application repository (`psapp`) has a `docker-compose.yml` too, but that one is a local development stack: its pins lag deliberately and are not release tags. Never sync them to production, and never read them to answer "what is deployed?".

For that question, read in this order:

1. `docker-compose.yml` here - what a deployment actually runs.
2. `documentation/01-release-snapshot.md` - what each tag contains and what it implies for deployment.
3. `release/capabilities.json` - the minimum tag each deployment-relevant capability needs.

Nothing enforces that these three, plus `psapp`'s own git tags, agree with each other - see `psapp/scripts/release-check.sh` in step 7 below, which is the automated form of this cross-check.

## The tag scheme

`ps-client` and `ps-server` are versioned independently, by Docker tag (`ps-client:8.x`, `ps-server:3.x`), because they deploy independently. These are **not** semver and nothing consumes them as semver.

- Bump the minor for any change that ships in an image.
- **Never reuse or move a tag once pushed.**
- Every image is anchored to the commit it was built from by a git tag in the application repo: `ps-client/<tag>`, `ps-server/<tag>`.

## Cutting a release

Steps 1-3 happen in the application repo (`psapp`); 4-6 happen here; 7 happens in `psapp` again, as the final check.

There is no CI and no git hook enforcing this order - it is discipline, checked at the end by step 7. `build-image.sh` enforces step 1 before step 2 itself (it refuses to build from an untagged commit), but nothing stops steps 4-6 from being forgotten; that is what `release-check.sh` is for.

**1. Anchor the commit first.** The tag is what makes the image traceable, so it comes before the image exists, not after:

```bash
cd psapp
git tag ps-server/3.28
git push origin ps-server/3.28
```

**2. Build the image with provenance.** Use the helper, never a bare `docker build` - it stamps the OCI labels that make the image traceable, and refuses to run at all if HEAD isn't already tagged `ps-<component>/<tag>`:

```bash
./scripts/build-image.sh server 3.28          # or: client 8.39
```

It also refuses to move an existing `ps-<component>/<tag>` git tag to a different commit, and stamps the revision `-dirty` if the working tree is not clean. A dirty release is not reproducible; commit first.

**3. Push the image.**

```bash
./scripts/build-image.sh server 3.28 --push
```

**4. Pin the new tag here.** Either edit `docker-compose.yml` directly, or let the upgrade script do it on a target host:

```bash
./installation-scripts/upgrade.sh --server-tag 3.28
```

**5. Describe the release.** Add the new tag to `documentation/01-release-snapshot.md`: what changed, and what it implies for a deployment. Keep the note about what the tag *retains* from the previous one, so an operator skipping versions can still tell what they are getting.

**6. Register any new capability.** If the release introduces something a deployment decision depends on - a config flag that older images ignore, a route that can now be closed, an endpoint an external component polls - add it to `release/capabilities.json`:

```json
"receive-back": {
  "min": { "ps-server": "3.27" },
  "why": "Explain what breaks, or silently no-ops, on an older image."
}
```

This is the only place that number belongs. `upgrade.sh` and `toggle-features.sh` read it at run time, so the gate and the documentation cannot disagree. Do not add a matching constant to a script.

**7. Run the release checker.** Back in `psapp`, cross-validate that steps 1-6 actually agree with each other:

```bash
cd ../psapp
./scripts/release-check.sh
```

It reads this repo's `docker-compose.yml`, `documentation/01-release-snapshot.md`, and `release/capabilities.json`, and cross-checks them against `psapp`'s own `ps-client/*` / `ps-server/*` git tags: does the compose pin match what the snapshot doc says, and does every tag mentioned anywhere (including every capability minimum) actually exist as an anchor commit. It exits non-zero and prints one `DRIFT:` line per disagreement if anything is out of sync - a release is not done until it passes clean. It defaults to finding this repo as a sibling checkout of `psapp`; pass `--deployment-dir <path>` if your layout differs. It is read-only and makes no changes to either repo.

## Verifying provenance

Any running container maps back to its source commit:

```bash
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
  mihailsgordijenko/ps-server:3.28
```

A tag shown as `unstamped`, or a revision of `unknown`, means the image was built without the helper and cannot be traced - rebuild it before releasing.

## Gating an upgrade on a capability

When a change outside the upgrade script depends on the image version, assert it in the same invocation so the script refuses rather than leaving a half-configured deployment. The main case is closing `GET /archive/api/document/{docid}/download` behind authentication at nginx, which only works against a client that sends the Keycloak Bearer token:

```bash
./installation-scripts/upgrade.sh --client-tag 8.38 \
  --require-capability closable-download-route
```

Add `--plan-only` to check without changing anything. To list the capabilities the registry defines:

```bash
python3 -m json.tool release/capabilities.json
```
