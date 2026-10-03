#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT_DIR}/bin/makevn"
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# A real restricted PATH, not a fake python that may hide an invocation.
mkdir -p "${TMP}/no-python"
for executable in bash sh env dirname basename git grep awk sed head tail tr cat mkdir rm find cp chmod uname date wc cmp cut sort readlink mktemp mv xargs perl; do
  path="$(command -v "${executable}")"
  ln -s "${path}" "${TMP}/no-python/${executable}"
done
if PATH="${TMP}/no-python" command -v python3 >/dev/null 2>&1; then exit 1; fi
repo="${TMP}/repo with \"quotes\" and spaces"
mkdir -p "${repo}"
printf '<project/>\n' > "${repo}/pom.xml"
printf 'custom:\n\t@echo preserved\n# makevn:begin\ninclude .makevn/makevn.mk\n# incomplete old block\n' > "${repo}/Makefile"
printf 'outside content\n' > "${TMP}/outside"
ln -s "${TMP}/outside" "${repo}/GNUmakefile"
cp "${repo}/Makefile" "${TMP}/Makefile.before"
# All adoption/cleanup operations succeed without Python and never inspect Make.
PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" doctor --compact >/dev/null
PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" init --dry-run >/dev/null
[[ ! -e "${repo}/.makevn" ]]
PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" init >/dev/null
printf 'MAKEVN_LOCAL_CONTAINERS="custom"\n' >> "${repo}/.makevn/config"
cp "${repo}/.makevn/config" "${TMP}/config"
printf 'unknown local artifact\n' > "${repo}/.makevn/makevn.mk"
printf 'managed_makefile=../../outside\ngenerated_root_makefile=Makefile\n' >> "${repo}/.makevn/manifest"
printf 'old unreadable state\n' > "${repo}/.makevn/state.json"
for command in 'init --force' refresh 'profile refresh'; do
  PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" ${command} >/dev/null
  cmp "${repo}/Makefile" "${TMP}/Makefile.before"
  cmp "${repo}/.makevn/config" "${TMP}/config"
  [[ -L "${repo}/GNUmakefile" ]]
  [[ "$(cat "${TMP}/outside")" == 'outside content' ]]
  [[ "$(cat "${repo}/.makevn/makevn.mk")" == 'unknown local artifact' ]]
done
for subcommand in install uninstall; do
  for frontend in "${CLI}" "${ROOT_DIR}/target/release/makevn"; do
    if PATH="${TMP}/no-python" "${frontend}" --repo "${repo}" make "${subcommand}" >"${TMP}/out" 2>&1; then exit 1; fi
    grep -Fq 'Unknown command: make' "${TMP}/out"
    [[ -f "${repo}/.makevn/manifest" ]]
  done
done
PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" uninstall --dry-run >/dev/null
[[ -f "${repo}/.makevn/manifest" ]]
PATH="${TMP}/no-python" "${BASH_BIN}" "${CLI}" --repo "${repo}" uninstall >/dev/null
[[ ! -e "${repo}/.makevn" && -L "${repo}/GNUmakefile" ]]
cmp "${repo}/Makefile" "${TMP}/Makefile.before"
[[ "$(cat "${TMP}/outside")" == 'outside content' ]]
printf 'Standalone contract without Python tests passed\n'
