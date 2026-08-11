#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Upgrade — update image tags and apply latest config patterns
#
# Usage (current release tags — see documentation/01-release-snapshot.md):
#   ./installation-scripts/upgrade.sh --server-tag 3.27 --client-tag 8.37
#   ./installation-scripts/upgrade.sh --server-tag 3.27   # server only
#   ./installation-scripts/upgrade.sh --client-tag 8.37   # client only
# ============================================================================

server_tag=""
client_tag=""
enable_local_eseal=false
plan_only=false
plan_format="text"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/upgrade.sh [--server-tag X.XX] [--client-tag X.XX] [--enable-local-eseal]
  ./installation-scripts/upgrade.sh [same args] --plan-only [--plan-format text|machine]

Previewing before you commit:
  --plan-only    Evaluate every configuration migration and print exactly what
                 would change, then exit 0. Writes nothing, starts nothing,
                 touches no container. Safe to run on a live deployment.
  --plan-format  'text' (default) is a readable summary; 'machine' emits a
                 delimiter-framed record per migration, which is what the
                 deployment wizard's preview screen consumes.

  The plan is generated from the same guards the real run uses, so it cannot
  disagree with what an unflagged run would do. Configuration migrations are
  additive: each one only fires when its target is absent, so a migration
  reported as 'already applied' will not touch your customised values.

What it does:
  1) Backs up docker-compose.yml and config.js
  2) Updates image tags in docker-compose.yml
  3) Ensures DOCUMENT_ROUTING config exists (disabled by default)
  4) Ensures signed-output volume mount and directory exist
  4b) (--enable-local-eseal only) Materializes the dmss-digital-stamping-service
      assets, appends the gated compose service block, patches the
      container-signature baseUrl, flips STAMP_MODE in config.js to "local",
      and sets COMPOSE_PROFILES=local-eseal in .env so subsequent
      `docker compose up -d` calls automatically include the new service.
  5) Pulls new images and recreates changed containers
  6) Verifies services are running

The --enable-local-eseal flag is idempotent: re-running is safe and only
touches files that haven't already been migrated. To revert, edit
config/config.js (STAMP_MODE: "external"), clear COMPOSE_PROFILES in .env,
and `docker compose up -d ps-server`. See documentation/04-enabling-local-e-sealing.md
for full recipe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-tag) server_tag="${2:-}"; shift 2;;
    --client-tag) client_tag="${2:-}"; shift 2;;
    --enable-local-eseal) enable_local_eseal=true; shift;;
    --plan-only) plan_only=true; shift;;
    --plan-format) plan_format="${2:-}"; shift 2;;
    --plan-format=*) plan_format="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

case "$plan_format" in
  text|machine) ;;
  *) echo "ERROR: --plan-format must be 'text' or 'machine' (got '${plan_format}')" >&2; exit 2;;
esac

if [[ -z "$server_tag" && -z "$client_tag" && "$enable_local_eseal" != true ]]; then
  echo "ERROR: Provide at least one of --server-tag, --client-tag, or --enable-local-eseal" >&2
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_yml="${repo_root}/docker-compose.yml"
config_js="${repo_root}/config/config.js"
# Hoisted out of the local-eseal block so the migration predicates below can
# read them without executing anything.
assets_src="${scripts_dir}/assets/dmss-digital-stamping-service"
stamping_dst="${repo_root}/dmss-digital-stamping-service"
csig_yml="${repo_root}/dmss-container-and-signature-services/application.yml"
env_file="${repo_root}/.env"
# NB: upgrade.sh deliberately never touches nginx/nginx.conf — a hostname
# change is configure-host.sh's job, not an upgrade's.

# Single portable tag reader, used by both the pre-flight gate and the
# "old → new" display lines. sed -E works in all locales; grep -oP (which the
# display lines used to use) can fail under non-UTF-8 locales where PCRE is
# unavailable, which meant the label could read "unknown" while the sed that
# actually rewrites the tag succeeded — the two disagreeing in a UI whose job
# is informed consent. Prints the tag, or nothing if the image line is absent.
current_tag() {
  sed -nE "s|.*mihailsgordijenko/$1:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p" "$compose_yml" 2>/dev/null | head -1
}

# ── Pre-flight: local-eseal needs a ps-server image that contains the STAMP_MODE
#    dispatch. The first image with that code is :3.26. If --enable-local-eseal is
#    set but the effective ps-server tag (either --server-tag or the existing pin
#    in docker-compose.yml) is older, refuse to run rather than producing a silent
#    no-op (where STAMP_MODE=local lands in config.js but ps-server ignores it).
LOCAL_ESEAL_MIN_SERVER_TAG="3.26"
if [[ "$enable_local_eseal" == true ]]; then
  current_server="$(current_tag ps-server)"
  effective_server="${server_tag:-$current_server}"
  if [[ -z "$effective_server" ]]; then
    echo "ERROR: Cannot determine the ps-server image tag from docker-compose.yml." >&2
    echo "       Pass --server-tag ${LOCAL_ESEAL_MIN_SERVER_TAG} (or newer) explicitly." >&2
    exit 2
  fi
  # Strict less-than via sort -V
  smaller="$(printf '%s\n%s\n' "$effective_server" "$LOCAL_ESEAL_MIN_SERVER_TAG" | sort -V | head -1)"
  if [[ "$effective_server" != "$LOCAL_ESEAL_MIN_SERVER_TAG" && "$smaller" == "$effective_server" ]]; then
    echo "ERROR: --enable-local-eseal requires mihailsgordijenko/ps-server:${LOCAL_ESEAL_MIN_SERVER_TAG} or newer." >&2
    echo "       The current effective ps-server tag is :${effective_server}, which predates the" >&2
    echo "       STAMP_MODE dispatch. Without the dispatch, ps-server silently ignores the" >&2
    echo "       STAMP_MODE field and keeps calling the external e-sealing service - so" >&2
    echo "       this upgrade would land config + start the stamping container, but signing" >&2
    echo "       would still go to the cloud (a silent no-op)." >&2
    echo "" >&2
    echo "       Re-run with the tag bump in the same invocation, for example:" >&2
    echo "         ./installation-scripts/upgrade.sh --server-tag ${LOCAL_ESEAL_MIN_SERVER_TAG} --enable-local-eseal" >&2
    exit 2
  fi
fi

# ── Config-migration table ──────────────────────────────────────────────────
#
# Single source of truth for every configuration change an upgrade can make.
# Each migration has three parts:
#
#   mig_<id>_needed   predicate — exit 0 if this migration WOULD change something
#   mig_<id>_body     prints the exact text it would write (for --plan-only)
#   mig_<id>_apply    performs the change
#
# `_apply` re-uses the same `need_*` predicates `_needed` is built from, so the
# plan and the actual run cannot disagree — that is the whole point of the
# table. A new configuration migration belongs here as a new entry; never add
# a fresh straight-line edit further down.
#
# The reportable IDs are deliberately coarser than the individual edits:
# `local-eseal` is six edits across four files that form one semantic unit
# (compose service, baseUrl, Spring creds, STAMP_MODE, COMPOSE_PROFILES, demo
# assets). Splitting them is how you get a stack that boots and then 401s on
# every seal, so they are reported and applied as one.

MIGRATION_IDS=(document-routing signed-output local-eseal)

# ---- per-edit predicates (shared by _needed and _apply) ----
need_document_routing()  { ! grep -q 'DOCUMENT_ROUTING' "$config_js"; }
need_signed_output_vol() { ! grep -q 'signed-output:/signed-output' "$compose_yml"; }
need_signed_output_dir() { [[ ! -d "${repo_root}/signed-output" || ! -d "${repo_root}/docs" ]]; }
need_eseal_assets()      { [[ ! -f "$stamping_dst/application.yml" || ! -f "$stamping_dst/seal/seal.p12" || ! -f "$stamping_dst/seal/README.md" ]]; }
need_eseal_compose()     { ! grep -qE '^[[:space:]]+dmss-digital-stamping-service:[[:space:]]*$' "$compose_yml"; }
need_eseal_baseurl()     { grep -q '^  baseUrl: http://host.docker.internal:8084/api' "$csig_yml" 2>/dev/null; }
need_eseal_springsec()   { ! grep -q 'SPRING_SECURITY_USER_NAME' "$compose_yml"; }
need_eseal_stampmode()   { ! grep -q 'STAMP_MODE: *"local"' "$config_js"; }
need_eseal_profile()     { ! grep -q '^COMPOSE_PROFILES=.*local-eseal' "$env_file" 2>/dev/null; }

# ---- literal bodies ----
# Defined as heredocs rather than inline in the perl/sed so that the plan can
# print byte-for-byte what will be written, and so the substitution can pass
# them through the environment instead of escaping them twice.
DOCUMENT_ROUTING_BLOCK=$(cat <<'BLOCK'

    // Document Routing (post-signing actions) - disabled by default
    DOCUMENT_ROUTING: {
      enabled: false,
      skipDemo: true,
      strategies: [
        {
          type: "filesystem",
          enabled: false,
          basePath: "/signed-output",
          pathTemplate: "{company}/{date:YYYY-MM}/{company}_{clientName}_{date:YYYY-MM-DD_HHmm}.pdf",
          createDirectories: true
        },
        {
          type: "webhook",
          enabled: false,
          url: "https://example.com/api/signing-status",
          method: "POST",
          headers: {},
          includeFile: false,
          timeoutMs: 10000,
          retries: 3,
          retryBaseDelayMs: 1000
        }
      ]
    },
BLOCK
)

STAMP_LOCAL_BLOCK=$(cat <<'BLOCK'
STAMP_MODE: "local",
    STAMP_LOCAL: {
      url: "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
      username: "user",
      password: "changeit",
      timeoutMs: 30000
    },
BLOCK
)

STAMPING_COMPOSE_BLOCK=$(cat <<'BLOCK'
  dmss-digital-stamping-service:
    container_name: dmss-digital-stamping-service
    profiles: ["local-eseal"]
    restart: always
    image: "trustlynx/digital-stamping-service:24.0.3.0"
    environment:
      - SPRING_CONFIG_ADDITIONAL_LOCATION=file:/conf/
    volumes:
      - "./dmss-digital-stamping-service:/conf:ro"
      - "./dmss-digital-stamping-service/seal:/seal:ro"
    extra_hosts:
      - "host.docker.internal:host-gateway"
BLOCK
)

SIGNED_OUTPUT_VOLUME_LINE='      - "./signed-output:/signed-output"'
SPRING_SECURITY_LINES=$'      - SPRING_SECURITY_USER_NAME=user\n      - SPRING_SECURITY_USER_PASSWORD=changeit'

# ---- document-routing ----
mig_document_routing_title() { echo 'Add DOCUMENT_ROUTING block (disabled by default)'; }
mig_document_routing_files() { echo 'config/config.js'; }
mig_document_routing_needed() { need_document_routing; }
mig_document_routing_body()  { printf '%s\n' "$DOCUMENT_ROUTING_BLOCK"; }
mig_document_routing_apply() {
  if need_document_routing; then
    # Passed via the environment so the literal needs no second layer of
    # escaping. \r? on the anchor: a config.js with CRLF line endings ends
    # "};\r\n", which the original bare \n\}; anchor never matched — the
    # substitution silently did nothing while still printing success.
    DR_BLOCK="$DOCUMENT_ROUTING_BLOCK" perl -0777 -i -pe '
      BEGIN { $b = $ENV{DR_BLOCK} }
      $n = /\r\n/ ? "\r\n" : "\n";
      ($t = $b) =~ s/\n/$n/g;
      s/\r?\n\};\r?\n?\z/$n$t$n};$n/;
    ' "$config_js"
    if need_document_routing; then
      echo "  WARNING: could not locate the closing '};' in config/config.js — DOCUMENT_ROUTING not added" >&2
    else
      echo "  Added DOCUMENT_ROUTING (disabled)"
    fi
  else
    echo "  DOCUMENT_ROUTING already present"
  fi
}

# ---- signed-output ----
mig_signed_output_title() { echo 'Add signed-output volume mount and create signed-output/ and docs/'; }
mig_signed_output_files() { echo 'docker-compose.yml,signed-output/,docs/'; }
mig_signed_output_needed() { need_signed_output_vol || need_signed_output_dir; }
mig_signed_output_body() {
  need_signed_output_vol && printf 'docker-compose.yml, under the ps-server volumes:\n%s\n' "$SIGNED_OUTPUT_VOLUME_LINE"
  need_signed_output_dir && printf 'mkdir -p signed-output/ docs/   (mode 777)\n'
  return 0
}
mig_signed_output_apply() {
  if need_signed_output_vol; then
    sed -i "/config\/config\.js:\/usr\/src\/app\/config\.js/a\\${SIGNED_OUTPUT_VOLUME_LINE}" "$compose_yml"
    echo "  Added volume mount"
  else
    echo "  Volume mount already present"
  fi
  # Always ensured: the mount without the directory silently writes into the
  # container's ephemeral layer, so these two belong to the same migration.
  mkdir -p "${repo_root}/signed-output"
  chmod 777 "${repo_root}/signed-output" 2>/dev/null || true
  mkdir -p "${repo_root}/docs"
  chmod 777 "${repo_root}/docs" 2>/dev/null || true
}

# ---- local-eseal ----
mig_local_eseal_title() { echo 'Provision local e-sealing (in-stack stamping service)'; }
mig_local_eseal_files() { echo 'docker-compose.yml,config/config.js,.env,dmss-container-and-signature-services/application.yml,dmss-digital-stamping-service/'; }
mig_local_eseal_needed() {
  need_eseal_assets || need_eseal_compose || need_eseal_baseurl \
    || need_eseal_springsec || need_eseal_stampmode || need_eseal_profile
}
mig_local_eseal_body() {
  need_eseal_assets    && printf 'dmss-digital-stamping-service/ — stage demo application.yml + seal/seal.p12 + seal/README.md (never overwrites existing files)\n\n'
  need_eseal_compose   && printf 'docker-compose.yml, before the networks: block:\n%s\n\n' "$STAMPING_COMPOSE_BLOCK"
  need_eseal_baseurl   && printf 'dmss-container-and-signature-services/application.yml:\n  baseUrl: http://dmss-digital-stamping-service:8084/api\n\n'
  need_eseal_springsec && printf 'docker-compose.yml, on container-signature:\n%s\n\n' "$SPRING_SECURITY_LINES"
  need_eseal_stampmode && printf 'config/config.js:\n    %s\n\n' "$STAMP_LOCAL_BLOCK"
  need_eseal_profile   && printf '.env:\nCOMPOSE_PROFILES=local-eseal\n'
  return 0
}
mig_local_eseal_apply() {
  if [[ ! -d "$assets_src" ]]; then
    echo "ERROR: missing local-eseal assets at $assets_src" >&2
    echo "       Re-pull the deployment repo to fetch installation-scripts/assets/." >&2
    exit 3
  fi

  # 4b.1 — Materialize stamping artifacts (non-destructive: never overwrites
  # files the customer may have already replaced, e.g. their real seal.p12).
  if need_eseal_assets; then
    mkdir -p "$stamping_dst/seal"
    cp -n "$assets_src/application.yml" "$stamping_dst/application.yml" 2>/dev/null || true
    cp -n "$assets_src/seal/seal.p12"   "$stamping_dst/seal/seal.p12"   2>/dev/null || true
    cp -n "$assets_src/seal/README.md"  "$stamping_dst/seal/README.md"  2>/dev/null || true
    echo "  Demo stamping artifacts staged at ./dmss-digital-stamping-service/"
  else
    echo "  Stamping artifacts already present (preserved)"
  fi

  # 4b.2 — Append compose service block if missing.
  if need_eseal_compose; then
    if grep -q '^networks:' "$compose_yml"; then
      STAMP_BLOCK="$STAMPING_COMPOSE_BLOCK" perl -i -pe '
        BEGIN { $b = $ENV{STAMP_BLOCK} }
        if (/^networks:/ && !$done) { print "$b\n\n"; $done = 1 }
      ' "$compose_yml"
    else
      printf '\n%s\n' "$STAMPING_COMPOSE_BLOCK" >>"$compose_yml"
    fi
    echo "  Compose service block appended (gated by profiles: [local-eseal])"
  else
    echo "  Compose service block already present"
  fi

  # 4b.3 — Patch container-signature baseUrl so it talks to the in-network stamping container.
  if need_eseal_baseurl; then
    sed -i 's#^  baseUrl: http://host.docker.internal:8084/api#  baseUrl: http://dmss-digital-stamping-service:8084/api#' "$csig_yml"
    echo "  Patched dmss-container-and-signature-services/application.yml baseUrl"
  else
    echo "  Container-signature baseUrl already patched (or non-default)"
  fi

  # 4b.4 — Pin Spring Security creds on container-signature for stable basic auth.
  if need_eseal_springsec; then
    # Appends to the container-signature service's `environment:` list,
    # creating that key if the service doesn't have one.
    #
    # This used to insert two list items immediately BEFORE the service's
    # `image:` line. That only produces valid YAML when `image:` happens to
    # follow `environment:` — which is true of the compose file shipped in
    # this repo, and false on a deployment where `image:` is the service's
    # first key. There the two entries landed directly under the service
    # mapping, outside any list, and `docker compose` could no longer parse
    # the file. Anchoring on the `environment:` list instead makes the insert
    # independent of key order. Found on a live deployment.
    SS_LINES="$SPRING_SECURITY_LINES" perl -i -pe '
      BEGIN { $b = $ENV{SS_LINES}; $in = 0; $env = 0; $seen = 0; $done = 0 }
      if (!$done) {
        if (/^  dmss-container-and-signature-services:\s*$/) {
          $in = 1;
        } elsif ($in && /^  \S/) {
          # Reached the next service. Either the environment: list ran right
          # up to the block edge (append to it), or the service never had one
          # (create it). Emitting a second environment: key in the first case
          # is YAML-valid but silently discards the original entries.
          print $seen ? "$b\n" : "    environment:\n$b\n";
          $done = 1; $in = 0; $env = 0;
        }
        if ($in && !$done) {
          if (/^    environment:\s*$/) { $env = 1; $seen = 1 }
          elsif ($env && !/^      -/) { print "$b\n"; $done = 1; $env = 0 }
        }
      }
      END { print "$b\n" if $env && !$done }   # environment: list ran to EOF
    ' "$compose_yml"
    if need_eseal_springsec; then
      echo "  WARNING: could not locate the container-signature image line in docker-compose.yml —" >&2
      echo "           SPRING_SECURITY_USER_* not pinned. Local e-sealing will fail to authenticate" >&2
      echo "           after the next container recreate. Add them by hand under that service." >&2
    else
      echo "  Pinned Spring Security creds on container-signature"
    fi
  else
    echo "  Spring Security creds already pinned"
  fi

  # 4b.5 — Flip STAMP_MODE in config.js to "local" and ensure STAMP_LOCAL is present.
  # Three branches kept distinct to preserve byte-for-byte idempotency on
  # re-run: (1) insert if missing, (2) flip if currently external, (3) skip if
  # already local. The skip branch matters because `sed -i` always rewrites the
  # file (even on no-op substitutions) and on MSYS/Git-Bash that rewrite can
  # alter line-endings (CRLF -> LF), tripping change detection in later runs.
  if ! grep -q 'STAMP_MODE' "$config_js"; then
    SL_BLOCK="$STAMP_LOCAL_BLOCK" perl -0777 -i -pe '
      BEGIN { $b = $ENV{SL_BLOCK} }
      $n = /\r\n/ ? "\r\n" : "\n";
      ($t = $b) =~ s/\n/$n/g;
      s/STAMP_API_URL:/$t$n    STAMP_API_URL:/;
    ' "$config_js"
    echo "  Inserted STAMP_MODE=local + STAMP_LOCAL in config.js"
  elif grep -q 'STAMP_MODE: *"external"' "$config_js"; then
    sed -i 's/STAMP_MODE: *"external"/STAMP_MODE: "local"/' "$config_js"
    echo "  Flipped STAMP_MODE to \"local\" in config.js"
  else
    echo "  STAMP_MODE already set to \"local\" in config.js"
  fi

  # 4b.6 — Activate compose profile via .env so all subsequent
  # `docker compose up -d` calls auto-include the stamping service.
  touch "$env_file"
  if ! grep -q '^COMPOSE_PROFILES=' "$env_file"; then
    printf '\nCOMPOSE_PROFILES=local-eseal\n' >>"$env_file"
    echo "  Wrote COMPOSE_PROFILES=local-eseal to .env"
  elif need_eseal_profile; then
    # Operates only on the COMPOSE_PROFILES line: strip a trailing CR first,
    # then either fill an empty value or append. The previous one-liner used a
    # greedy (.*) which, on a CRLF .env under real GNU sed, swallowed the
    # carriage return and produced "COMPOSE_PROFILES=wizard\r,local-eseal" —
    # a profile name with an embedded CR that then matches nothing.
    # (Not reproducible under MSYS sed, which strips CR on read; see
    # documentation/05-02.)  The `t` branches out after filling an empty
    # value so it can't then also get a comma appended.
    sed -i '/^COMPOSE_PROFILES=/ {
      s/\r$//
      s/^COMPOSE_PROFILES=$/COMPOSE_PROFILES=local-eseal/
      t
      s/$/,local-eseal/
    }' "$env_file"
    echo "  Appended local-eseal to existing COMPOSE_PROFILES in .env"
  else
    echo "  .env already activates local-eseal profile"
  fi
}

# Dispatch helper: mig_call <id> <suffix>. Migration IDs use hyphens (they are
# a public contract in the plan output); bash function names use underscores.
mig_call() { "mig_${1//-/_}_$2"; }

# Migrations in scope for THIS invocation. local-eseal is only ever applied
# when explicitly requested, so it is only ever reported when requested too —
# a plan must not advertise work the same arguments wouldn't actually do.
plan_scope() {
  local id
  for id in "${MIGRATION_IDS[@]}"; do
    [[ "$id" == "local-eseal" && "$enable_local_eseal" != true ]] && continue
    echo "$id"
  done
}

# ── --plan-only ─────────────────────────────────────────────────────────────
# Evaluates every migration predicate and prints what WOULD change. Touches no
# file and runs no container. Reads the same predicates the apply path uses,
# so the plan cannot disagree with the run.
render_plan() {
  local id status title
  local srv_now cli_now
  srv_now="$(current_tag ps-server)"; srv_now="${srv_now:-unknown}"
  cli_now="$(current_tag ps-client)"; cli_now="${cli_now:-unknown}"

  if [[ "$plan_format" == machine ]]; then
    printf '###PLAN-BEGIN\n'
    printf 'server_tag_from=%s\n' "$srv_now"
    printf 'server_tag_to=%s\n'   "${server_tag:-$srv_now}"
    printf 'client_tag_from=%s\n' "$cli_now"
    printf 'client_tag_to=%s\n'   "${client_tag:-$cli_now}"
    while read -r id; do
      [[ -z "$id" ]] && continue
      if mig_call "$id" needed; then status="will-apply"; else status="already-applied"; fi
      printf '###PLAN-ITEM\n'
      printf 'id=%s\n' "$id"
      printf 'status=%s\n' "$status"
      printf 'files=%s\n' "$(mig_call "$id" files)"
      printf 'title=%s\n' "$(mig_call "$id" title)"
      printf '###PLAN-BODY-BEGIN\n'
      [[ "$status" == "will-apply" ]] && mig_call "$id" body
      printf '###PLAN-BODY-END\n'
      printf '###PLAN-ITEM-END\n'
    done < <(plan_scope)
    printf '###PLAN-END\n'
    return 0
  fi

  echo "========================================"
  echo "PadSign Upgrade — PLAN ONLY (nothing was changed)"
  echo "========================================"
  echo ""
  echo "  Image tags:"
  if [[ -n "$server_tag" ]]; then echo "    ps-server: ${srv_now} → ${server_tag}"
  else echo "    ps-server: ${srv_now} (unchanged)"; fi
  if [[ -n "$client_tag" ]]; then echo "    ps-client: ${cli_now} → ${client_tag}"
  else echo "    ps-client: ${cli_now} (unchanged)"; fi
  echo ""
  echo "  Configuration migrations:"
  echo ""
  local pending=0
  while read -r id; do
    [[ -z "$id" ]] && continue
    if mig_call "$id" needed; then status="WILL APPLY"; pending=$((pending + 1)); else status="already applied"; fi
    title="$(mig_call "$id" title)"
    printf '    [%s] %s\n' "$status" "$id"
    printf '        %s\n' "$title"
    printf '        files: %s\n' "$(mig_call "$id" files)"
    if [[ "$status" == "WILL APPLY" ]]; then
      echo ""
      mig_call "$id" body | sed 's/^/          /'
    fi
    echo ""
  done < <(plan_scope)

  if [[ "$pending" -eq 0 ]]; then
    echo "  No configuration changes. Running this upgrade would only pull images"
    echo "  and restart containers."
  else
    echo "  ${pending} configuration migration(s) would be applied."
  fi
  echo ""
  echo "  Nothing has been modified. Re-run without --plan-only to apply."
  echo "========================================"
}

if [[ "$plan_only" == true ]]; then
  render_plan
  exit 0
fi

echo "========================================"
echo "PadSign Upgrade"
[[ -n "$server_tag" ]] && echo "  ps-server: → ${server_tag}"
[[ -n "$client_tag" ]] && echo "  ps-client: → ${client_tag}"
echo "========================================"
echo ""

# ── Step 1: Backup ──
echo "Step 1/6: Backing up..."
cp -f "$compose_yml" "${compose_yml}.bak"
cp -f "$config_js" "${config_js}.bak"
echo "  Backups created"

# ── Step 2: Update image tags ──
echo "Step 2/6: Updating image tags..."
if [[ -n "$server_tag" ]]; then
  old_server="$(current_tag ps-server)"; old_server="${old_server:-unknown}"
  sed -i "s|mihailsgordijenko/ps-server:[0-9.]*|mihailsgordijenko/ps-server:${server_tag}|" "$compose_yml"
  echo "  ps-server: ${old_server} → ${server_tag}"
fi
if [[ -n "$client_tag" ]]; then
  old_client="$(current_tag ps-client)"; old_client="${old_client:-unknown}"
  sed -i "s|mihailsgordijenko/ps-client:[0-9.]*|mihailsgordijenko/ps-client:${client_tag}|" "$compose_yml"
  echo "  ps-client: ${old_client} → ${client_tag}"
fi

# ── Step 3: Ensure DOCUMENT_ROUTING ──
echo "Step 3/6: Ensuring DOCUMENT_ROUTING config..."
mig_call document-routing apply

# ── Step 4: Ensure signed-output volume + directory ──
echo "Step 4/6: Ensuring signed-output volume..."
mig_call signed-output apply

# ── Step 4b (optional): Enable local e-sealing ──
if [[ "$enable_local_eseal" == true ]]; then
  echo "Step 4b/6: Enabling local e-sealing..."
  mig_call local-eseal apply
fi

# ── Step 5: Pull and restart ──
echo "Step 5/6: Pulling images and restarting..."
cd "$repo_root"
services=""
[[ -n "$server_tag" ]] && services="$services ps-server"
[[ -n "$client_tag" ]] && services="$services ps-client"
if [[ "$enable_local_eseal" == true ]]; then
  # Pull / start the stamping service alongside any tagged images.
  services="$services dmss-digital-stamping-service"
fi
# .env now carries COMPOSE_PROFILES if applicable, so plain `docker compose`
# picks the profile up automatically.
docker compose pull $services
docker compose up -d $services
if [[ "$enable_local_eseal" == true ]]; then
  # container-signature needs to be restarted to pick up the new
  # SPRING_SECURITY_USER_* env vars and the patched baseUrl, and ps-server to
  # re-read config.js. These restarts are cheap and intentional.
  docker compose up -d dmss-container-and-signature-services ps-server
fi

# Also restart nginx to pick up any config changes
docker compose restart nginx 2>/dev/null || true
sleep 3

# ── Step 6: Verify ──
echo "Step 6/6: Verifying..."
echo ""
echo "  Running containers:"
docker ps --format '  {{.Names}}: {{.Image}} ({{.Status}})' | grep -E 'ps-server|ps-client|nginx' | sort

# Health check
if docker compose logs ps-server 2>/dev/null | grep -q "PadSign Server listening"; then
  echo ""
  echo "  ps-server: OK"
else
  echo ""
  echo "  WARNING: ps-server may not have started. Check: docker compose logs ps-server" >&2
fi

echo ""
echo "========================================"
echo "Upgrade complete!"
echo "  Rollback: cp docker-compose.yml.bak docker-compose.yml && cp config/config.js.bak config/config.js && docker compose up -d"
echo "========================================"
