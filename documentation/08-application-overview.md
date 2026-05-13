# 8. Application Overview

The PadSign application uses Keycloak for authentication and authorization. The setup includes:
- **Keycloak Server**: Containerized authentication server
- **Client Application**: React frontend with Keycloak integration
- **Server Application**: Node.js backend with Keycloak middleware

## 8.1 How this solution works

- Users open the PadSign portal in the browser and are redirected to Keycloak to log in securely.
- After login, the SPA pulls its runtime config and shows the latest PDF that was registered for that user and company.
- External systems register sessions/documents through API-key endpoints (`/api/registerUser`, `/api/registerUserPDF`, `/api/registerPDF`) and clear them using `/api/removeUser`.
- The SPA polls the backend for that user/company pair; when a PDF is found, it streams the document from the archive service for viewing and signing.
- All traffic flows through the NGINX reverse proxy over HTTPS, which routes to the SPA (`/portal`), Keycloak (`/auth`), backend (`/api`), and the DMSS services used for document storage and signing.

