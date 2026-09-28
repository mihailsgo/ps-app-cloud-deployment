# 13.1 How are many documents sent at (almost) the same time handled?

`POST /api/registerPDF` goes through an in-memory queue with a
concurrency limit in ps-server, so a burst of uploads is processed in a
controlled way instead of overloading the archive.

These `config/config.js` settings control throughput and back-pressure
([7.4 Server config.js](07-04-server-config-js.md)):

| Setting | Shipped value | Meaning |
|---|---|---|
| `REGISTER_PDF_MAX_CONCURRENCY` | `4` | uploads processed at the same time |
| `REGISTER_PDF_QUEUE_MAX_SIZE` | `100` | uploads that may wait in the queue |
| `REGISTER_PDF_QUEUE_WAIT_MS` | `30000` | longest wait in the queue |
| `REGISTER_PDF_UPSTREAM_TIMEOUT_MS` | `15000` | timeout of each archive call |
| `REGISTER_PDF_UPSTREAM_RETRIES` | `3` | attempts per archive call |

When a limit is reached, the caller gets a clear, repeatable answer rather
than random failures:

- `429` with `errorCode: "REGISTER_PDF_QUEUE_FULL"` when the queue is full;
- `503` with `errorCode: "REGISTER_PDF_QUEUE_TIMEOUT"` when an upload waited
  too long, or `"ARCHIVE_CIRCUIT_OPEN"` when the archive has failed
  repeatedly and ps-server stops calling it for a cool-down
  (`DEPENDENCY_CB_FAILURE_THRESHOLD`, `DEPENDENCY_CB_COOLDOWN_MS`).

Callers should retry these with a delay. The full list of responses is in
[7.5 registerPDF API](07-05-register-pdf-api.md).
