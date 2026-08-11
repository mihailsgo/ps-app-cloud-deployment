$ErrorActionPreference = "Stop"

param(
  [string]$Realm = "padsign",
  [string]$PublicHost = $env:KC_HOSTNAME,
  [string]$CompanyRole
)

function Require($name, $value) {
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required value: $name"
  }
}

Require "PublicHost (param -PublicHost or env KC_HOSTNAME)" $PublicHost
Require "CompanyRole (param -CompanyRole)" $CompanyRole

$portalBase = "https://$PublicHost/portal"
$keycloakExternalBase = "https://$PublicHost/auth"
$postLogoutUris = "$portalBase/*##$portalBase/##$portalBase"

Write-Host "Bootstrapping Keycloak realm '$Realm' for host '$PublicHost'..."

# Ensure keycloak is up so exec works.
docker compose up -d keycloak | Out-Null

# Wait for readiness (Keycloak is proxied under /auth but inside the container it's also mounted there).
$readyUrl = "http://localhost:8080/auth/health/ready"
for ($i = 0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri $readyUrl
    if ($r.StatusCode -eq 200) { break }
  } catch { }
  Start-Sleep -Seconds 1
  if ($i -eq 59) { throw "Keycloak did not become ready at $readyUrl within 60s" }
}

# Login to Keycloak from inside the container; server must be reachable as localhost from inside the container.
docker compose exec -T keycloak sh -lc (`
  "/opt/keycloak/bin/kcadm.sh config credentials " +
  "--server http://localhost:8080/auth --realm master " +
  "--user `"${KEYCLOAK_ADMIN:-admin}`" --password `"${KEYCLOAK_ADMIN_PASSWORD:-admin}`"") | Out-Null

# Create realm if missing.
docker compose exec -T keycloak sh -lc (`
  "/opt/keycloak/bin/kcadm.sh get realms/$Realm >/dev/null 2>&1 || " +
  "/opt/keycloak/bin/kcadm.sh create realms -s realm=$Realm -s enabled=true") | Out-Null

function Ensure-RealmRole([string]$roleName) {
  docker compose exec -T keycloak sh -lc (`
    "/opt/keycloak/bin/kcadm.sh get roles/$roleName -r $Realm >/dev/null 2>&1 || " +
    "/opt/keycloak/bin/kcadm.sh create roles -r $Realm -s name=$roleName") | Out-Null
}

Ensure-RealmRole "padsign-admin"
Ensure-RealmRole "psapp-integration"
Ensure-RealmRole $CompanyRole

# Recreate 'test' user to ensure it has ONLY the company role.
$testPass = $CompanyRole.ToLowerInvariant()
$testUserInternal = @"
UID=\$(/opt/keycloak/bin/kcadm.sh get users -r $Realm -q username=test --fields id --format csv | tail -n 1)
if [ -n "\$UID" ] && [ "\$UID" != "id" ]; then
  /opt/keycloak/bin/kcadm.sh delete users/\$UID -r $Realm >/dev/null
fi
/opt/keycloak/bin/kcadm.sh create users -r $Realm -s username=test -s enabled=true >/dev/null
UID=\$(/opt/keycloak/bin/kcadm.sh get users -r $Realm -q username=test --fields id --format csv | tail -n 1)
/opt/keycloak/bin/kcadm.sh set-password -r $Realm --userid \$UID --new-password '$testPass' --temporary=false >/dev/null
/opt/keycloak/bin/kcadm.sh add-roles -r $Realm --uusername test --rolename '$CompanyRole' >/dev/null
"@

docker compose exec -T keycloak sh -lc $testUserInternal | Out-Null

# Create or update frontend client.
$clientIdFrontend = "padsign-client"
$redirectUris = "[\"$portalBase/*\",\"$portalBase/\",\"$portalBase\"]"
$webOrigins = "[\"$portalBase/\",\"$portalBase\"]"

$frontendClientInternal = @"
/opt/keycloak/bin/kcadm.sh get clients -r $Realm -q clientId=$clientIdFrontend --fields id,clientId | grep -q '\"id\"' || \
/opt/keycloak/bin/kcadm.sh create clients -r $Realm \
  -s clientId=$clientIdFrontend \
  -s enabled=true \
  -s publicClient=true \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s implicitFlowEnabled=false \
  -s 'redirectUris=$redirectUris' \
  -s 'webOrigins=$webOrigins' \
  -s rootUrl=$portalBase/ \
  -s baseUrl=$portalBase/ \
  -s adminUrl=$portalBase/ \
  -s "attributes.\"post.logout.redirect.uris\"=$postLogoutUris" >/dev/null

CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r $Realm -q clientId=$clientIdFrontend --fields id --format csv | tail -n 1)
/opt/keycloak/bin/kcadm.sh update clients/\$CID -r $Realm \
  -s 'redirectUris=$redirectUris' \
  -s 'webOrigins=$webOrigins' \
  -s rootUrl=$portalBase/ \
  -s baseUrl=$portalBase/ \
  -s adminUrl=$portalBase/ \
  -s "attributes.\"post.logout.redirect.uris\"=$postLogoutUris" >/dev/null
"@

docker compose exec -T keycloak sh -lc $frontendClientInternal | Out-Null

# Create backend client (bearer-only resource server) if missing, and print its secret.
$clientIdBackend = "padsign-backend"
$backendClientInternal = @"
/opt/keycloak/bin/kcadm.sh get clients -r $Realm -q clientId=$clientIdBackend --fields id,clientId | grep -q '\"id\"' || \
/opt/keycloak/bin/kcadm.sh create clients -r $Realm \
  -s clientId=$clientIdBackend \
  -s enabled=true \
  -s publicClient=false \
  -s bearerOnly=false \
  -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false \
  -s implicitFlowEnabled=false \
  -s directAccessGrantsEnabled=false >/dev/null

CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r $Realm -q clientId=$clientIdBackend --fields id --format csv | tail -n 1)
/opt/keycloak/bin/kcadm.sh get clients/\$CID/client-secret -r $Realm --fields value --format csv | tail -n 1
"@

$backendSecret = (docker compose exec -T keycloak sh -lc $backendClientInternal).Trim()

Write-Host ""
Write-Host "Keycloak bootstrap complete."
Write-Host "- KEYCLOAK_URL: $keycloakExternalBase"
Write-Host "- KEYCLOAK_REALM: $Realm"
Write-Host "- KEYCLOAK_CLIENT_ID (frontend): $clientIdFrontend"
Write-Host "- Backend clientId: $clientIdBackend"
Write-Host "- Backend client secret: $backendSecret"
