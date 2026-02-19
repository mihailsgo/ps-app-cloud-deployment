  module.exports = {
    VISUAL_SIGNATURE_API_TEMPLATE: "https://padsign.trustlynx.com/container/api/signing/visual/pdf/{docid}/sign",
    STAMP_API_URL: "https://eseal.trustlynx.com/api/gateway/esealing/sign/api-key/DEMOCOMPANY",
    STAMP_API_KEY: "HT8mLAEMOBgKcyFbFg8gfS4hX2IeKBYRHQ==",
    STAMP_COMPANY_ID: "78861438-0ed3-427a-884f-218902083540",
    STAMP_COMPANY_SECRET: "Xsw9ayZ^%3",
    API_PROTECT_LOGS_ENABLED: false,
    PORT: 3001,
    ARCHIVE_API_BASE_URL: "https://padsign.trustlynx.com/archive/api/",
    CREATE_DOCUMENT_API_URL: "https://padsign.trustlynx.com/archive/api/document/create",
    FORM_FILL_API_URL: "https://padsign.trustlynx.com/container/api/forms/fill/template/application",
    DOCUMENT_DOWNLOAD_API_URL: "https://padsign.trustlynx.com/archive/api/document/",
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
        "secret": "ZhFzSQ9mFvNsm15sZNC6ugStSLFUwb7e"
      },
      "bearer-only": true
    },
    DEMO_MAX_FILE_SIZE_MB: 10,
    // Used by demo/internal flows; set to your company role name in Keycloak (or disable demo mode in constants.json).
    DEMO_COMPANY_ROLE: "CHANGE_ME",
    REGISTER_PDF_API_KEY: "tlx_pdf_8f7e2a1b9c4d6e3f5a8b2c7d9e1f4a6b8c3d5e7f9a2b4c6d8e0f1a3b5c7d9e2f4",
    ALLOW_INSECURE_TLS: false,
    SESSION_SECRET: "change-this-session-secret",
    USER_ENTRY_TTL_MS: 7200000,
    USER_STATE_CLEANUP_MS: 60000,
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
};
