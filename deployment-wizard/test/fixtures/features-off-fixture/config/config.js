module.exports = {
  DEMO_COMPANY_ROLE: "Acme Corp",
  STAMP_API_URL: "https://cloud-eseal.example.com/api",
  STAMP_MODE: "external",
  DOCUMENT_ROUTING: {
    enabled: false,
    skipDemo: true,
    strategies: [
      { type: "filesystem", enabled: true, basePath: "/signed-output" },
      { type: "webhook", enabled: false, url: "https://example.com/api/signing-status" }
    ]
  },
};
