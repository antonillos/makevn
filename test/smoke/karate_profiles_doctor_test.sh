#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/src/main/java" "${tmp}/.github/workflows"
printf '<project><modelVersion>4.0.0</modelVersion><groupId>example</groupId><artifactId>app</artifactId><version>1</version></project>\n' > "${tmp}/pom.xml"
printf 'public class Application { public static void main(String[] args) {} }\n' > "${tmp}/src/main/java/Application.java"
printf 'SPRING_PROFILES_ACTIVE: standalone,local\n' > "${tmp}/.github/workflows/karate.yml"
"${ROOT_DIR}/bin/makevn" --repo "${tmp}" init > /dev/null
printf 'MAKEVN_APP_HEALTH_URL="http://localhost/health"\n' >> "${tmp}/.makevn/config"
cp "${tmp}/.makevn/config" "${tmp}/original"
python3 "${ROOT_DIR}/test/smoke/doctor_health_prompt_test.py" "${ROOT_DIR}/bin/makevn" "${tmp}" "${tmp}/out" '[["Karate profiles [standalone,local]", ""]]'
grep -q '^MAKEVN_KARATE_APP_PROFILES=standalone\\,local$' "${tmp}/.makevn/config"
python3 "${ROOT_DIR}/test/smoke/doctor_health_prompt_test.py" "${ROOT_DIR}/bin/makevn" "${tmp}" "${tmp}/out" '[]'
! grep -q 'Karate profiles \[' "${tmp}/out"
cp "${tmp}/original" "${tmp}/.makevn/config"
python3 "${ROOT_DIR}/test/smoke/doctor_health_prompt_test.py" "${ROOT_DIR}/bin/makevn" "${tmp}" "${tmp}/out" '[["Karate profiles [standalone,local]", "edited,local"]]'
grep -q 'edited' "${tmp}/.makevn/config"
cp "${tmp}/original" "${tmp}/.makevn/config"
python3 "${ROOT_DIR}/test/smoke/doctor_health_prompt_test.py" "${ROOT_DIR}/bin/makevn" "${tmp}" "${tmp}/out" '[["Karate profiles [standalone,local]", "skip"]]'
cmp "${tmp}/original" "${tmp}/.makevn/config"
bash "${ROOT_DIR}/libexec/makevn/backend.sh" doctor --repo "${tmp}" --format json > "${tmp}/doctor.json"
python3 - "${tmp}/doctor.json" <<'PY'
import json,sys
result = json.load(open(sys.argv[1]))
# The machine-readable snapshot contains the same effective profiles and source.
def find(value):
    if isinstance(value, dict):
        if 'karate_app_profiles' in value: return value
        for item in value.values():
            found = find(item)
            if found: return found
snapshot = find(result)
assert snapshot['karate_app_profiles'] == 'standalone,local', result
assert 'karate.yml' in snapshot['karate_app_profiles_source'], result
PY
"${ROOT_DIR}/bin/makevn" --repo "${tmp}" profile refresh > "${tmp}/profile.out"
grep -q 'MAKEVN_PROFILE_KARATE_APP_PROFILES=' "${tmp}/.makevn/profile.env"
printf 'Karate profiles doctor PTY tests passed\n'
