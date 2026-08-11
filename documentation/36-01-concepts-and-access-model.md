# 36.1 Concepts and access model

## No wizard-side database

The wizard has no database. On every page load it derives "what state is
this deployment in" by reading the same signals a human would check by
hand: whether `config/config.js.bak` / `nginx/nginx.conf.bak` exist (created
the first time `bootstrap.sh`/`upgrade.sh` ever touch this checkout), and
live `docker compose ps` output. That decides whether you land on the
onboarding flow (fresh install) or the dashboard (already deployed).

In-progress form answers during onboarding (hostname, company name, feature
toggles, etc.) live only in your browser session — a wizard-container
restart mid-flow loses that in-progress state, but never anything already
written to disk.

## Two different TLS certificates, on purpose

The wizard needs HTTPS for its own admin UI *before* you've uploaded the
real PadSign certificate — a chicken-and-egg problem. It solves this by
generating its own throwaway self-signed certificate on every container
start, used only for the wizard's own port. Your browser will show a
"connection isn't private" warning the first time you open it — that's
expected, the same as logging into a router admin page or a tool like
Portainer. It is completely separate from the real hostname certificate you
upload during the flow, which nginx serves to actual PadSign visitors.

## Access token, not a password

On every container start, the wizard generates a random access token and
prints it to the container's own logs:

```bash
docker logs padsign-wizard
```

Copy that token into the browser's unlock screen — it's masked as you paste
it, with a **Show token** toggle if you want to confirm the paste before
submitting. There is no user/password database — anyone who can read the container's logs and reach its port can
unlock it, which is the intended access model (see
[36.5 Security considerations](36-05-security-considerations.md) for why
that's an acceptable boundary, and what to do about it).

## Keyboard and screen-reader use

The wizard is operable without a mouse. Every control is reachable by `Tab`
and carries a visible focus ring. Specifically:

- The step rail is a list of links — `Tab` to a step you've already
  completed and press `Enter` to jump back to it.
- Confirmation dialogs trap focus while open, close on `Esc` or a click
  outside, and return focus to the control that opened them.
- Live progress during a deploy, upgrade or settings change is announced to
  screen readers as each step starts and finishes, as is the final
  success/failure outcome.
- Buttons that are gated on a prior action — **Next** before a certificate
  validates, **Continue to Verify** before a deploy finishes — are inert to
  keyboard as well as mouse, and state in plain text what unlocks them.
- A "Skip to main content" link precedes the top bar.

## One wizard per deployment

The wizard is not a shared, multi-tenant control plane. It has no existence
outside the exact repo checkout it's mounted into — one running wizard
container maps to exactly one PadSign deployment, the same way one repo
checkout already maps to one client deployment today.
