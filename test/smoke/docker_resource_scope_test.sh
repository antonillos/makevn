#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/commands/docker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
repo="${TMP}/repo with spaces"
mkdir -p "${repo}"
touch "${repo}/custom.yml" "${repo}/override.yml"
export MAKEVN_FRONTEND_RESOURCE_SCOPE_OUT="${TMP}/scope"
makevn_publish_compose_resources "${repo}" 'docker compose' "${repo}/custom.yml" "${repo}/override.yml"
printf '%s\n' "${repo}" docker compose -f "${repo}/custom.yml" -f "${repo}/override.yml" > "${TMP}/expected"
cmp "${TMP}/scope" "${TMP}/expected"
makevn_publish_compose_resources "${repo}" 'docker-compose' "${repo}/custom.yml" "${repo}/missing.yml"
printf '%s\n' "${repo}" docker-compose -f "${repo}/custom.yml" > "${TMP}/expected"
cmp "${TMP}/scope" "${TMP}/expected"
rm "${TMP}/scope"
makevn_publish_compose_resources "${repo}" 'docker compose' "${repo}/missing.yml" ""
[[ ! -e "${TMP}/scope" ]]
makevn_publish_compose_resources $'invalid\nrepo' 'docker compose' "${repo}/custom.yml" ""
[[ ! -e "${TMP}/scope" ]]
unset MAKEVN_FRONTEND_RESOURCE_SCOPE_OUT
makevn_publish_compose_resources "${repo}" 'docker compose' "${repo}/custom.yml" ""
printf 'Docker resource scope tests passed\n'
# Resolve the boot project's scope for read-only docker-ps/docker-stats commands.
makevn_resolve_docker_compose_command() { printf 'docker compose\n'; }
makevn_boot_compose_file_path() { printf '%s/custom.yml\n' "$1"; }
makevn_boot_compose_override_file_path() { printf '%s/override.yml\n' "$1"; }
export MAKEVN_FRONTEND_RESOURCE_SCOPE_OUT="${TMP}/scope"
makevn_publish_boot_resources "${repo}"
printf '%s\n' "${repo}" docker compose -f "${repo}/custom.yml" -f "${repo}/override.yml" > "${TMP}/expected"
cmp "${TMP}/scope" "${TMP}/expected"
