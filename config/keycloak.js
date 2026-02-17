export default {
  url: `${window.location.origin}/auth`,
  realm: "padsign",
  clientId: "padsign-client",
  redirectUri: `${window.location.origin}/portal/`,
  postLogoutRedirectUri: `${window.location.origin}/portal/`
};
