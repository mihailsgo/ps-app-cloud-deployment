# 13.4 What software is used on the tablets?

No app needs to be installed. The tablet opens the PadSign portal in a
browser at `https://padsign.example.com/portal/`.

In the portal the user can:

- sign in through Keycloak;
- see the document (PDF) sent to them;
- place the visual signature;
- have the document sealed, when sealing is on (`RUN_STAMPING_REQUEST` in
  `config/constants.json`, [7.3 Client constants.json](07-03-client-constants-json.md)).

What happens after signing (saving the PDF, notifying another system,
returning it to the Padsign Manager on the desk) is done by the server, not
the tablet: see [11. Document routing and receive-back](11-document-routing-and-receive-back.md).

The Padsign Manager (Virtual Printer) is a separate Windows application
for the desktops that send documents; it is not installed on tablets.
