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

### Pre-scheme versions

Anchoring starts at `ps-server/3.27` and `ps-client/8.38`. Anything older was released before the scheme existed: it has no git tag, and its image carries no OCI labels, so its source commit can't be identified reliably. Those versions stay **permanently unanchored**. They are not tagged after the fact, because a guessed anchor is worse than none (decided on mihailsgo/psapp-saas#26).

This only matters where an old version is still cited, which today means one capability minimum: `local-eseal` needs `ps-server:3.26`. `psapp/scripts/release-check.sh` keeps these in an explicit `PRE_SCHEME_UNANCHORED` list and reports them as `PRE`, not `DRIFT`. The list is guarded:

- An entry must be older than the earliest `ps-<component>/*` tag, or the checker refuses to run (exit 2). A post-scheme version with a missing anchor gets tagged, not listed.
- `PRE` applies only to a `capabilities.json` minimum. If the compose pin or the release snapshot names a pre-scheme version, that is still `DRIFT`, because the current release must be anchored.
- Don't raise the `local-eseal` minimum to `3.27` to make the entry go away. A minimum records the first image that has the capability, and for `local-eseal` that image is `3.26`.

## Cutting a release

Steps 1-3 happen in the application repo (`psapp`); 4-7 happen here; 8 happens in `psapp` again, as the final check.

Steps 1-3 are enforced by tooling: pushing the `ps-<component>/<tag>` git tag triggers CI (`psapp/.github/workflows/build-and-push.yml`), which refuses to build unless that tag points at the commit being built and refuses to overwrite a tag already in the registry. Steps 4-7 are discipline, checked at the end by step 8; that is what `release-check.sh` (tags/capabilities) and `check-digest-drift.sh` (digests) are for.

**1. Anchor the commit.** The tag is what makes the image traceable, so it comes before the image exists, not after:

```bash
cd psapp
git tag ps-server/3.30
git push origin ps-server/3.30
```

**2. Let CI build, attest, and push it.** The tag push in step 1 starts the *Build, SBOM & Provenance* workflow: it stamps the same OCI labels the helper does, attaches an SPDX SBOM and a `mode=max` SLSA provenance attestation, pushes, and prints the pushed `tag@digest` in the run summary for step 5. This is the release path - it is the only one that produces an SBOM and full provenance.

```bash
gh run list --repo mihailsgo/psapp-saas --workflow build-and-push.yml --limit 1
```

**3. Fallback only: build and push by hand.** If CI cannot run (no Docker Hub secrets, Actions outage), `scripts/build-image.sh` produces the same labels but **no SBOM**, and only BuildKit's minimal default provenance (no builder identity) - record that in the release snapshot. Never use it for a tag CI has already pushed:

```bash
./scripts/build-image.sh server 3.30 --push   # or: client 8.40
```

With `--push` it refuses unless HEAD is already tagged `ps-<component>/<tag>` (step 1), refuses if the registry already has that tag (so it can't overwrite CI's attested image), and prints the pushed digest. It always refuses to move an existing git tag to a different commit, and stamps the revision `-dirty` if the working tree is not clean. A dirty release is not reproducible; commit first.

**4. Pin the new tag here.** Either edit `docker-compose.yml` directly, or let the upgrade script do it on a target host:

```bash
./installation-scripts/upgrade.sh --server-tag 3.30
```

If the image being replaced was digest-pinned, `upgrade.sh` never carries the old `@sha256:...` forward onto the new tag (the old digest belongs to the old content). It pins a digest only when `release/approved-digests.json` already approves exactly the requested tag - which is what makes an operator's upgrade to the release this checkout ships end digest-pinned. For a brand-new tag that is not approved yet, the reference is unpinned until the next step, and `validate-config.sh` fails until it is pinned and approved.

**5. Resolve and pin the digest.** Never skip this - a tag alone is mutable. Ask the registry what the tag resolves to right now:

```bash
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.30
# Digest:    sha256:<64 hex chars>
```

Edit `docker-compose.yml`'s image line to `mihailsgordijenko/ps-server:3.30@sha256:<that digest>`, and update (or add) the matching entry in `release/approved-digests.json` - `repository`, `tag`, `digest`. These two files are meant to be edited together; `installation-scripts/validate-config.sh` fails if they disagree. Before committing, re-pull the exact `repo:tag@digest` string to confirm it's real:

```bash
docker pull mihailsgordijenko/ps-server:3.30@sha256:<that digest>
```

**Pinning third-party images (Nginx, Keycloak, DMSS).** These don't go through the `ps-client`/`ps-server` tag-anchoring flow above - there's no `psapp` git tag or `build-image.sh` step for them - but they're pinned the same way: pick the tag (for Nginx, use the `stable` line, e.g. `docker buildx imagetools inspect nginx:stable` to find the current stable version - never pin a bare `latest`/`mainline` pull, which tracks whatever the maintainer ships next, not a fixed release), resolve its digest with `docker buildx imagetools inspect`, and update both `docker-compose.yml` and `release/approved-digests.json` together, exactly as above.

**6. Describe the release.** Add the new tag to `documentation/01-release-snapshot.md`: what changed, and what it implies for a deployment. Keep the note about what the tag *retains* from the previous one, so an operator skipping versions can still tell what they are getting. Then update the example `upgrade.sh --server-tag/--client-tag` commands in `05-upgrading-an-existing-deployment.md`, `05-01-what-upgrade-does-step-by-step.md`, and `05-02-upgrade-to-the-current-release.md`, which name the current release so they can be copy-pasted.

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

It reads this repo's `docker-compose.yml`, `documentation/01-release-snapshot.md`, and `release/capabilities.json`, and cross-checks them against `psapp`'s own `ps-client/*` / `ps-server/*` git tags: does the compose pin match what the snapshot doc says, and does every tag mentioned anywhere (including every capability minimum) actually exist as an anchor commit. The only exception is a pre-scheme capability minimum, which it prints as a `PRE` line (see [Pre-scheme versions](#pre-scheme-versions)). It exits non-zero and prints one `DRIFT:` line per disagreement if anything is out of sync - a release is not done until it passes clean. It defaults to finding this repo as a sibling checkout of `psapp`; pass `--deployment-dir <path>` if your layout differs. It is read-only and makes no changes to either repo. It does not check digests at all - only tags.

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
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.29 --format '{{ json .SBOM }}'
docker buildx imagetools inspect mihailsgordijenko/ps-server:3.29 --format '{{ json .Provenance }}'
```

That workflow requires `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` repository secrets to actually push - confirmed working end-to-end via a real `ps-server/3.29` tag push (CI-verification only, not a real release): tag-anchor check, Docker Hub login, build, SBOM/provenance attestation, and push all succeeded, and `docker buildx imagetools inspect` independently confirmed a real SPDX SBOM and SLSA provenance document on the pushed image. `build-image.sh`'s fallback path (step 3) does not produce an SBOM, and its provenance is BuildKit's default minimal one (no builder identity) - any tag built that way has no SBOM regardless of whether CI works for other tags. `ps-server:3.28` and `ps-client:8.39` were built that way, before CI existed.

The attestations are stored next to the image in the registry and are not signed: they prove what BuildKit recorded, but anyone with push access to the repository could replace them. Signing them (cosign keyless, or GitHub artifact attestations, which need a public repository or GitHub Enterprise for a private one) is not set up.

To confirm a digest itself is pinned and approved, rather than just present:

```bash
python3 -m json.tool release/approved-digests.json   # what's approved
./installation-scripts/check-digest-drift.sh          # approved vs. pinned vs. live
```

## Keeping digests current

Digests are pinned deliberately (step 5) and never auto-updated - `check-digest-drift.sh` only reports drift, for a human to review and re-pin. Renovate (configured by `renovate.json`, enabled on this repository) proposes updates: every Monday before 06:00 UTC it opens one grouped `chore(digests):` PR for newer third-party tags and changed digests, which goes through ordinary code review like any other change. It never merges on its own.

Renovate edits only `docker-compose.yml`. Before merging one of its PRs, in the same PR:

- update `release/approved-digests.json` to the new `tag` + `digest` for every image it bumped (`validate-config.sh` fails otherwise), re-verifying each digest with `docker buildx imagetools inspect`;
- update the matching lines of `documentation/01-release-snapshot.md`;
- drop any bump you are not approving (the first run, PR #12, dropped an nginx mainline bump; `renovate.json` now pins nginx to the 1.30.x stable line).

`ps-server` and `ps-client` tag bumps are excluded from Renovate: a new PadSign tag is a release and goes through the steps above (snapshot entry, capability registry), not a dependency bump. Renovate still reports a changed digest for the *same* PadSign tag - which should never happen, since tags are never moved, so treat such a PR as an incident.

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
