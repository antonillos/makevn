#!/usr/bin/env bash
set -euo pipefail

MAKEVN_CRAP4JAVA_VERSION="0.1.0"
MAKEVN_CRAP4JAVA_SHA256="b996434078d560d52a058e3d9ffb0d07a9469ecdc57c8b4fa241fa70252bf68e"
MAKEVN_CRAP4JAVA_URL="https://github.com/antonillos/crap4java/releases/download/v${MAKEVN_CRAP4JAVA_VERSION}/crap4java-${MAKEVN_CRAP4JAVA_VERSION}.jar"

makevn_crap_cache_jar() {
  local cache_root="${XDG_CACHE_HOME:-}"
  if [[ -z "${cache_root}" && -n "${HOME:-}" ]]; then
    cache_root="${HOME}/.cache"
  fi
  [[ -n "${cache_root}" ]] || return 1
  printf '%s/makevn/crap4java/%s/crap4java-%s.jar\n' \
    "${cache_root}" "${MAKEVN_CRAP4JAVA_VERSION}" "${MAKEVN_CRAP4JAVA_VERSION}"
}

makevn_crap_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
  else
    return 1
  fi
}

makevn_crap_install_analyzer() {
  local jar_path=""
  local tmp_path=""
  local actual_sha=""

  command -v curl >/dev/null 2>&1 || {
    printf 'Error: curl is required to install crap4java.\n' >&2
    return 2
  }
  jar_path="$(makevn_crap_cache_jar || true)"
  [[ -n "${jar_path}" ]] || {
    printf 'Error: HOME or XDG_CACHE_HOME is required to install crap4java.\n' >&2
    return 2
  }
  mkdir -p "$(dirname "${jar_path}")"
  tmp_path="${jar_path}.tmp.$$"
  trap 'rm -f "${tmp_path}"' RETURN
  printf 'Downloading crap4java v%s from %s\n' "${MAKEVN_CRAP4JAVA_VERSION}" "${MAKEVN_CRAP4JAVA_URL}"
  if ! curl -fsSL "${MAKEVN_CRAP4JAVA_URL}" -o "${tmp_path}"; then
    printf 'Error: failed to download crap4java v%s.\n' "${MAKEVN_CRAP4JAVA_VERSION}" >&2
    return 2
  fi
  actual_sha="$(makevn_crap_sha256 "${tmp_path}" || true)"
  [[ -n "${actual_sha}" ]] || {
    printf 'Error: sha256sum or shasum is required to verify crap4java.\n' >&2
    return 2
  }
  if [[ "${actual_sha}" != "${MAKEVN_CRAP4JAVA_SHA256}" ]]; then
    printf 'Error: crap4java checksum mismatch (expected %s, got %s).\n' \
      "${MAKEVN_CRAP4JAVA_SHA256}" "${actual_sha}" >&2
    return 2
  fi
  mv "${tmp_path}" "${jar_path}"
  trap - RETURN
  printf 'Installed crap4java: %s\n' "${jar_path}"
}

makevn_crap_validate_number() {
  python3 - "$1" <<'PY'
import math, sys
try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if math.isfinite(value) and value >= 0 else 1)
PY
}

makevn_crap_validate_count() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

makevn_crap_module_root_for_xml() {
  local maven_base_path="$1"
  local xml_path="$2"
  local prefix="${xml_path%%/target/*}"
  if [[ "${xml_path}" == */jacoco-aggregate/jacoco.xml ]]; then
    printf '%s\n' "${maven_base_path}"
  elif [[ "${xml_path}" == */target/* && -d "${prefix}" ]]; then
    printf '%s\n' "${prefix}"
  else
    printf '%s\n' "${maven_base_path}"
  fi
}

makevn_crap_run() {
  local repo_root="$1"
  local command_name="${2:-crap}"
  local external_jar="${MAKEVN_CRAP4JAVA_JAR:-}"
  local maven_base_path=""
  local explicit_xml=""
  local threshold=""
  local max_warnings=""
  local analyzer_jar=""
  local cached_jar=""
  local java_home=""
  local java_bin=""
  local report_dir="${repo_root}/.makevn/reports/${command_name}"
  local raw_dir="${report_dir}/raw"
  local reporter="${MAKEVN_LIBEXEC_DIR}/crap/report.py"
  local xml_path=""
  local module_root=""
  local raw_log=""
  local raw_json=""
  local source_dir=""
  local source_file=""
  local rc=0
  local base_ref=""
  local -a xml_reports=()
  local -a report_args=()
  local -a java_sources=()

  shift 2
  if [[ "${command_name}" == "crap" && "${1:-}" == "install-analyzer" ]]; then
    shift
    [[ $# -eq 0 ]] || {
      printf 'Error: crap install-analyzer does not accept extra arguments.\n' >&2
      return 2
    }
    makevn_crap_install_analyzer
    return $?
  fi

  makevn_load_config "${repo_root}"
  threshold="${MAKEVN_CRAP_THRESHOLD:-8}"
  if [[ "${command_name}" == "crap" ]]; then
    max_warnings="${MAKEVN_CRAP_MAX_WARNINGS:-}"
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        [[ "${command_name}" == "crap-changes" && $# -ge 2 ]] || { printf 'Error: --base requires crap-changes and a value.\n' >&2; return 2; }
        base_ref="$2"
        shift 2
        ;;
      --jacoco-xml)
        [[ "${command_name}" == "crap" ]] || { printf 'Error: --jacoco-xml is only supported by crap.\n' >&2; return 2; }
        [[ $# -ge 2 ]] || { printf 'Error: Missing value for --jacoco-xml\n' >&2; return 2; }
        explicit_xml="$2"
        shift 2
        ;;
      --threshold)
        [[ "${command_name}" == "crap" ]] || { printf 'Error: --threshold is only supported by crap.\n' >&2; return 2; }
        [[ $# -ge 2 ]] || { printf 'Error: Missing value for --threshold\n' >&2; return 2; }
        threshold="$2"
        shift 2
        ;;
      --max-warnings)
        [[ "${command_name}" == "crap" ]] || { printf 'Error: --max-warnings is only supported by crap.\n' >&2; return 2; }
        [[ $# -ge 2 ]] || { printf 'Error: Missing value for --max-warnings\n' >&2; return 2; }
        max_warnings="$2"
        shift 2
        ;;
      *)
        printf 'Error: Unknown %s option: %s\n' "${command_name}" "$1" >&2
        return 2
        ;;
    esac
  done

  command -v python3 >/dev/null 2>&1 || { printf 'Error: python3 is required by makevn crap.\n' >&2; return 2; }
  makevn_crap_validate_number "${threshold}" || { printf 'Error: --threshold must be a finite non-negative number.\n' >&2; return 2; }
  if [[ -n "${max_warnings}" ]]; then
    makevn_crap_validate_count "${max_warnings}" || { printf 'Error: --max-warnings must be a non-negative integer.\n' >&2; return 2; }
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || { printf 'Error: No Maven project detected in %s.\n' "${repo_root}" >&2; return 2; }

  cached_jar="$(makevn_crap_cache_jar || true)"
  if [[ -n "${external_jar}" ]]; then
    analyzer_jar="${external_jar}"
  elif [[ -n "${MAKEVN_CRAP4JAVA_JAR:-}" ]]; then
    analyzer_jar="${MAKEVN_CRAP4JAVA_JAR}"
  elif [[ -n "${cached_jar}" && -f "${cached_jar}" ]]; then
    analyzer_jar="${cached_jar}"
  fi
  if [[ -z "${analyzer_jar}" || ! -f "${analyzer_jar}" ]]; then
    printf 'Error: crap4java is not installed. Set MAKEVN_CRAP4JAVA_JAR or run `makevn crap install-analyzer`.\n' >&2
    return 2
  fi

  if [[ -n "${explicit_xml}" ]]; then
    [[ "${explicit_xml}" = /* ]] || explicit_xml="${repo_root}/${explicit_xml}"
    [[ -f "${explicit_xml}" ]] || { printf 'Error: JaCoCo XML not found: %s\n' "${explicit_xml}" >&2; return 2; }
    xml_reports=("${explicit_xml}")
  else
    while IFS= read -r xml_path; do
      [[ -n "${xml_path}" ]] && xml_reports+=("${xml_path}")
    done < <(find "${maven_base_path}" -path '*/target/*' -name 'jacoco.xml' -type f -print 2>/dev/null | LC_ALL=C sort)
    if printf '%s\n' "${xml_reports[@]:-}" | grep -q '/jacoco-aggregate/jacoco.xml$'; then
      while IFS= read -r xml_path; do
        [[ -n "${xml_path}" ]] && { xml_reports=("${xml_path}"); break; }
      done < <(printf '%s\n' "${xml_reports[@]}" | grep '/jacoco-aggregate/jacoco.xml$')
    fi
  fi
  [[ ${#xml_reports[@]} -gt 0 ]] || {
    printf 'Error: No JaCoCo XML report found. Run `makevn verify-ut-coverage` or pass --jacoco-xml.\n' >&2
    return 2
  }

  java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  if [[ -n "${java_home}" && -x "${java_home}/bin/java" ]]; then
    java_bin="${java_home}/bin/java"
  elif command -v java >/dev/null 2>&1; then
    java_bin="$(command -v java)"
  else
    printf 'Error: Java is required to run crap4java.\n' >&2
    return 2
  fi
  [[ -f "${reporter}" ]] || { printf 'Error: Internal CRAP reporter not found: %s\n' "${reporter}" >&2; return 2; }

  mkdir -p "${raw_dir}"
  if [[ "${command_name}" == "crap-changes" ]]; then
    command -v git >/dev/null 2>&1 || { printf 'Error: git is required by crap-changes.\n' >&2; return 2; }
    if [[ -z "${base_ref}" ]]; then
      base_ref="$(makevn_detect_parent_branch_spec "${repo_root}")"
      base_ref="${base_ref%...HEAD}"
    fi
    python3 "${MAKEVN_LIBEXEC_DIR}/crap/changes.py" --repo-root "${repo_root}" --base "${base_ref}" --output "${report_dir}/changes.json" || return 2
  fi
  rm -f "${report_dir}/report.json" "${report_dir}/report.md" "${report_dir}/report.sarif" "${report_dir}/summary.txt" "${report_dir}/coverage-gaps.txt"
  rm -f "${raw_dir}"/*.json "${raw_dir}"/*.log 2>/dev/null || true
  report_args=(--output-dir "${report_dir}" --threshold "${threshold}")
  if [[ "${command_name}" == "crap-changes" ]]; then
    report_args+=(--changes-file "${report_dir}/changes.json" --repo-root "${repo_root}")
  fi
  [[ -z "${max_warnings}" ]] || report_args+=(--max-warnings "${max_warnings}")

  local report_index=0
  for xml_path in "${xml_reports[@]}"; do
    module_root="$(makevn_crap_module_root_for_xml "${maven_base_path}" "${xml_path}")"
    java_sources=()
    if [[ "${xml_path}" == */jacoco-aggregate/jacoco.xml || "${module_root}" == "${maven_base_path}" ]]; then
      while IFS= read -r source_dir; do
        while IFS= read -r source_file; do
          java_sources+=("${source_file}")
        done < <(find "${source_dir}" -type f -name '*.java' -print | LC_ALL=C sort)
      done < <(find "${maven_base_path}" -type d -path '*/src/main/java' ! -path '*/target/*' -print | LC_ALL=C sort)
    else
      source_dir="${module_root}/src/main/java"
      if [[ -d "${source_dir}" ]]; then
        while IFS= read -r source_file; do
          java_sources+=("${source_file}")
        done < <(find "${source_dir}" -type f -name '*.java' -print | LC_ALL=C sort)
      fi
    fi
    [[ ${#java_sources[@]} -gt 0 ]] || {
      printf 'Error: No production Java sources found for JaCoCo XML: %s\n' "${xml_path}" >&2
      return 2
    }
    report_index=$((report_index + 1))
    raw_log="${raw_dir}/report-${report_index}.log"
    raw_json="${raw_log%.log}.json"
    set +e
    "${java_bin}" -jar "${analyzer_jar}" \
      --format json --jacoco-xml "${xml_path}" --report-only --threshold "${threshold}" \
      "${java_sources[@]}" >"${raw_json}" 2>"${raw_log}"
    rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
      tail -n 40 "${raw_log}" >&2 || true
      printf 'Error: crap4java analysis failed for %s (exit %s).\n' "${module_root}" "${rc}" >&2
      printf 'Analyzer log: %s\n' "${raw_log}" >&2
      return 2
    fi
    [[ -s "${raw_json}" ]] || { printf 'Error: crap4java produced no JSON for %s. Analyzer log: %s\n' "${module_root}" "${raw_log}" >&2; return 2; }
    report_args+=(--input "${raw_json}" --jacoco-xml "${xml_path}")
    [[ "${command_name}" != "crap-changes" ]] || report_args+=(--source-root "${module_root}")
  done

  set +e
  python3 "${reporter}" "${report_args[@]}"
  rc=$?
  set -e
  if [[ ${rc} -eq 2 ]]; then
    for raw_json in "${raw_dir}"/report-*.json; do
      [[ -f "${raw_json}" ]] || continue
      printf 'Analyzer JSON: %s\n' "${raw_json}" >&2
      printf 'Analyzer log: %s (may be empty if analysis succeeded)\n' "${raw_json%.json}.log" >&2
    done
  fi
  [[ -f "${report_dir}/summary.txt" ]] && cat "${report_dir}/summary.txt"
  if [[ "${command_name}" == "crap" || ${rc} -ne 0 ]]; then
    printf 'Artifacts: %s\n' "${report_dir}"
  fi
  return ${rc}
}

cmd_crap() {
  local repo_root="$1"
  local command_name="${2:-crap}"
  local log_path=""
  local detail_line=""
  local rc=0

  if ! makevn_frontend_owns_loader; then
    makevn_crap_run "$@"
    return $?
  fi

  log_path="$(makevn_logs_dir "${repo_root}")/${command_name}.log"
  mkdir -p "$(dirname "${log_path}")"
  : > "${log_path}"
  makevn_write_backend_metadata \
    "${MAKEVN_BACKEND_METADATA_OUT:-}" \
    "${command_name}" "${repo_root}" "${repo_root}" "${log_path}" \
    ".makevn/logs/${command_name}.log" "makevn ${command_name}" '' "${command_name}"

  if (makevn_crap_run "$@") > "${log_path}" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  while IFS= read -r detail_line; do
    case "${detail_line}" in
      Error:*|Coverage\ gaps:*|Coverage\ diagnosis:*|Analyzer\ JSON:*|Analyzer\ log:*|Artifacts:*|CRAP\ report*|CRAP\ changes*|Base:*|Gate:*|Methods:*|Warnings:*|Missing\ coverage:*|Installed\ crap4java:*)
        makevn_print_detail_line "${detail_line}"
        ;;
    esac
  done < "${log_path}"
  return ${rc}
}
