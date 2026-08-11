# 30.1 How does the solution handle a large number of documents sent at the same time (or almost at the same time)?

- `/api/registerPDF` is protected with an internal in-memory queue and concurrency limits.
- Throughput and backpressure are controlled by:
  - `REGISTER_PDF_MAX_CONCURRENCY`
  - `REGISTER_PDF_QUEUE_MAX_SIZE`
  - `REGISTER_PDF_QUEUE_WAIT_MS`
  - `REGISTER_PDF_UPSTREAM_TIMEOUT_MS`
  - `REGISTER_PDF_UPSTREAM_RETRIES`
- When limits are reached, backend returns deterministic overload/timeout responses (for example `429` queue full, `503` queue timeout or circuit open), instead of unstable random behavior.

