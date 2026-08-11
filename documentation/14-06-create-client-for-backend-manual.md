# 14.6 Create Client for Backend (Manual)

1. Create another client for the backend:
   - **Client ID**: `padsign-backend`
   - **Client Protocol**: `openid-connect`
   - **Access Type**: `confidential`
   - **Service accounts roles**:
     - Enable this only if you will call privileged internal APIs using the backend client service user.
     - If your deployment does not use service-user calls, this can stay disabled.

2. Go to "Credentials" tab and copy the client secret

3. Configure settings:
   - **Valid Redirect URIs**: `https://padsign.trustlynx.com/auth/realms/padsign/protocol/openid-connect/auth`

