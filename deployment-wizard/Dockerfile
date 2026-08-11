# node:18-bookworm-slim, NOT alpine: installation-scripts/*.sh use `grep -oP`
# (PCRE) in several places (upgrade.sh, validate-config.sh) — BusyBox grep on
# Alpine doesn't support -P. Debian's default grep is GNU grep with PCRE
# support built in.
FROM node:18-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash perl python3 curl openssl ca-certificates gawk \
      gnupg lsb-release \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/wizard
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .

ENV NODE_ENV=production
EXPOSE 8443
# Absolute path, not "server.js" — docker-compose.yml must never set
# working_dir on this service (it would override this WORKDIR and break
# module resolution). The app's own child-process calls (bootstrap.sh,
# docker compose, etc.) already pass an explicit `cwd: HOST_PROJECT_DIR`
# in code (see lib/paths.js), so nothing depends on the container's own
# runtime cwd matching the project directory.
CMD ["node", "/usr/src/wizard/server.js"]
