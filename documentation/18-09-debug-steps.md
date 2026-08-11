# 18.9 Debug Steps

1. **Check Keycloak Logs**:
   ```bash
   docker-compose logs keycloak
   ```

2. **Check Application Logs**:
   ```bash
   docker-compose logs ps-server
   docker-compose logs nginx
   ```

3. **Verify Network Connectivity**:
   ```bash
   docker-compose exec keycloak ping ps-server
   ```

4. **Test Keycloak Endpoints**:
   ```bash
   curl https://padsign.trustlynx.com/auth/realms/padsign/.well-known/openid_configuration
   ```

