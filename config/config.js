  module.exports = {
    VISUAL_SIGNATURE_API_TEMPLATE: "https://padsign.trustlynx.com/container/api/signing/visual/pdf/{docid}/sign",
    STAMP_API_TEMPLATE: "https://padsign.trustlynx.com/container/api/stamping/pdf/stamp/{docid}/as/{company}",
    PORT: 3001,
    CONTAINER_API_BASE_URL: "https://padsign.trustlynx.com/container/api/",
    ARCHIVE_API_BASE_URL: "https://padsign.trustlynx.com/archive/api/",
    CREATE_DOCUMENT_API_URL: "https://padsign.trustlynx.com/archive/api/document/create",
    FORM_FILL_API_URL: "https://padsign.trustlynx.com/container/api/forms/fill/template/application",
    TEMPLATE_DIRECTORY: "/Repos/psapp/client/public/template",
    DOCUMENT_DOWNLOAD_API_URL: "https://padsign.trustlynx.com/archive/api/document/",
    DEFAULT_TEMPLATE_FILENAME: "template.pdf",
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
    REGISTER_PDF_API_KEY: "tlx_pdf_8f7e2a1b9c4d6e3f5a8b2c7d9e1f4a6b8c3d5e7f9a2b4c6d8e0f1a3b5c7d9e2f4",
};
