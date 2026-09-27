# 14.6 Image approval and digest pinning

A deployment runs only images that TrustLynx has approved for the release you
checked out. Every image in `docker-compose.yml` is pinned by tag **and**
immutable `sha256` digest, and the scripts refuse or fail anything else.

## The files in `release/`

| File | What it holds | Who reads it |
| --- | --- | --- |
| `release/approved-digests.json` | The one approved tag and digest per image for this release | `upgrade.sh` (approved-tag gate), `validate-config.sh` and `postdeploy-check.sh` (digest gate), `check-digest-drift.sh`, the Deployment Wizard's Upgrade panel |
| `release/capabilities.json` | The minimum ps-server / ps-client tag a feature needs | `upgrade.sh --require-capability`, `toggle-features.sh` |
| `release/cosign.pub` | Public key the ps-server / ps-client images are signed with | `upgrade.sh`, `validate-config.sh` (signature check) |
| `release/unsigned-legacy-images.json` | The two releases published before image signing, accepted unsigned by exact digest | the signature check |

You never edit these files. A new release updates them; you receive it with
`git pull` (see [9.5 Upgrading](09-05-upgrading.md)).

## What the gates do

- **`upgrade.sh`** refuses a `--server-tag` / `--client-tag` that
  `approved-digests.json` does not approve (exit 2, before anything is pulled),
  and verifies each image's signature against `release/cosign.pub`.
- **`validate-config.sh`** fails when an image in the effective compose model
  (`docker-compose.yml` plus any `COMPOSE_FILE` overlay, every profile) is not
  digest-pinned, or is pinned to a digest the release does not approve.
- **`check-digest-drift.sh`** (read-only) additionally asks the registry
  whether it still serves each approved digest for its tag. A `DRIFT` line
  means "look before you act": an upstream rebuild moved the tag, or the tag
  was changed. Your deployment keeps running the pinned digest either way.
  Report drift you cannot explain to TrustLynx support.

## Emergency hotfix: `--allow-unapproved`

`upgrade.sh --allow-unapproved` lets a tag through that the release does not
approve, with a loud warning. Use it only when TrustLynx support tells you to.
The image is pulled without a digest pin, so `validate-config.sh` and
`postdeploy-check.sh` keep failing until a release that approves the tag is
pulled. The override is recorded in `deployment-evidence.json` as
`unapproved_override`.

## Rolling back

`rollback.sh` restores the images a previous `upgrade.sh` recorded, with
their digests. If a snapshot has no digest for an image, the script says so
and the image is left pinned by tag only; pull the release that matches it
or contact TrustLynx support. See [9.8 Rollback](09-08-rollback.md).
