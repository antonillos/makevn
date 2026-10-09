#!/usr/bin/env bash
set -euo pipefail

repo="${1:-${MAKEVN_DOCKER_DEMO_REPO:-/tmp/makevn-docker-demo}}"

"$(dirname "$0")/setup-demo-repo.sh" developer "${repo}" >/dev/null

cat > "${repo}/docker-compose.yml" <<'EOF'
services:
  worker:
    image: busybox:1.36
    command: ["sh", "-c", "while true; do sleep 60; done"]
EOF

mkdir -p "${repo}/.makevn"
printf 'MAKEVN_LOCAL_CONTAINERS=TRUE\n' > "${repo}/.makevn/config"

git -C "${repo}" add docker-compose.yml
git -C "${repo}" \
  -c user.name="makevn demo" \
  -c user.email="demo@makevn.dev" \
  commit --quiet -m "Add required Docker service"

printf '%s\n' "${repo}"
