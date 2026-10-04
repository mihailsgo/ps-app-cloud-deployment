  module.exports = {
    // Container-signature service, in-network (see "DMSS service addresses" below).
    VISUAL_SIGNATURE_API_TEMPLATE: "http://dmss-container-and-signature-services:8092/api/signing/visual/pdf/{docid}/sign",
    STAMP_API_URL: "https://eseal.trustlynx.com/api/gateway/esealing/sign/api-key/DEMOCOMPANY",
    STAMP_API_KEY: "CHANGE_ME",
    STAMP_COMPANY_ID: "CHANGE_ME",
    STAMP_COMPANY_SECRET: "CHANGE_ME",
    API_PROTECT_LOGS_ENABLED: false,
    PORT: 3001,
    // ── DMSS service addresses ─────────────────────────────────────────────
    // How ps-server reaches the archive and container-signature services:
    // directly, by Docker service name, not through nginx and the public
    // hostname. Neither service checks a credential, so nothing is sent with
    // these calls; the Docker network is what keeps them private
    // (documentation/07-04-server-config-js.md). That is what lets nginx's
    // /archive/api/ and /container/api/ be closed to outside callers
    // (documentation/06-01-route-protection.md). Service names and ports match
    // the proxy_pass lines in nginx/nginx.conf. The code only concatenates these
    // values, so the public form (https://<host>/archive/api/..., what releases
    // up to the 3.34 image shipped) keeps working if you set it; a host that
    // runs on it switches with `upgrade.sh --use-internal-dmss-urls` (and back
    // with --use-public-dmss-urls).
    ARCHIVE_API_BASE_URL: "http://dmss-archive-services:8090/api/",
    CREATE_DOCUMENT_API_URL: "http://dmss-archive-services:8090/api/document/create",
    FORM_FILL_API_URL: "http://dmss-container-and-signature-services:8092/api/forms/fill/template/application",
    DOCUMENT_DOWNLOAD_API_URL: "http://dmss-archive-services:8090/api/document/",
    // The archive address a webhook receiver can reach. Only the `archiveUrl`
    // field of webhook payloads uses it; ps-server's own calls use the URLs
    // above. Leave it out and the payload carries ARCHIVE_API_BASE_URL (the
    // in-network name above, which a receiver outside the stack cannot open).
    // Needs the ps-server named by the dmss-internal-urls capability in
    // release/capabilities.json; an older one ignores it.
    ARCHIVE_PUBLIC_BASE_URL: "https://padsign.trustlynx.com/archive/api/",
    TEMP_DIRECTORY: "./tmp/",
    DOCUMENT_OUTPUT_DIRECTORY: "/PSDOCS/out/",
    READONLY_PDF_DIRECTORY: "/PSDOCS/in/",
    ENABLE_PERSONAL_CODE_VALIDATION: false,
    ALLOWED_ORIGINS: [
      'https://padsign.trustlynx.com:5173',
      'https://padsign.trustlynx.com'
    ],
    DEFAULT_DOCUMENT_JSON: {
      "objectName": "template",
      "contentType": "application/pdf",
      "documentType": "DMSSDoc",
      "documentFilename": "template.pdf"
    },
    KEYCLOAK_CONFIG: {
      realm: "padsign",
      "auth-server-url": "https://padsign.trustlynx.com/auth",
      // Switch to confidential backend client
      resource: "padsign-backend",
      "credentials": {
        "secret": "CHANGE_ME"
      },
      "bearer-only": true
    },
    DEMO_MAX_FILE_SIZE_MB: 10,
    // Used by demo/internal flows; set to your company role name in Keycloak (or disable demo mode in constants.json).
    DEMO_COMPANY_ROLE: "CHANGE_ME",
    REGISTER_PDF_API_KEY: "tlx_pdf_8f7e2a1b9c4d6e3f5a8b2c7d9e1f4a6b8c3d5e7f9a2b4c6d8e0f1a3b5c7d9e2f4",
    ALLOW_INSECURE_TLS: false,
    SESSION_SECRET: "change-this-session-secret",
    USER_ENTRY_TTL_MS: 600000,
    USER_STATE_CLEANUP_MS: 60000,
    // Pad arrival timeout (hard wall, ms): a user/document record is evicted
    // this long after arrival on the pad, regardless of activity. Clears the
    // tablet view via the next /api/latestUser poll. 600000 = 10 min.
    PAD_ARRIVAL_TIMEOUT_MS: 600000,
    DOC_OPERATION_LOCK_TTL_MS: 45000,
    IDEMPOTENCY_TTL_MS: 600000,
    REGISTER_PDF_UPSTREAM_TIMEOUT_MS: 15000,
    REGISTER_PDF_UPSTREAM_RETRIES: 3,
    REGISTER_PDF_MAX_CONCURRENCY: 4,
    REGISTER_PDF_QUEUE_MAX_SIZE: 100,
    REGISTER_PDF_QUEUE_WAIT_MS: 30000,
    DEPENDENCY_CB_FAILURE_THRESHOLD: 5,
    DEPENDENCY_CB_COOLDOWN_MS: 30000,
    PRIVILEGED_API_ROLES: ["padsign-admin", "psapp-integration"],

    // ── Document Routing (post-signing actions) ──
    // Enable and configure strategies to control what happens after signing.
    DOCUMENT_ROUTING: {
      enabled: true,
      skipDemo: true,
      strategies: [
        {
          type: "filesystem",
          enabled: true,
          basePath: "/signed-output",
          pathTemplate: "{company}/{email}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf",
          createDirectories: true
        },
        {
          type: "webhook",
          enabled: false,
          url: "https://example.com/api/signing-status",
          method: "POST",
          headers: {},
          includeFile: false,
          timeoutMs: 10000,
          retries: 3,
          retryBaseDelayMs: 1000
        },
        {
          // Per-company webhook (direct-API integration). Runs only when the
          // signing company matches `company`. Bearer token per endpoint.
          // Permanent failure after retries is logged (no email/alert).
          type: "webhook",
          enabled: false,
          company: "Acme-DirectAPI",
          url: "https://customer.example.com/padsign/signed",
          method: "POST",
          includeFile: true,
          headers: { "Authorization": "Bearer REPLACE_WITH_CUSTOMER_TOKEN" },
          timeoutMs: 10000,
          retries: 5,
          retryBaseDelayMs: 1000
        }
      ]
    },

    // ── Customer Data lookup (virtual-printer flow) ──
    // Called when /api/registerPDF receives source=virtual-printer.
    // Extracts CustomerId from the PDF barcode and looks up the customer name
    // so the visual signature shows "Signed by: <resolved name>".
    // Leave CUSTOMER_DATA_API_KEY empty to disable.
    CUSTOMER_DATA_API_URL: "",
    CUSTOMER_DATA_API_KEY: "",
    CUSTOMER_DATA_API_KEY_HEADER: "api_key",
    CUSTOMER_DATA_CACHE_TTL_MS: 3600000,
    CUSTOMER_DATA_TIMEOUT_MS: 10000,
    CUSTOMER_DATA_RETRIES: 2,

    // ── Signing audit log ──
    // One JSON line per signing event (registered, signed, sealed, failed),
    // appended to <dir>/audit-YYYY-MM.jsonl by ps-server 3.34 and newer.
    // Read by the Deployment Wizard's Monitoring > Signing activity page.
    // Holds signer e-mail addresses: see
    // documentation/09-13-signing-activity-log.md for retention.
    AUDIT_LOG: {
      enabled: true,
      dir: "/signed-output/.padsign-audit",
      retentionMonths: 12
    },
};
