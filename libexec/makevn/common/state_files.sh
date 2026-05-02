#!/usr/bin/env bash
set -euo pipefail

makevn_existing_makefile_path() {
  local repo_root="$1"
  if [[ -f "${repo_root}/Makefile" ]]; then
    printf '%s\n' "${repo_root}/Makefile"
    return 0
  fi
  if [[ -f "${repo_root}/GNUmakefile" ]]; then
    printf '%s\n' "${repo_root}/GNUmakefile"
    return 0
  fi
  return 1
}

makevn_existing_makefiles_count() {
  local repo_root="$1"
  local count=0
  [[ -f "${repo_root}/Makefile" ]] && count=$((count + 1))
  [[ -f "${repo_root}/GNUmakefile" ]] && count=$((count + 1))
  printf '%s\n' "${count}"
}

makevn_single_existing_makefile_path() {
  local repo_root="$1"
  local count

  count="$(makevn_existing_makefiles_count "${repo_root}")"
  if [[ "${count}" -eq 0 ]]; then
    makevn_die "No Makefile or GNUmakefile exists in ${repo_root}"
  fi

  if [[ "${count}" -gt 1 ]]; then
    makevn_die "Both Makefile and GNUmakefile exist. Add the include manually to avoid ambiguity."
  fi

  makevn_existing_makefile_path "${repo_root}"
}

makevn_manifest_value() {
  local repo_root="$1"
  local key="$2"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${manifest_path}"
}

makevn_recommended_mode() {
  local repo_root="$1"
  local maven_base_path=""

  if [[ -f "$(makevn_manifest_path "${repo_root}")" ]]; then
    printf '%s\n' "$(makevn_manifest_value "${repo_root}" mode || true)"
    return 0
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    printf '%s\n' unsupported
    return 0
  fi

  if [[ -f "${repo_root}/Makefile" || -f "${repo_root}/GNUmakefile" ]]; then
    printf '%s\n' make-include
    return 0
  fi

  printf '%s\n' standalone
}

makevn_render_make_include() {
  local bin_path="$1"
  local template_path="${MAKEVN_INSTALL_ROOT}/share/makevn/makevn.mk"

  if [[ ! -f "${template_path}" ]]; then
    makevn_die "Make include template not found: ${template_path}"
  fi

  printf 'MAKEVN_BIN ?= %s\n' "${bin_path}"
  awk 'NR > 1 { print }' "${template_path}"
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
MAKEVN_COMPOSE_FILE=""
MAKEVN_E2E_COMPOSE_FILE=""
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

makevn_write_state_json() {
  local repo_root="$1"
  local mode="$2"
  local managed_makefile="$3"
  local generated_root_makefile="$4"
  local state_path

  state_path="$(makevn_state_json_path "${repo_root}")"
  cat > "${state_path}" <<EOF
{
  "version": 1,
  "mode": "${mode}",
  "repo_root": "${repo_root}",
  "managed_makefile": "${managed_makefile}",
  "generated_root_makefile": "${generated_root_makefile}",
  "generated_at": "$(makevn_now_utc)"
}
EOF
}

makevn_write_manifest() {
  local repo_root="$1"
  local mode="$2"
  local managed_makefile="$3"
  local generated_root_makefile="$4"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  cat > "${manifest_path}" <<EOF
mode=${mode}
managed_makefile=${managed_makefile}
generated_root_makefile=${generated_root_makefile}
generated_at=$(makevn_now_utc)
EOF
}

makevn_insert_include_block() {
  local makefile_path="$1"

  if grep -Fq "${MAKEVN_BLOCK_BEGIN}" "${makefile_path}"; then
    return 0
  fi

  cat >> "${makefile_path}" <<EOF

${MAKEVN_BLOCK_BEGIN}
include .makevn/makevn.mk
${MAKEVN_BLOCK_END}
EOF
}

makevn_remove_include_block() {
  local makefile_path="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v begin="${MAKEVN_BLOCK_BEGIN}" -v end="${MAKEVN_BLOCK_END}" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "${makefile_path}" > "${tmp_file}"
  mv "${tmp_file}" "${makefile_path}"
}

makevn_bootstrap_makefile_content() {
  cat <<'EOF'
# Generated by makevn. Remove with `makevn uninstall`.
include .makevn/makevn.mk
EOF
}

makevn_write_bootstrap_makefile() {
  local repo_root="$1"
  makevn_bootstrap_makefile_content > "${repo_root}/Makefile"
}

makevn_is_managed_bootstrap_makefile() {
  local repo_root="$1"
  local makefile_path="${repo_root}/Makefile"
  [[ -f "${makefile_path}" ]] || return 1
  cmp -s <(makevn_bootstrap_makefile_content) "${makefile_path}"
}

