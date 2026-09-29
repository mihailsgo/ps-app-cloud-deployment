# 9.13 Signing activity log

ps-server records what happens to each document as a signing audit log: one JSON line per event, for
example that a document was registered, that its visual signature succeeded or that its e-seal was
skipped. The wizard's **Signing activity** tab reads it ([9.12](09-12-monitoring-from-the-wizard.md)),
and you can read it directly.

## What is recorded

| Event | When | Outcomes |
|---|---|---|
| `document.registered` | A document was registered for signing | `ok` |
| `signature.visual` | The visual signature was applied | `ok`, `failed` |
| `eseal` | The e-seal step ran | `ok`, `skipped`, `failed` |
| `signing.finalized` | The document was signed and finished | `ok` |
| `signing.failed` | Signing ended with an error | `failed` |

Each line has these fields:

| Field | Meaning |
|---|---|
| `padsignAudit` | Format version of the line, currently `1` |
| `ts` | Time of the event, UTC, ISO 8601 |
| `event`, `outcome` | As in the table above |
| `docid` | The document's ID |
| `user` | The signer's e-mail address |
| `userId` | The signer's Keycloak subject ID; `null` for a registration made with an API key ([7.5](07-05-register-pdf-api.md)) |
| `company` | The company the document belongs to |
| `documentNumber`, `filename` | The document number and the file name, when known |
| `profile` | The signature profile; in local e-seal mode, the e-seal profile name |
| `mode` | E-seal mode, `external` or `local` ([10](10-local-e-sealing.md)) |
| `demo` | `true` for a document signed in demo mode |
| `correlationId` | Ties the events of one request together |
| `status` | HTTP status of the step, where there is one |
| `error` | Error text, at most 500 characters |

String fields are cut at 256 characters. Access tokens, signature images and document contents are
never logged. If the log cannot be written, the signing request still succeeds.

An example line (wrapped here; in the file it is one line):

```json
{"padsignAudit":1,"ts":"2026-09-29T08:15:42.118Z","event":"signature.visual","outcome":"ok",
 "docid":"a1b2c3d4","user":"signer@example.com","userId":"5b0f3c1e-0000-0000-0000-000000000000",
 "company":"Example Ltd","documentNumber":"12345","filename":"contract.pdf",
 "profile":"LocalDemo","mode":"local","demo":false,"correlationId":"c0ffee","status":200}
```

## Where it is written

Every event goes to ps-server's standard output, so it also appears in `docker compose logs ps-server`.
When `AUDIT_LOG.enabled` is `true`, each event is also appended to
`<AUDIT_LOG.dir>/audit-YYYY-MM.jsonl`, one file per UTC month. With the default directory
`/signed-output/.padsign-audit`, the files are on the host under `signed-output/.padsign-audit/`. The
files are mode 640 and the directory mode 750, owned by ps-server's user, like the rest of
`signed-output/` ([14.1](14-01-file-map.md)).

## Requirements

- A ps-server image that writes the log. The minimum tag is the `signing-audit` entry in
  [`release/capabilities.json`](../release/capabilities.json). An older ps-server ignores the
  configuration below and writes nothing; the Signing activity tab then says to upgrade.
- The `AUDIT_LOG` block in `config/config.js` ([7.4](07-04-server-config-js.md#signing-audit-log)).
  `upgrade.sh` adds it to a deployment that lacks it, enabled, in its `signing-audit` migration
  ([9.6](09-06-what-upgrade-does.md)). Adding it to a host that still runs an older ps-server is
  harmless.
- For the wizard to read the files, the directory must be inside the deployment directory. If you
  point `AUDIT_LOG.dir` at a path that is not mounted from there, ps-server still writes it, but the
  Signing activity tab cannot show it.

## Retention

`AUDIT_LOG.retentionMonths` (default `12`) is how many months of files are kept. ps-server deletes
older files at startup and once a day. `0` keeps everything. The standard-output copy follows Docker's
log rotation instead ([9.10](09-10-monitoring-and-alerting.md#how-often-an-alert-repeats)).

## Privacy

The log records signers' e-mail addresses, which are personal data. Set `retentionMonths` to your
retention policy, and treat the files as you treat signed documents.

To switch the file off, set `enabled: false` in `AUDIT_LOG` and run
`docker compose restart ps-server`. Events still go to standard output.

The audit files are not part of a [support bundle](09-12-monitoring-from-the-wizard.md#support-bundles).
The copy on standard output is in ps-server's container log, which a bundle does include, so read a
bundle before you send it.

## Reading it without the wizard

The files belong to ps-server's user; read them as root or with `sudo`.

```bash
cd /opt/padsign
# Follow the current month
sudo tail -f signed-output/.padsign-audit/audit-$(date -u +%Y-%m).jsonl

# Failed events this month, with jq
sudo jq -r 'select(.outcome == "failed") | [.ts, .user, .event, .error] | @tsv' \
  signed-output/.padsign-audit/audit-$(date -u +%Y-%m).jsonl

# The same with python3, if jq is not installed
sudo cat signed-output/.padsign-audit/audit-$(date -u +%Y-%m).jsonl | python3 -c '
import json, sys
for line in sys.stdin:
    e = json.loads(line)
    if e.get("outcome") == "failed":
        print(e.get("ts"), e.get("user"), e.get("event"), e.get("error"), sep="\t")
'
```

## Why the tab may be empty

| The tab says | Cause | What to do |
|---|---|---|
| ps-server is older than the version that writes the log | The running image is below the minimum | Upgrade ([9.5](09-05-upgrading.md)) |
| The audit log is disabled | `AUDIT_LOG.enabled` is `false` | Set it to `true`, then `docker compose restart ps-server` |
| The directory is outside the deployment directory | `AUDIT_LOG.dir` is not under `signed-output/` on the host | Use the default directory, or read the files on the host as above |
| Nothing has been signed yet | The log exists but has no events in the selected range | Widen the date range, or sign a test document ([5.4](05-04-signing-smoke-test.md)) |

## Backups

The default directory is inside `signed-output/`, so the backup of signed documents covers it
([9.11 Backups](09-11-start-at-boot-backups-and-customized-hosts.md#backups)). Files older than
`retentionMonths` are deleted whether or not they were backed up.
