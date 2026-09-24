# shellcheck shell=bash
#
# Readers and rewriters for the two places docker-compose.yml names the
# deployment hostname, plus a reader for the hostname nginx.conf serves.
#
# Sourced by configure-host.sh (rewrites both on every hostname change),
# upgrade.sh (the `compose-hostname` migration for deployments configured
# before configure-host.sh did this) and validate-config.sh (the consistency
# check). All three use these same functions, so the check, the migration
# preview and the rewrite cannot disagree about what "matches" means.
#
#   1. KC_HOSTNAME on the keycloak service. NOT inert: with it set, Keycloak
#      26 uses it as its fixed frontend hostname regardless of
#      KC_HOSTNAME_STRICT or the proxy headers, so it decides the token
#      issuer and every URL Keycloak renders (login form action, redirects).
#      Left at the shipped padsign.trustlynx.com, a deployment on any other
#      host sends browsers to that host at login (form action, redirects) and
#      names it as every token's issuer. (ps-server itself validates tokens
#      by introspection, which does not compare the issuer, so its API calls
#      are not what breaks; the browser login is.)
#   2. The first network alias on the nginx service. Makes https://<host>/
#      resolve to nginx from inside the Docker network (ps-server's calls to
#      its own https://<host>/auth, /archive/api, ...), instead of relying on
#      public DNS hairpinning back to the same machine.
#
# Every function is self-contained; none expects caller variables.

# Prints KC_HOSTNAME's value exactly as written (list form `- KC_HOSTNAME=x`
# or map form `KC_HOSTNAME: x`, optionally quoted), or nothing if absent.
compose_kc_hostname() {  # <compose.yml>
  perl -ne '
    if (/^\s*-\s*["\x27]?KC_HOSTNAME=([^"\x27\s]*)/ || /^\s*KC_HOSTNAME:\s*["\x27]?([^"\x27\s#]*)/) {
      print "$1\n"; exit;
    }
  ' "$1"
}

# Bare, lower-cased host of a KC_HOSTNAME value. KC_HOSTNAME may be a bare
# host (this repo's form) or, in Keycloak 26's hostname v2, a full URL such
# as https://host:8443/auth — only the host part is compared.
kc_hostname_host() {  # <value>
  local v="${1#*://}"
  v="${v%%/*}"
  v="${v%%:*}"
  printf '%s\n' "${v,,}"
}

# Rewrites the host part of KC_HOSTNAME in place, keeping any scheme, port,
# path and quoting. Host passed via the environment, never interpolated into
# the perl source. Returns 1 if there is no KC_HOSTNAME line to rewrite.
compose_set_kc_hostname() {  # <compose.yml> <host>
  [[ -n "$(compose_kc_hostname "$1")" ]] || return 1
  CH_HOST="$2" perl -i -pe '
    s{^(\s*-\s*["\x27]?KC_HOSTNAME=(?:[A-Za-z][A-Za-z0-9+.-]*://)?)[^/:"\x27\s]*}{$1$ENV{CH_HOST}};
    s{^(\s*KC_HOSTNAME:\s*["\x27]?(?:[A-Za-z][A-Za-z0-9+.-]*://)?)[^/:"\x27\s#]*}{$1$ENV{CH_HOST}};
  ' "$1"
}

# The nginx-alias logic is anchored on YAML structure, not on a neighbouring
# line or on the alias's current value (see AGENTS.md: compose edits must
# anchor on structure): it tracks which service block it is in, and inside
# the `nginx` service reads the block-style list under any `aliases:` key.
# Block lists only — an inline `aliases: [a, b]` is left alone and reported
# as having no aliases.
#
# CH_MODE=read  prints one alias per line.
# CH_MODE=write (CH_HOST set) prints one of:
#   present          host is already one of the aliases — file untouched
#   changed <old>    first alias was <old>, rewritten to host
#   absent           nginx has no block-style aliases list — file untouched
# shellcheck disable=SC2016  # perl source, not shell
_compose_nginx_alias_perl='
  my @lines = <STDIN>;
  my ($in_services, $svc_indent, $svc, $al_indent) = (0, undef, "", undef);
  my @items;   # indices of alias list-item lines inside the nginx service
  for my $i (0 .. $#lines) {
    my $l = $lines[$i];
    if ($l =~ /^services:\s*(#.*)?\r?$/) { $in_services = 1; $svc = ""; next; }
    if ($l =~ /^[^\s#]/) { $in_services = 0; $svc = ""; $al_indent = undef; next; }
    next unless $in_services;
    if ($l =~ /^(\s+)([\w.-]+):\s*(#.*)?\r?$/ && (!defined $svc_indent || length($1) <= $svc_indent)) {
      $svc_indent = length($1); $svc = $2; $al_indent = undef; next;
    }
    next unless $svc eq "nginx";
    if (defined $al_indent) {
      next if $l =~ /^\s*(#.*)?\r?$/;
      if ($l =~ /^(\s*)-\s*["\x27]?[^"\x27\s#]+/ && length($1) >= $al_indent) { push @items, $i; next; }
      $al_indent = undef;
    }
    if ($l =~ /^(\s*)aliases:\s*(#.*)?\r?$/) { $al_indent = length($1); }
  }
  my @vals = map { $lines[$_] =~ /^\s*-\s*["\x27]?([^"\x27\s#]+)/; $1 } @items;
  if ($ENV{CH_MODE} eq "read") { print "$_\n" for @vals; exit 0; }
  my $want = lc $ENV{CH_HOST};
  if (!@items) { print "absent\n"; exit 0; }
  if (grep { lc($_) eq $want } @vals) { print "present\n"; exit 0; }
  $lines[$items[0]] =~ s/^(\s*-\s*["\x27]?)[^"\x27\s#]+/$1$ENV{CH_HOST}/;
  open(my $fh, ">", $ARGV[0]) or die "cannot write $ARGV[0]: $!\n";
  print $fh @lines;
  close($fh);
  print "changed $vals[0]\n";
'

compose_nginx_aliases() {  # <compose.yml>
  CH_MODE=read perl -e "$_compose_nginx_alias_perl" "$1" < "$1"
}

compose_set_nginx_alias() {  # <compose.yml> <host>
  CH_MODE=write CH_HOST="$2" perl -e "$_compose_nginx_alias_perl" "$1" < "$1"
}

# True (exit 0) when nginx HAS a block-style aliases list and <host> is not
# in it — i.e. compose_set_nginx_alias would change something. No list at
# all is not "needed": nothing resolves through it, and upgrade.sh does not
# invent one.
nginx_alias_needs_update() {  # <compose.yml> <host>
  local want="${2,,}" a found=""
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    found="yes"
    [[ "${a,,}" == "$want" ]] && return 1
  done < <(compose_nginx_aliases "$1")
  [[ -n "$found" ]]
}

# The single hostname nginx.conf serves (every server_name directive must
# name the same one host), lower-cased; nothing if there is none, several,
# or a wildcard/regex/catch-all name — callers then have no host to align to.
nginx_server_name() {  # <nginx.conf>
  local names
  names="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
    | grep -oE '(^|[[:space:];{])server_name[[:space:]]+[^;]+' \
    | sed -E 's/.*server_name[[:space:]]+//' \
    | tr -s ' \t\r' '\n\n\n' | sed '/^$/d' | tr '[:upper:]' '[:lower:]' | sort -u)"
  [[ -z "$names" || "$names" == *$'\n'* ]] && return 0
  [[ "$names" == "_" || "$names" == *'*'* || "$names" == '~'* ]] && return 0
  printf '%s\n' "$names"
}
