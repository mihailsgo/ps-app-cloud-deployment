# 30.2 How are errors handled if `ps-server` is not available when `registerPDF` is called?

- If `ps-server` is unavailable, the caller will receive a gateway/network failure from the front proxy layer (for example upstream `5xx`).
- If `ps-server` is available but dependencies are unstable, register flow returns controlled errors (`502/503/504` with `errorCode`, `429`, `503` queue timeout/circuit-open).
- For completed signing workflows, optional callback can report failures with technical details in `status`, for example:
  - `status: "error: <technical details>"`

