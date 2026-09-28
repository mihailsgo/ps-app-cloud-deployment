# 14.2 Deployment and integration architecture

One diagram of every PadSign component, the systems it talks to, and the data it keeps. Use it when
you plan firewall rules, integrations or backups. For a walk-through of the components see
[1.1 Architecture](01-01-architecture.md); for the signing sequence see
[1.2 How signing works](01-02-how-signing-works.md).

Solid lines are always present. Dashed lines are optional:

- local e-sealing (`STAMP_MODE: "local"`, compose profile `local-eseal`, [10](10-local-e-sealing.md)).
  The external and the local e-sealer are alternatives; `STAMP_MODE` selects exactly one;
- document routing and receive-back (`DOCUMENT_ROUTING`, [11](11-document-routing-and-receive-back.md));
- the customer-data lookup for Virtual Printer uploads (`CUSTOMER_DATA_*`, [7.4](07-04-server-config-js.md));
- the Deployment Wizard (compose profile `wizard`, [3](03-install-with-the-wizard.md)), reached only by
  the operator through an SSH tunnel.

Inside the Docker network, nginx reaches every service by its service name and container port.
Only nginx (80, 443) is meant to be reachable from users' networks; see
[2.3 Network and firewall](02-03-network-and-firewall.md) for every published port.

```mermaid
flowchart LR
  classDef user fill:#f5f7fb,stroke:#1f2937,stroke-width:1px,color:#111827;
  classDef edge fill:#eef6ff,stroke:#1d4ed8,stroke-width:1px,color:#0f172a;
  classDef core fill:#ecfeff,stroke:#0f766e,stroke-width:1px,color:#0f172a;
  classDef dmss fill:#fff7ed,stroke:#c2410c,stroke-width:1px,color:#431407;
  classDef security fill:#f0fdf4,stroke:#166534,stroke-width:1px,color:#052e16;
  classDef external fill:#fef2f2,stroke:#b91c1c,stroke-width:1px,color:#450a0a;
  classDef storage fill:#f8fafc,stroke:#475569,stroke-width:1px,color:#0f172a;

  U1[Business user<br/>browser or tablet]:::user
  U2[Third-party integrator<br/>API client]:::user
  U3[PadSign Virtual Printer and Manager<br/>Windows desktop]:::user
  OP[Operator<br/>SSH tunnel]:::user

  subgraph CUST[Your infrastructure]
    direction LR

    subgraph EDGE[Edge]
      NGINX[nginx<br/>TLS termination and reverse proxy<br/>ports 80 and 443]:::edge
    end

    subgraph APP[Application]
      PSC[ps-client<br/>React app and PDF viewer<br/>/portal]:::core
      PSS[ps-server<br/>Node.js API, port 3001<br/>/api]:::core
      KC[Keycloak<br/>OIDC identity provider, port 8080<br/>/auth]:::security
    end

    subgraph DMSS[Documents and signatures]
      DCS[dmss-container-and-signature-services<br/>port 8092<br/>/container/api]:::dmss
      DAS[dmss-archive-services<br/>port 8090<br/>/archive/api]:::dmss
      DAF[dmss-archive-services-fallback<br/>filesystem archive, port 8095]:::dmss
      DSS[dmss-digital-stamping-service<br/>seal keystore, port 8084<br/>profile local-eseal]:::dmss
    end

    WIZ[Deployment Wizard<br/>port 8443<br/>profile wizard]:::core

    subgraph DATA[Data on the host]
      DOCS[(docs/<br/>fallback document store)]:::storage
      KCV[(keycloak_data volume)]:::storage
      MEM[(ps-server in-memory session state)]:::storage
      OUT[(signed-output/<br/>routing archive and<br/>receive-back buffer)]:::storage
    end
  end

  subgraph EXT[External services]
    TLSEAL[External e-sealing service<br/>STAMP_API_URL]:::external
    TRUST[Trust services used by DMSS<br/>TSA, OCSP, Smart-ID, Mobile-ID]:::external
    WEBHOOK[Webhook endpoint<br/>DOCUMENT_ROUTING webhook strategy]:::external
    CDATA[Customer-data API<br/>CUSTOMER_DATA_API_URL]:::external
  end

  U1 -->|HTTPS /portal, /auth, /api| NGINX
  U2 -->|API key: registerPDF, registerUser| NGINX
  U3 -.->|API key: registerPDF source=virtual-printer<br/>then poll signedPdf pending, download, ack| NGINX
  OP -.->|HTTPS via SSH tunnel| WIZ

  NGINX -->|/portal| PSC
  NGINX -->|/api| PSS
  NGINX -->|/auth| KC
  NGINX -->|/container/api| DCS
  NGINX -->|/archive/api| DAS

  PSC -->|Bearer-token API calls| PSS
  PSC -->|OIDC login| KC
  PSC -->|Bearer-token PDF download<br/>via /archive/api| DAS

  PSS -->|Token introspection| KC
  PSS -->|Create, download, upload document versions| DAS
  PSS -->|Visual signature request| DCS
  PSS -->|STAMP_MODE external:<br/>POST PDF with API headers| TLSEAL
  PSS -.->|STAMP_MODE local:<br/>POST PDF to /api/eseal with basic auth| DCS
  PSS -.->|Signed-document event when routing is enabled| WEBHOOK
  PSS -.->|Look up signer name by customerId| CDATA
  PSS -.->|Filesystem routing strategy| OUT

  DAS -->|Fallback when the archive fails| DAF
  DAF --> DOCS
  KC --> KCV
  PSS --> MEM

  DCS -->|Archive read and write| DAS
  DCS -.->|Local e-seal signature| DSS
  DCS -->|Timestamp, OCSP and trust checks| TRUST
```

The wizard is drawn without connections inside the stack: it runs the installation scripts and
`docker compose` through the host's Docker socket, so it can change every component
([3.3 How the wizard works](03-03-how-the-wizard-works.md)).
