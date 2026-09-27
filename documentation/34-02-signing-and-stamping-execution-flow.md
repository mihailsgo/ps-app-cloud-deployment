# 34.2 Signing and stamping execution flow

The document is already registered (by `/api/registerPDF`, `/api/registerUser` or a demo upload), so ps-server holds its user entry in memory. The e-seal goes to the external service or, with `STAMP_MODE: "local"`, to container-signature's `/api/eseal`, which signs with the key held by `dmss-digital-stamping-service`. Routing runs only when `DOCUMENT_ROUTING` is enabled ([18.4](18-04-server-configconfigjs.md)).

```mermaid
sequenceDiagram
  autonumber
  actor User as User Browser
  participant SPA as PS Client SPA
  participant API as PS Server
  participant KC as Keycloak
  participant ARC as DMSS Archive
  participant SIG as DMSS Container Signature
  participant ESEAL as E-sealer

  User->>SPA: Login and open portal
  SPA->>KC: OIDC authentication
  loop every USER_POLLING_FREQUENCY
    SPA->>API: GET /latestUser with bearer token
    API->>KC: Introspect access token
    API-->>SPA: Active document from in-memory state (docid, lng, signer)
  end
  SPA->>ARC: GET /archive/api/document/{docid}/download with bearer token
  ARC-->>SPA: PDF shown in the viewer

  SPA->>API: PUT /visual-signature with docid payload
  API->>SIG: Forward visual-signature request
  SIG->>ARC: Store signed version
  SIG-->>API: Signature response
  API-->>SPA: Signature complete

  alt Stamping enabled (RUN_STAMPING_REQUEST=true)
    SPA->>API: POST /stamp with docid
    API->>ARC: Download latest signed PDF
    ARC-->>API: PDF bytes
    alt STAMP_MODE external
      API->>ESEAL: POST PDF to STAMP_API_URL with API headers
    else STAMP_MODE local
      API->>SIG: POST PDF to /api/eseal/document/profile/X with Basic auth
      SIG->>ESEAL: dmss-digital-stamping-service signs with the seal key
    end
    alt Sealed
      ESEAL-->>API: Sealed PDF bytes
      API->>ARC: Upload stamped PDF as new version
      opt DOCUMENT_ROUTING enabled
        API--)API: routeDocument: filesystem save and/or webhook (fire-and-forget)
      end
      API-->>SPA: Stamp complete
    else Upstream answered 5xx
      API-->>SPA: 200 stampStatus skipped (nothing routed)
      SPA->>API: POST /notify-signing-error
    end
  else Stamping disabled (RUN_STAMPING_REQUEST=false)
    SPA->>API: POST /finalize-signing with docid
    API->>ARC: Download signed PDF
    ARC-->>API: PDF bytes
    opt DOCUMENT_ROUTING enabled
      API--)API: routeDocument (fire-and-forget)
    end
    API-->>SPA: Routing triggered
  end

  opt Signing error at any step
    SPA->>API: POST /notify-signing-error with docid and error
    opt webhook strategy enabled
      API--)API: POST document.signing_error event (with retries)
    end
  end
```

When a filesystem strategy is enabled, the routed PDF also enters the receive-back buffer, which the Padsign Manager polls and acknowledges. That flow is in [35](35-receive-back-deployment-runbook.md).
