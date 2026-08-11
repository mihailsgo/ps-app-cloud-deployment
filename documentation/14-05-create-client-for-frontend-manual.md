# 14.5 Create Client for Frontend (Manual)

1. In the `padsign` realm, go to "Clients" ? "Create"
2. Configure the client:
   - **Client ID**: `padsign-client`
   - **Client Protocol**: `openid-connect`
   - **Root URL**: `https://<host>/portal/`
   - create user, as user role setup the company name.

<img width="2252" height="774" alt="image" src="https://github.com/user-attachments/assets/adc1cea1-ba42-415e-bd13-73697c35ff0b" />


4. Go to "Settings" tab and configure:
   - **Access Type**: `public`
   - **Valid Redirect URIs**: 
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - **Valid Post Logout Redirect URIs**:
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - **Web Origins**:
     - `https://<host>/portal/`
     - `https://<host>/portal`
     - `https://<host>`

5. Save the configuration

