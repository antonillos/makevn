#!/usr/bin/env bash
set -euo pipefail

makevn_manifest_value() {
  local repo_root="$1"
  local key="$2"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${manifest_path}"
}

makevn_repository_support_status() {
  local repo_root="$1"
  local maven_base_path=""

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    printf '%s\n' unsupported
    return 0
  fi

  printf '%s\n' supported
}

makevn_write_config() {
  local repo_root="$1"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"
  cat > "${config_path}" <<'EOF'
# makevn local configuration
MAKEVN_JAVA_HOME=""
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
MAKEVN_KARATE_APP_PROFILES=""
MAKEVN_FORMAT_CHECK_GOAL=""
MAKEVN_FORMAT_APPLY_GOAL=""
MAKEVN_CHECKSTYLE_GOAL=""
MAKEVN_COVERAGE_PROP_FLAGS="-Djacoco.skip=false"
MAKEVN_MIN_COVERAGE_THRESHOLD=""
MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD=""
MAKEVN_CRAP4JAVA_JAR=""
MAKEVN_CRAP_THRESHOLD="8"
MAKEVN_CRAP_MAX_WARNINGS=""
MAKEVN_COMPOSE_FILE=""
MAKEVN_E2E_COMPOSE_FILE=""
MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS=""
EOF
}

makevn_update_config_compose_file() {
  local repo_root="$1"
  local compose_file="$2"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  if grep -q '^MAKEVN_COMPOSE_FILE=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${compose_file}" 'BEGIN{q="\""} /^MAKEVN_COMPOSE_FILE=/ { print "MAKEVN_COMPOSE_FILE=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf 'MAKEVN_COMPOSE_FILE=%q\n' "${compose_file}" >> "${config_path}"
  fi
}

makevn_update_config_e2e_compose_file() {
  local repo_root="$1"
  local compose_file="$2"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  if grep -q '^MAKEVN_E2E_COMPOSE_FILE=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${compose_file}" 'BEGIN{q="\""} /^MAKEVN_E2E_COMPOSE_FILE=/ { print "MAKEVN_E2E_COMPOSE_FILE=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf 'MAKEVN_E2E_COMPOSE_FILE=%q\n' "${compose_file}" >> "${config_path}"
  fi
}

makevn_update_config_app_health_url() {
  local repo_root="$1"
  local app_health_url="$2"
  local config_path
  local config_line
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  printf -v config_line 'MAKEVN_APP_HEALTH_URL=%q' "${app_health_url}"

  if grep -q '^MAKEVN_APP_HEALTH_URL=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    MAKEVN_CONFIG_HEALTH_LINE="${config_line}" awk '/^MAKEVN_APP_HEALTH_URL=/ { print ENVIRON["MAKEVN_CONFIG_HEALTH_LINE"]; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf '%s\n' "${config_line}" >> "${config_path}"
  fi
}

makevn_update_config_local_containers() {
  local repo_root="$1"
  local local_containers="$2"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  if grep -q '^MAKEVN_LOCAL_CONTAINERS=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${local_containers}" 'BEGIN{q="\""} /^MAKEVN_LOCAL_CONTAINERS=/ { print "MAKEVN_LOCAL_CONTAINERS=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf 'MAKEVN_LOCAL_CONTAINERS=%q\n' "${local_containers}" >> "${config_path}"
  fi
}

makevn_update_config_min_coverage_threshold() {
  local repo_root="$1"
  local min_coverage_threshold="$2"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  if grep -q '^MAKEVN_MIN_COVERAGE_THRESHOLD=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${min_coverage_threshold}" 'BEGIN{q="\""} /^MAKEVN_MIN_COVERAGE_THRESHOLD=/ { print "MAKEVN_MIN_COVERAGE_THRESHOLD=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf 'MAKEVN_MIN_COVERAGE_THRESHOLD=%q\n' "${min_coverage_threshold}" >> "${config_path}"
  fi
}

makevn_update_config_min_coverage_changes_threshold() {
  local repo_root="$1"
  local min_coverage_threshold="$2"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  if grep -q '^MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${min_coverage_threshold}" 'BEGIN{q="\""} /^MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD=/ { print "MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    printf 'MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD=%q\n' "${min_coverage_threshold}" >> "${config_path}"
  fi
}

makevn_write_state_json() {
  local repo_root="$1"
  local state_path

  state_path="$(makevn_state_json_path "${repo_root}")"
  cat > "${state_path}" <<EOF
{
  "version": 1,
  "repo_root": "$(makevn_json_escape "${repo_root}")",
  "generated_at": "$(makevn_now_utc)"
}
EOF
}

makevn_write_manifest() {
  local repo_root="$1"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  cat > "${manifest_path}" <<EOF
makevn_version=${MAKEVN_VERSION}
generated_at=$(makevn_now_utc)
EOF
}

makevn_update_config_generated_contract_clean_dirs() {
  local repo_root="$1"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"

  if [[ ! -f "${config_path}" ]]; then
    return 1
  fi

  local maven_base_path=""
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || return 0

  local unresolved
  unresolved="$(makevn_detect_unresolved_generated_contract_dirs "${maven_base_path}" | tr '\n' ' ' | sed 's/ $//')"

  if grep -q '^MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS=' "${config_path}"; then
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v val="${unresolved}" 'BEGIN{q="\""} /^MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS=/ { print "MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS=" q val q; next } { print }' "${config_path}" > "${tmp_file}"
    mv "${tmp_file}" "${config_path}"
  else
    local q="\""
    printf 'MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS=%s%s%s\n' "${q}" "${unresolved}" "${q}" >> "${config_path}"
  fi
}
