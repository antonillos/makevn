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

makevn_validate_doctor_setting() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "${MAKEVN_LIBEXEC_DIR}/common/doctor_setup.py" validate "$1" "$2"
    return $?
  fi
  case "$1" in
    app_health_url) [[ "$2" =~ ^https?://[^[:space:]]+$ ]] ;;
    karate_app_profiles) [[ "$2" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] ;;
    *) return 1 ;;
  esac
}

# Share atomic setup persistence with chat; retain CLI support without Python.
makevn_update_config_setting() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "${MAKEVN_LIBEXEC_DIR}/common/doctor_setup.py" set "$(makevn_config_path "$1")" "$2" "$3"
    return $?
  fi
  local config_path line tmp_file
  config_path="$(makevn_config_path "$1")"
  [[ -f "${config_path}" ]] || return 1
  printf -v line '%s=%q' "$2" "$3"
  tmp_file="$(mktemp "${config_path}.XXXXXX")"
  MAKEVN_CONFIG_KEY="$2" MAKEVN_CONFIG_LINE="${line}" awk 'index($0, ENVIRON["MAKEVN_CONFIG_KEY"] "=") == 1 {next} {print} END {print ENVIRON["MAKEVN_CONFIG_LINE"]}' "${config_path}" > "${tmp_file}"
  mv "${tmp_file}" "${config_path}"
}

makevn_update_config_compose_file() {
  makevn_update_config_setting "$1" MAKEVN_COMPOSE_FILE "$2"
}

makevn_update_config_e2e_compose_file() {
  makevn_update_config_setting "$1" MAKEVN_E2E_COMPOSE_FILE "$2"
}

makevn_update_config_app_health_url() {
  makevn_update_config_setting "$1" MAKEVN_APP_HEALTH_URL "$2"
}

makevn_update_config_local_containers() {
  makevn_update_config_setting "$1" MAKEVN_LOCAL_CONTAINERS "$2"
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
