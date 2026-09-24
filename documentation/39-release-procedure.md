# 39. Release Procedure

How a new `ps-client` / `ps-server` image gets built, published, and pinned here.

## What is authoritative

**This repository's `docker-compose.yml` is the source of truth for released image tags and digests.** The application repository (`psapp`) has a `docker-compose.yml` too, but that one is a local development stack: its pins lag deliberately and are not release tags. Never sync them to production, and never read them to answer "what is deployed?".

For that question, read in this order:

1. `docker-compose.yml` here - what a deployment actually runs. Every image is pinned `tag@sha256:digest`; the tag is for humans, the digest is what Docker actually pulls.
2. `documentation/01-release-snapshot.md` - what each tag contains and what it implies for deployment.
3. `release/capabilities.json` - the minimum tag each deployment-relevant capability needs.
4. `release/approved-digests.json` - the digest approved for each currently-pinned tag. `installation-scripts/validate-config.sh` fails if `docker-compose.yml` disagrees with it; `installation-scripts/check-digest-drift.sh` fails if it disagrees with what the registry serves today.

Nothing enforces that these four, plus `psapp`'s own git tags, agree with each other - see `psapp/scripts/release-check.sh` in step 8 below (tags/capabilities) and `installation-scripts/check-digest-drift.sh` (digests), which are the automated forms of this cross-check.

## The tag scheme

`ps-client` and `ps-server` are versioned independently, by Docker tag (`ps-client:8.x`, `ps-server:3.x`), because they deploy independently. These are **not** semver and nothing consumes them as semver.

- Bump the minor for any change that ships in an image.
- **Never reuse or move a tag once pushed.**
- Every image is anchored to the commit it was built from by a git tag in the application repo: `ps-client/<tag>`, `ps-server/<tag>`.

## Cutting a release

Steps 1-3 happen in the application repo (`psapp`); 4-7 happen here; 8 happens in `psapp` again, as the final check.

There is no CI and no git hook enforcing this order - it is discipline, checked at the end by step 8. `build-image.sh` enforces step 1 before step 2 itself (it refuses to build from an untagged commit), but nothing stops steps 4-7 from being forgotten; that is what `release-check.sh` (tags/capabilities) and `check-digest-drift.sh` (digests) are for.

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

This bumps the tag only. If the image being replaced was digest-pinned, `upgrade.sh` deliberately drops the old `@sha256:...` rather than carry it forward onto the new tag (the old digest belongs to the old content) - the new reference is unpinned until the next step, and `validate-config.sh` will fail until it is pinned again.

**5. Resolve and pin the digest.** Never skip this - a tag alone is mutable. Ask the registry what the tag resolves to right now:

```bash
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.28
# Digest:    sha256:<64 hex chars>
```

Edit `docker-compose.yml`'s image line to `mihailsgordijenko/ps-server:3.28@sha256:<that digest>`, and update (or add) the matching entry in `release/approved-digests.json` - `repository`, `tag`, `digest`. These two files are meant to be edited together; `installation-scripts/validate-config.sh` fails if they disagree. Before committing, re-pull the exact `repo:tag@digest` string to confirm it's real:

```bash
docker pull mihailsgordijenko/ps-server:3.28@sha256:<that digest>
```

**Pinning third-party images (Nginx, Keycloak, DMSS).** These don't go through the `ps-client`/`ps-server` tag-anchoring flow above - there's no `psapp` git tag or `build-image.sh` step for them - but they're pinned the same way: pick the tag (for Nginx, use the `stable` line, e.g. `docker buildx imagetools inspect nginx:stable` to find the current stable version - never pin a bare `latest`/`mainline` pull, which tracks whatever the maintainer ships next, not a fixed release), resolve its digest with `docker buildx imagetools inspect`, and update both `docker-compose.yml` and `release/approved-digests.json` together, exactly as above.

**6. Describe the release.** Add the new tag to `documentation/01-release-snapshot.md`: what changed, and what it implies for a deployment. Keep the note about what the tag *retains* from the previous one, so an operator skipping versions can still tell what they are getting.

**7. Register any new capability.** If the release introduces something a deployment decision depends on - a config flag that older images ignore, a route that can now be closed, an endpoint an external component polls - add it to `release/capabilities.json`:

```json
"receive-back": {
  "min": { "ps-server": "3.27" },
  "why": "Explain what breaks, or silently no-ops, on an older image."
}
```

This is the only place that number belongs. `upgrade.sh` and `toggle-features.sh` read it at run time, so the gate and the documentation cannot disagree. Do not add a matching constant to a script.

**8. Run the release checker, and the digest drift checker.** Back in `psapp`, cross-validate that steps 1-7 actually agree with each other:

```bash
cd ../psapp
./scripts/release-check.sh
```

It reads this repo's `docker-compose.yml`, `documentation/01-release-snapshot.md`, and `release/capabilities.json`, and cross-checks them against `psapp`'s own `ps-client/*` / `ps-server/*` git tags: does the compose pin match what the snapshot doc says, and does every tag mentioned anywhere (including every capability minimum) actually exist as an anchor commit. It exits non-zero and prints one `DRIFT:` line per disagreement if anything is out of sync - a release is not done until it passes clean. It defaults to finding this repo as a sibling checkout of `psapp`; pass `--deployment-dir <path>` if your layout differs. It is read-only and makes no changes to either repo. It does not check digests at all - only tags.

Then, back here, check that digests themselves haven't drifted from what's approved:

```bash
./installation-scripts/check-digest-drift.sh
```

It cross-checks `docker-compose.yml`, `release/approved-digests.json`, and what each registry currently serves for the pinned tags. Also read-only; also exits non-zero with one `DRIFT:` line per disagreement.

## Verifying provenance

Any running container maps back to its source commit:

```bash
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
  mihailsgordijenko/ps-server:3.28
```

A tag shown as `unstamped`, or a revision of `unknown`, means the image was built without the helper and cannot be traced - rebuild it before releasing.

CI (`psapp/.github/workflows/build-and-push.yml`) additionally attaches an SBOM and build-provenance attestation to `ps-client`/`ps-server` images pushed by a tag push, via `docker buildx build --sbom=true --provenance=mode=max`. Verify a specific image carries both:

```bash
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.28 --format '{{ json .SBOM }}'
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.28 --format '{{ json .Provenance }}'
```

That workflow requires `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` repository secrets to actually push - confirmed working end-to-end via a real `ps-server/3.29` tag push (CI-verification only, not a real release): tag-anchor check, Docker Hub login, build, SBOM/provenance attestation, and push all succeeded, and `docker buildx imagetools inspect` independently confirmed a real SPDX SBOM and SLSA provenance document on the pushed image. `build-image.sh`'s manual path (steps 1-3 above) still does not produce attestations - any tag built that way, rather than through CI, has none regardless of whether CI works for other tags.

To confirm a digest itself is pinned and approved, rather than just present:

```bash
python3 -m json.tool release/approved-digests.json   # what's approved
./installation-scripts/check-digest-drift.sh          # approved vs. pinned vs. live
```

## Keeping digests current

Digests are pinned deliberately (step 5) and never auto-updated - `check-digest-drift.sh` only reports drift, for a human to review and re-pin. `renovate.json` at the repository root scaffolds an automated alternative (Renovate's `docker-compose` manager, `pinDigests: true`): once the Renovate GitHub App (or a self-hosted runner) is enabled on this repository, it opens a PR whenever a pinned tag's digest changes upstream, which goes through ordinary code review like any other change. It needs no additional secrets - every image here is public. Nothing in this repository activates it by itself.

**DMSS images need a boot + seal check, not just a diff review.** A DMSS bump can pass `validate-config.sh` and `check-digest-drift.sh` and still not work with this repo's config. Renovate's first DMSS PR did exactly that: `container-signature-service` 24.3.3.9 did not start without `spring.mail.*` (`application.yml` now carries a placeholder), and every tag from 24.3.0.43 to 24.3.3.9 seals the B_BES `LocalDemo` profile once, then treats it as `PAdES-BASELINE-LT` and fails every later seal on the TSA. So `renovate.json` puts `trustlynx/*` images in their own PR, labelled `needs-seal-smoke`, and it blocks the container-signature tags already known to fail. Before approving a DMSS PR, or moving a DMSS pin by hand, check out the branch and run:

```bash
./installation-scripts/dmss-seal-smoke.sh
# or, to try a tag before pinning it:
./installation-scripts/dmss-seal-smoke.sh --cs-image trustlynx/container-signature-service:<tag>
```

It boots the pinned container-signature and digital-stamping images against this repo's own DMSS config in a throwaway compose project (its own project name, no host ports), then does 3 consecutive local e-seals. One seal is not enough: the profile bug above only shows from the second. It exits non-zero on a failed boot, a failed seal, or a signature level that changes between seals, and removes everything it created. Paste its output into the review and approve only on `PASSED`. It covers container-signature and digital-stamping only. An archive or archive-fallback bump also needs a real document round trip (`registerPDF` through signing), because what breaks there is storage ownership, not sealing.

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
