# 18.3 Client: config/constants.json

Branding and UI
- `PS_PAGE_TITLE`: Window title and logo alt text. Default: `"TrustLynx"`.
- `PS_LOGO_PATH`: Path to logo used in header. Default: `"/portal/logo.png"`.
- `PS_DEFAULT_LOGO_PATH`: Fallback logo if `PS_LOGO_PATH` missing. Default: `"/portal/logo.png"`.
- `SHOW_USER_DATA_BOX`: Toggle small user-info box for authenticated users. Default: `false`.
- `SHOW_SIGNER_NAME`: When `true`, the SPA renders the resolved signer name (returned by the CustomerData lookup, see server `CUSTOMER_DATA_*` config) above the signature canvas, e.g. `Signer: Stephen Graham`. Lets the user confirm identity before signing. Designed for the virtual-printer flow where the signer is identified by a barcode on the printed document. Default: `false`. Enable per-deployment by setting to `true` only for clients using this flow.

Authentication (Keycloak)
- `KEYCLOAK_URL`: Base URL to Keycloak auth server. Default: `"https://padsign.trustlynx.com/auth"`.
- `KEYCLOAK_REALM`: Realm name. Default: `"padsign"`.
- `KEYCLOAK_CLIENT_ID`: Public client ID used by the SPA. Default: `"padsign-client"`.
- `KEYCLOAK_REDIRECT_URI`: SPA redirect URI after login. Default: `"https://padsign.trustlynx.com/portal/"`.
- `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`: Redirect URI after logout. Default: `"https://padsign.trustlynx.com/portal/"`.

Data polling and backend endpoints
- `PS_API_ACTUAL_USER`: Path to latest user API (proxied by nginx to backend). Used by polling worker. Default: `"/api/latestUser"`.
- `USER_POLLING_FREQUENCY`: Polling interval in ms for `/latestUser`. Default: `5000`.
- `PS_API_SAVE_DOC_IN_STORAGE`: Path to backend endpoint that downloads a generated PDF into `DOCUMENT_OUTPUT_DIRECTORY`. Default: `"/api/save"`. API is not relevant for cloud instance.
- `PS_API_CLEANUP_USER`: Internal app cleanup endpoint. Default: `"/api/cleanupUser"` (Keycloak protected).
- `PS_API_DEMO_UPLOAD`: DEMO upload endpoint. Default: `"/api/demo/upload"`.
- `PS_API_DEMO_UPLOAD_VERSION`: DEMO upload new version endpoint. Default: `"/api/demo/upload/version"`.
- `PS_API_DEMO_FILL_BY_DOCID`: DEMO fill-by-doc endpoint. Default: `"/api/demo/fill-by-docid"`.

PDF rendering, download, and signature overlay
- `PS_DOWNLOAD_API`: Archive service base used by the viewer to open PDFs in readonly mode. Final URL: `PS_DOWNLOAD_API + <docId> + "/download"`. Default: `"https://padsign.trustlynx.com/archive/api/document/"`.
- `PDF_TEST_PATH`: Base URL to static templates for interactive mode. Viewer uses `PDF_TEST_PATH + "_" + <lng> + ".pdf"` (e.g., `/portal/template_LV.pdf`). Default: `"https://padsign.trustlynx.com/template"` (override to your SPA path if hosting templates with the client). API is not relevant for cloud instance.
- `PDF_RENDER_SYNCFUSION_SECRET_KEY`: Syncfusion viewer license key used at runtime. Default: present key in repo (replace with your own license key).
- `PDF_SIGNATURE_X`: X position for visual signature overlay (px units, service-specific). Default: `-250`.
- `PDF_SIGNATURE_Y`: Y position for visual signature overlay. Default: `-100`.
- `PDF_SIGNATURE_ZOOM`: Scale for signature image in overlay. Default: `100`.
- `PDF_SIGNATURE_PAGE`: Page index for the overlay (special value `10000` instructs service to place at last page). Default: `10000`.
- `PDF_ZOOM_VALUE`: Initial zoom level in viewer. Default: `"125"`.
- `MAX_ZOOM`: Max zoom allowed. Default: `125`.
- `MIN_ZOOM`: Min zoom allowed. Default: `125`.
- `DEFAULT_PAGE_SIZE`: CSS height for PDF viewer container. Default: `"7800px"`.
- `EXTRA_HEIGHT_MARGIN_PX`: Extra pixels added to computed PDF height to prevent clipping. Default: `2500`.
- `OPACITY_DELAY`: Delay (ms) before removing loading overlays after viewer load. Default: `4000`.

Signature pad and phone prefixing
- `CANVA_WIDTH`: Signature canvas width (px). Default: `300`.
- `CANVA_HEIGHT`: Signature canvas height (px). Default: `100`.
- `DEFAULT_PHONE_PREFIX`: Default country prefix used by UI helpers. Default: `"371"`.

Form fields
- The app extracts PDF form fields generically (text -> string, checkbox -> boolean) and does not run business validations or field-type coercion based on field names.
- `HIDDEN_FIELDS`: Fields to hide per language (currently not active in code; kept for future use).

Localization and text
- `DEFAULT_LANGUAGE`: Default language code for UI and date formatting. Default: `"LV"`.
- `LV_MONTHS_LIST` / `EN_MONTHS_LIST`: Month names used to build `getCurrentDate()` texts placed into PDF fields. Not relevant for cloud instance.
- `TRANSLATIONS`: String resources for UI and notifications in `LV` and `EN`. Update to localize texts.
- Signature visual labels in visual-sign payload:
- `SIGNATURE_LABEL_SIGNER`, `SIGNATURE_LABEL_DATE`: Localized labels used in `pdfSignatureVisuals.signatureText` (for example, `Signer/Date` vs `Parakstitajs/Datums`).
- Signing workflow popup labels/statuses:
- `WF_TITLE_IN_PROGRESS`, `WF_SUBTITLE_IN_PROGRESS`, `WF_STEP_PREPARE`, `WF_STEP_VISUAL_SIGNATURE`, `WF_STEP_STAMP`, `WF_STEP_FINALIZE`, `WF_SUBTITLE_SUCCESS`, `WF_TITLE_FAILED`, `WF_SUBTITLE_FAILED`, `WF_CLOSE`, `WF_REFRESH_COUNTDOWN`.
- Stage-specific signing error texts:
- `ERROR_VISUAL_SIGNATURE`, `ERROR_STAMP_RESPONSE`.

Workflow toggles and callbacks
- `RUN_STAMPING_REQUEST`: When `true`, triggers a backend call to stamp the PDF after signing. Default: `false`.
- `DEMO_MODE`: Enables/disables DEMO behavior (`ENABLE`/`DISABLE`). Default: `"DISABLE"`.
- `PDF_SIGNING_STATUS_CALLBACK`: **Deprecated** - replaced by server-side `DOCUMENT_ROUTING` webhook strategy in `config.js`. Previously an external webhook URL for client-side notification. Default: `"https://example.com/api/signing-status"`.
- `PDF_SIGNING_STATUS_CALLBACK_ENABLED`: **Deprecated** - replaced by server-side `DOCUMENT_ROUTING` webhook strategy. Default: `false`.

---

