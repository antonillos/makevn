#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
printf '<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>' > "${tmp}/pom.xml"
MAKEVN_FRONTEND_STATE_METADATA_OUT="${tmp}/state" MAKEVN_BACKEND_DETAIL_OUT="${tmp}/detail" "${ROOT}/bin/makevn" --repo "${tmp}" init > "${tmp}/output"
! grep -q 'makevn init' "${tmp}/output"
! grep -q 'makevn init' "${tmp}/detail"
grep -q 'created:' "${tmp}/detail"
grep -q 'Initialized makevn.' "${tmp}/output"
# Plain shell output keeps its standalone heading when there is no dashboard.
"${ROOT}/bin/makevn" --repo "${tmp}" init --force > "${tmp}/plain"
grep -q 'makevn init' "${tmp}/plain"
printf 'Init presentation tests passed\n'
