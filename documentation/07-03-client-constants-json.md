# 7.3 Client: config/constants.json

`config/constants.json` is the runtime configuration of the portal (the
ps-client SPA). The browser fetches it on every page load. After a change,
run `docker compose restart ps-client` and reload the portal
([7.2](07-02-how-configuration-is-loaded.md#when-a-change-takes-effect)); the
restart makes sure ps-client serves the new file. Values
missing from the file fall back to the SPA's built-in defaults.

The file must stay valid JSON: no comments, no trailing commas.
`validate-config.sh` checks this. `configure-host.sh` rewrites these keys for
the deployment host and saves the whole file as indented JSON:
`KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`,
`PS_DOWNLOAD_API`, `PDF_TEST_PATH`. With `--enable-demo` / `--disable-demo` it
also rewrites `DEMO_MODE`.

Defaults below are the values in the shipped file. `<host>` is your
hostname, for example `padsign.example.com`.

## Branding and UI

| Key | Default | Meaning |
|-----|---------|---------|
| `PS_PAGE_TITLE` | `"TrustLynx"` | Window title and logo alt text. |
| `PS_LOGO_PATH` | `"/portal/logo.png"` | Header logo (`config/TLlogo.png` is mounted there). |
| `PS_DEFAULT_LOGO_PATH` | `"/portal/logo.png"` | Fallback if `PS_LOGO_PATH` does not load. |
| `PS_LOGO_WIDTH`, `PS_LOGO_HEIGHT` | `"30"`, `"50%"` | Logo size, any CSS length (`"30"`, `"120px"`, `"50%"`). Empty lets the stylesheet decide. |
| `PS_LOGO_WIDTH_IDLE`, `PS_LOGO_HEIGHT_IDLE`, `PS_LOGO_WIDTH_ACTIVE`, `PS_LOGO_HEIGHT_ACTIVE` | `""` | Per-screen overrides for the idle screen and the signing screen. Empty falls back to `PS_LOGO_WIDTH` / `PS_LOGO_HEIGHT`. |
| `PS_SIGNATURE_BUTTON_FONT_SIZE` | `""` | CSS font size for the signature pad's buttons. Empty keeps the default. |
| `SHOW_USER_DATA_BOX` | `false` | Show a small user-info box (with logout) for the signed-in user. |
| `SHOW_SIGNER_NAME` | `false` | Show the signer name resolved by the customer-data lookup above the signature canvas (for example `Signer: Anna Berzina`), so the signer can confirm their identity. Intended for the Virtual Printer flow, where a barcode on the printed document identifies the signer. See `CUSTOMER_DATA_*` in [7.4](07-04-server-config-js.md#customer-data-lookup-virtual-printer). |

## Authentication (Keycloak)

| Key | Default | Meaning |
|-----|---------|---------|
| `KEYCLOAK_URL` | `"https://<host>/auth"` | Keycloak base URL. |
| `KEYCLOAK_REALM` | `"padsign"` | Realm. |
| `KEYCLOAK_CLIENT_ID` | `"padsign-client"` | The public client the SPA logs in with. |
| `KEYCLOAK_REDIRECT_URI` | `"https://<host>/portal/"` | Where Keycloak returns after login. |
| `KEYCLOAK_POST_LOGOUT_REDIRECT_URI` | `"https://<host>/portal/"` | Where Keycloak returns after logout. |

The login itself is configured by `config/keycloak.js` (below). These keys
are used for logout and role lookup, and by the SPA's built-in fallback when
`keycloak.js` cannot be loaded. Keep both consistent.

## Backend endpoints and polling

| Key | Default | Meaning |
|-----|---------|---------|
| `PS_API_ACTUAL_USER` | `"/api/latestUser"` | Endpoint the SPA polls for the next document to sign. |
| `USER_POLLING_FREQUENCY` | `5000` | Polling interval in ms. |
| `PS_API_CLEANUP_USER` | `"/api/cleanupUser"` | Clears the pad after signing (Keycloak-protected). |
| `PS_API_FILL_PDF_DEMO` | `"/api/fillPDFDemo"` | Form-fill fallback: stores the filled PDF as a new version of the document. |
| `PS_API_DEMO_UPLOAD` | `"/api/demo/upload"` | Demo-mode upload. |
| `PS_API_DEMO_UPLOAD_VERSION` | `"/api/demo/upload/version"` | Demo-mode upload of a new version. |
| `PS_API_DEMO_FILL_BY_DOCID` | `"/api/demo/fill-by-docid"` | Demo-mode form fill. |
| `PS_API_SAVE_DOC_IN_STORAGE` | `"/api/save"` | Saves a PDF into ps-server's `DOCUMENT_OUTPUT_DIRECTORY`. Not used in the standard flow. |

## PDF viewer, download and signature placement

| Key | Default | Meaning |
|-----|---------|---------|
| `PS_DOWNLOAD_API` | `"https://<host>/archive/api/document/"` | Archive base the viewer opens documents from: `PS_DOWNLOAD_API + <docId> + "/download"`. |
| `PDF_TEST_PATH` | `"https://<host>/template"` | Base URL of static templates for interactive mode (`PDF_TEST_PATH + "_" + <lang> + ".pdf"`). Not used in the standard flow. |
| `PDF_RENDER_SYNCFUSION_SECRET_KEY` | licensed key | Syncfusion PDF viewer licence key. Keep the shipped value, or use your own licence. A key only licenses the Syncfusion versions it was issued for, so it must match the `ps-client` image: `8.40` and older run Syncfusion 27, `8.41` and later Syncfusion 34 (a 34.x key, valid for 8 major versions from 34). A mismatch does not break signing, but the viewer shows a licence banner over the document. The browser receives this value on every page load, so it is not a secret in the usual sense. Moving across that boundary: [9.5, New Syncfusion key](09-05-upgrading.md#new-syncfusion-key-for-ps-client-841). |
| `PDF_SIGNATURE_X`, `PDF_SIGNATURE_Y` | `-250`, `-100` | Position of the visual signature. |
| `PDF_SIGNATURE_ZOOM` | `100` | Scale of the signature image. |
| `PDF_SIGNATURE_PAGE` | `10000` | Page for the signature. `10000` means the last page. |
| `PDF_ZOOM_VALUE` | `"125"` | Initial viewer zoom. |
| `MAX_ZOOM`, `MIN_ZOOM` | `125`, `125` | Zoom limits. |
| `DEFAULT_PAGE_SIZE` | `"7800px"` | CSS height of the viewer container. |
| `EXTRA_HEIGHT_MARGIN_PX` | `2500` | Extra pixels added to the computed PDF height to avoid clipping. |
| `OPACITY_DELAY` | `4000` | Delay (ms) before the loading overlay is removed. |

## Signature pad and input helpers

| Key | Default | Meaning |
|-----|---------|---------|
| `CANVA_WIDTH`, `CANVA_HEIGHT` | `300`, `100` | Signature canvas size in px. |
| `DEFAULT_PHONE_PREFIX` | `"371"` | Default country prefix for phone fields. |

The SPA reads PDF form fields generically (text as string, checkbox as
boolean). It does not validate fields by name.

## Workflow

| Key | Default | Meaning |
|-----|---------|---------|
| `RUN_STAMPING_REQUEST` | `false` | When `true`, the portal calls ps-server's `/api/stamp` after the visual signature, and ps-server e-seals the document in the mode `STAMP_MODE` selects ([7.4](07-04-server-config-js.md#e-sealing-apistamp)). |
| `DEMO_MODE` | `"DISABLE"` | `"ENABLE"` turns on demo upload in the portal. Toggle it with `toggle-features.sh` ([9.4](09-04-toggling-features.md)). |
| `DEMO_MAX_FILE_SIZE_MB` | `10` | Largest PDF the demo upload accepts in the browser. Keep it equal to `DEMO_MAX_FILE_SIZE_MB` in `config.js`, which enforces the limit on the server. |
| `PDF_SIGNING_STATUS_CALLBACK`, `PDF_SIGNING_STATUS_CALLBACK_ENABLED` | `"https://example.com/api/signing-status"`, `false` | **Deprecated and ignored** by the current client. Use the server-side `DOCUMENT_ROUTING` webhook strategy instead ([11](11-document-routing-and-receive-back.md)). |

## Language and texts

| Key | Default | Meaning |
|-----|---------|---------|
| `DEFAULT_LANGUAGE` | `"LV"` | Default UI language and date format. |
| `TRANSLATIONS` | `LV` and `EN` | All UI strings per language. Edit these to change any text: button labels, the signing-workflow popup (`WF_*`), stage error messages (`ERROR_VISUAL_SIGNATURE`, `ERROR_STAMP_RESPONSE`) and the labels printed in the visual signature (`SIGNATURE_LABEL_SIGNER`, `SIGNATURE_LABEL_DATE`). |
| `LV_MONTHS_LIST`, `EN_MONTHS_LIST` | month names | Not used by the current client. Leave them as shipped. |

## config/keycloak.js

`config/keycloak.js` is mounted as `/portal/keycloak.js`. The SPA loads it at
startup and uses it to create its Keycloak client. If it cannot be loaded,
the SPA falls back to its built-in configuration built from the `KEYCLOAK_*`
keys above. The shipped file derives everything from the page's own
address, so it works on any hostname without edits:

```js
export default {
  url: `${window.location.origin}/auth`,
  realm: "padsign",
  clientId: "padsign-client",
  redirectUri: `${window.location.origin}/portal/`,
  postLogoutRedirectUri: `${window.location.origin}/portal/`
};
```

Keep it mounted. Change `realm` or `clientId` only if you changed them in
Keycloak, and change `KEYCLOAK_REALM` / `KEYCLOAK_CLIENT_ID` above to match.
