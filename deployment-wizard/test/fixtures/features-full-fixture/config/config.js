module.exports = {
  KEYCLOAK_CONFIG: { "auth-server-url": "https://padsign.example.com/auth" },
  DEMO_COMPANY_ROLE: "Acme Corp",
  STAMP_API_URL: "https://cloud-eseal.example.com/api",
  STAMP_MODE: "local",
  STAMP_LOCAL: {
    url: "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
    username: "user",
    password: "changeit",
    timeoutMs: 30000
  },
  DOCUMENT_ROUTING: {
    enabled: true,
    skipDemo: true,
    strategies: [
      { type: "filesystem", enabled: true, basePath: "/signed-output" },
      { type: "webhook", enabled: false, url: "https://example.com/api/signing-status" }
    ]
  },
};
