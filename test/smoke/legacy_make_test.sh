#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT_DIR}/bin/makevn"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"
for executable in make gmake; do
  printf '#!/usr/bin/env bash\nprintf "Make must never be invoked\\n" >&2\nexit 91\n' > "${TMP}/bin/${executable}"
  chmod +x "${TMP}/bin/${executable}"
done
export PATH="${TMP}/bin:${PATH}"
repo="${TMP}/repo with \"quotes\" and spaces"
mkdir -p "${repo}"
printf '<project/>\n' > "${repo}/pom.xml"
"${CLI}" --repo "${repo}" doctor --compact >/dev/null
"${CLI}" --repo "${repo}" init >/dev/null
printf 'MAKEVN_LOCAL_CONTAINERS="custom"\n' >> "${repo}/.makevn/config"
cp "${repo}/.makevn/config" "${TMP}/config"
# Retired entrypoints, including MCP, are absent; errors cannot reach uninstall.
for subcommand in install uninstall; do
  if "${ROOT_DIR}/target/release/makevn" --repo "${repo}" make "${subcommand}" >"${TMP}/out" 2>&1; then exit 1; fi
  grep -Fq 'Unknown command: make' "${TMP}/out"
  if "${CLI}" --repo "${repo}" make "${subcommand}" >"${TMP}/out" 2>&1; then exit 1; fi
  grep -Fq 'Unknown command: make' "${TMP}/out"
  if bash "${ROOT_DIR}/libexec/makevn/backend.sh" make --repo "${repo}" "${subcommand}" >"${TMP}/out" 2>&1; then exit 1; fi
  grep -Fq 'Unknown backend command: make' "${TMP}/out"
done
# Both forced initialization and refresh use the same migration, preserving config.
for command in 'init --force' refresh; do
  printf 'custom:\n\t@echo retained\n\n' > "${repo}/GNUmakefile"
  cp "${repo}/GNUmakefile" "${TMP}/original"
  printf '# makevn:begin\ninclude .makevn/makevn.mk\n# makevn:end\n' >> "${repo}/GNUmakefile"
  printf 'managed_makefile=GNUmakefile\ngenerated_root_makefile=\n' >> "${repo}/.makevn/manifest"
  cp "${ROOT_DIR}/test/smoke/fixtures/legacy-makevn.mk" "${repo}/.makevn/makevn.mk"
  cp "${repo}/GNUmakefile" "${TMP}/before"
  "${CLI}" --repo "${repo}" ${command} --dry-run > "${TMP}/out"
  cmp "${repo}/GNUmakefile" "${TMP}/before"
  grep -Fq 'would remove managed block' "${TMP}/out"
  "${CLI}" --repo "${repo}" ${command} >/dev/null
  cmp "${repo}/GNUmakefile" "${TMP}/original"
  cmp "${repo}/.makevn/config" "${TMP}/config"
  [[ ! -e "${repo}/.makevn/makevn.mk" ]]
  ! grep -q 'managed_makefile\|generated_root_makefile' "${repo}/.makevn/manifest"
  ! grep -q 'managed_makefile\|generated_root_makefile' "${repo}/.makevn/state.json"
done
# Profile refresh must leave an unknown artifact unchanged, not regenerate it.
printf 'user content\n' > "${repo}/.makevn/makevn.mk"
"${CLI}" --repo "${repo}" profile refresh >/dev/null
[[ "$(cat "${repo}/.makevn/makevn.mk")" == 'user content' ]]
for command in 'init --force' refresh uninstall; do
  cp "${repo}/.makevn/manifest" "${TMP}/manifest"
  if "${CLI}" --repo "${repo}" ${command} >"${TMP}/out" 2>&1; then exit 1; fi
  grep -Fq 'No files changed' "${TMP}/out"
  cmp "${repo}/.makevn/manifest" "${TMP}/manifest"
  cmp "${repo}/.makevn/config" "${TMP}/config"
done
# Sequence dispatch must also fail closed while a conditional suppresses errexit.
if "${CLI}" --repo "${repo}" init --force uninstall >"${TMP}/out" 2>&1; then exit 1; fi
[[ -f "${repo}/.makevn/manifest" && -f "${repo}/.makevn/makevn.mk" ]]
rm "${repo}/.makevn/makevn.mk"
# Makefile variables no longer supply application execution defaults.
printf 'LOCAL_TEST ?= TRUE\nexport LOCAL_CONTAINERS := ${LOCAL_TEST}\n' > "${repo}/Makefile"
bash -c 'source "$1/libexec/makevn/common.sh"; source "$1/libexec/makevn/commands/run.sh"; unset LOCAL_CONTAINERS MAKEVN_LOCAL_CONTAINERS; makevn_load_config() { :; }; if makevn_effective_app_local_containers "$2"; then exit 1; fi' _ "${ROOT_DIR}" "${repo}"
"${CLI}" --repo "${repo}" uninstall --dry-run >/dev/null
[[ -f "${repo}/.makevn/manifest" ]]
"${CLI}" --repo "${repo}" uninstall >/dev/null
[[ -f "${repo}/Makefile" && -f "${repo}/GNUmakefile" && ! -e "${repo}/.makevn" ]]
printf 'Legacy Make retirement CLI tests passed\n'
