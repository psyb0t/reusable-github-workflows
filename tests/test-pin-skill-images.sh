#!/usr/bin/env bash
# Tests scripts/pin-skill-images.sh against a file:// stand-in for the Docker
# Hub API.
#
# Run: bash tests/test-pin-skill-images.sh
# Needs: Bash, curl, jq and python3. No token or network.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="${SCRIPT_DIR}/../scripts/pin-skill-images.sh"
readonly DIGEST='sha256:1111111111111111111111111111111111111111111111111111111111111111'
readonly OTHER_DIGEST='sha256:2222222222222222222222222222222222222222222222222222222222222222'

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pin-skill-images.XXXXXX")
trap 'rm -r -- "${test_dir}"' EXIT
failures=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

api() {
	local namespace=$1 name=$2 tag=$3 digest=$4
	mkdir -p "${test_dir}/api/namespaces/${namespace}/repositories/${name}/tags"
	printf '{"name":"%s","digest":"%s"}' "${tag}" "${digest}" \
		>"${test_dir}/api/namespaces/${namespace}/repositories/${name}/tags/${tag}"
}

api fixture tool v1.2.3 "${DIGEST}"
api fixture tool-extra v1.2.3 "${OTHER_DIGEST}"
export DOCKERHUB_API_URL="file://${test_dir}/api"
export BACKOFF_SECONDS=0

skill="${test_dir}/skills/tool"
mkdir -p "${skill}/references"
cat >"${skill}/SKILL.md" <<'EOF'
docker run --rm fixture/tool version
docker run fixture/tool:latest serve
image: "fixture/tool"
`fixture/tool`
docker pull fixture/tool:v1.0.0
docker pull fixture/tool@sha256:abc
docker run fixture/tool:latest-ffmpeg
https://hub.docker.com/r/fixture/tool
https://github.com/fixture/tool/blob/main/README.md
other/fixture/tool
fixture/tool-extra:latest
fixture/toolbox
EOF
printf 'FROM fixture/tool\n' >"${skill}/references/setup.md"
printf '\xff\xfe binary' >"${skill}/references/blob.bin"
cp "${skill}/references/blob.bin" "${test_dir}/blob.orig"

bash "${SCRIPT}" v1.2.3 '["fixture/tool","fixture/tool-extra"]' "${skill}" 2>/dev/null

pinned="fixture/tool:v1.2.3@${DIGEST}"
expected="docker run --rm ${pinned} version
docker run ${pinned} serve
image: \"${pinned}\"
\`${pinned}\`
docker pull fixture/tool:v1.0.0
docker pull fixture/tool@sha256:abc
docker run fixture/tool:latest-ffmpeg
https://hub.docker.com/r/fixture/tool
https://github.com/fixture/tool/blob/main/README.md
other/fixture/tool
fixture/tool-extra:v1.2.3@${OTHER_DIGEST}
fixture/toolbox"
[ "$(cat "${skill}/SKILL.md")" = "${expected}" ] || fail "SKILL.md was not pinned as expected: $(cat "${skill}/SKILL.md")"
[ "$(cat "${skill}/references/setup.md")" = "FROM ${pinned}" ] || fail 'nested reference was not pinned'
cmp -s "${skill}/references/blob.bin" "${test_dir}/blob.orig" || fail 'binary file changed'

if bash "${SCRIPT}" v9.9.9 '["fixture/tool"]' "${skill}" 2>/dev/null; then
	fail 'a tag without a Docker Hub digest was accepted'
fi
if bash "${SCRIPT}" 'bad tag' '["fixture/tool"]' "${skill}" 2>/dev/null; then
	fail 'an invalid tag was accepted'
fi
if bash "${SCRIPT}" v1.2.3 '["Fixture/Tool"]' "${skill}" 2>/dev/null; then
	fail 'an invalid image name was accepted'
fi
if bash "${SCRIPT}" v1.2.3 '"fixture/tool"' "${skill}" 2>/dev/null; then
	fail 'a non-array image list was accepted'
fi
if bash "${SCRIPT}" v1.2.3 '["fixture/tool"]' "${test_dir}/missing" 2>/dev/null; then
	fail 'a missing skill directory was accepted'
fi
urls="${test_dir}/skills/urls"
mkdir -p "${urls}"
cat >"${urls}/SKILL.md" <<'MARKDOWN'
curl -fsSL https://raw.githubusercontent.com/fixture/tool/main/install.sh -o install.sh
https://raw.githubusercontent.com/fixture/tool/master/scripts/run.sh
https://github.com/fixture/tool/raw/HEAD/install.sh
https://raw.githubusercontent.com/fixture/tool/v1.0.0/install.sh
https://raw.githubusercontent.com/fixture/tool-other/main/install.sh
https://raw.githubusercontent.com/other/tool/main/install.sh
MARKDOWN
SOURCE_REPO=fixture/tool bash "${SCRIPT}" v1.2.3 '[]' "${urls}" 2>/dev/null || fail 'source URL pinning failed'
expected_urls='curl -fsSL https://raw.githubusercontent.com/fixture/tool/v1.2.3/install.sh -o install.sh
https://raw.githubusercontent.com/fixture/tool/v1.2.3/scripts/run.sh
https://github.com/fixture/tool/raw/v1.2.3/install.sh
https://raw.githubusercontent.com/fixture/tool/v1.0.0/install.sh
https://raw.githubusercontent.com/fixture/tool-other/main/install.sh
https://raw.githubusercontent.com/other/tool/main/install.sh'
[ "$(cat "${urls}/SKILL.md")" = "${expected_urls}" ] || fail "source URLs were not pinned as expected: $(cat "${urls}/SKILL.md")"
if SOURCE_REPO='not a repo' bash "${SCRIPT}" v1.2.3 '[]' "${urls}" 2>/dev/null; then
	fail 'an invalid SOURCE_REPO was accepted'
fi

before="$(cat "${skill}/SKILL.md")"
bash "${SCRIPT}" v1.2.3 '[]' "${skill}" 2>/dev/null || fail 'an empty image list failed'
[ "$(cat "${skill}/SKILL.md")" = "${before}" ] || fail 'an empty image list changed files'

if [ "${failures}" -ne 0 ]; then
	printf '%d failure(s)\n' "${failures}" >&2
	exit 1
fi
echo 'pin-skill-images: all checks passed'
