#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
readonly DOCKERHUB_SCRIPT="${REPOSITORY_DIR}/scripts/dockerhub-metadata.sh"
readonly GRYPE_SCRIPT="${REPOSITORY_DIR}/scripts/grype-scan.sh"
readonly GITHUB_RELEASE_SCRIPT="${REPOSITORY_DIR}/scripts/github-release.sh"
readonly FREE_DISK_SPACE_SCRIPT="${REPOSITORY_DIR}/scripts/free-disk-space.sh"
readonly FIXTURE_USERNAME='fixture-user'
readonly FIXTURE_TOKEN='fixture-token'
readonly FIXTURE_JWT='fixture-jwt'
readonly FIXTURE_REPOSITORY='fixture-org/fixture-image'
readonly FIXTURE_DESCRIPTION='fixture description'
readonly FIXTURE_FULL_DESCRIPTION='fixture full description'
readonly FIXTURE_VERSION='0.118.0'
readonly FIXTURE_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly EXIT_THRESHOLD=2

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/docker-tools.XXXXXX")
trap 'rm -r -- "${test_dir}"' EXIT

log() {
	local level=$1
	shift

	jq -cn \
		--arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg level "${level}" \
		--arg file "${BASH_SOURCE[1]##*/}" \
		--argjson line "${BASH_LINENO[0]}" \
		--arg func "${FUNCNAME[1]:-main}" \
		--arg msg "$*" \
		'{time: $time, level: $level, file: $file, line: $line, func: $func, msg: $msg}' >&2
}

fail() {
	log ERROR "$*"
	exit 1
}

assert_equals() {
	local expected=$1
	local actual=$2
	local context=$3

	if [[ "${actual}" != "${expected}" ]]; then
		fail "assertion failed context=${context} expected=${expected} actual=${actual}"
	fi
}

assert_file_absent() {
	local path=$1
	local context=$2

	if [[ -e "${path}" ]]; then
		fail "assertion failed context=${context} unexpected_path=${path}"
	fi
}

assert_file_contains() {
	local path=$1
	local expression=$2
	local context=$3

	if ! grep -Fqx -- "${expression}" "${path}"; then
		fail "assertion failed context=${context} expression=${expression}"
	fi
}

run_expected() {
	local expected_status=$1
	shift

	set +e
	"$@"
	local actual_status=$?
	set -e
	assert_equals "${expected_status}" "${actual_status}" "command exit status"
}

new_case() {
	local name=$1
	local case_dir="${test_dir}/${name}"

	mkdir -p "${case_dir}/bin"
	printf '%s\n' "${case_dir}"
}

write_metadata_curl_mock() {
	local case_dir=$1
	local mode=$2
	local metadata=$3

	cat >"${case_dir}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
readonly mode="${MOCK_CURL_MODE:?}"
readonly metadata="${MOCK_METADATA:?}"
readonly jwt="${MOCK_JWT:?}"

endpoint=''
method='GET'
for argument in "$@"; do
	case "${argument}" in
	https://*) endpoint="${argument}" ;;
	PATCH | POST) method="${argument}" ;;
	esac
done
printf '%s\n' "$@" >"${case_dir}/curl-args-${method}"

if [[ "${endpoint}" == */v2/users/login/ ]]; then
	cat >"${case_dir}/login-payload.json"
	if [[ "${mode}" == auth_failure ]]; then
		exit 22
	fi
	printf '{"token":"%s"}\n' "${jwt}"
	exit 0
fi

if [[ "${method}" == PATCH ]]; then
	cat >"${case_dir}/patch-payload.json"
	if [[ "${mode}" == patch_failure ]]; then
		exit 22
	fi
	exit 0
fi

if [[ "${mode}" == read_failure ]]; then
	exit 22
fi
printf '%s\n' "${metadata}"
MOCK
	chmod +x "${case_dir}/bin/curl"

	printf '%s\n' "${mode}" >"${case_dir}/mode"
	printf '%s\n' "${metadata}" >"${case_dir}/metadata"
}

run_metadata_case() {
	local case_dir=$1
	local repository=$2
	local want_private=$3
	local sync_description=$4
	local description_file=$5
	local expected_status=$6

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		MOCK_CURL_MODE="$(<"${case_dir}/mode")" \
		MOCK_METADATA="$(<"${case_dir}/metadata")" \
		MOCK_JWT="${FIXTURE_JWT}" \
		RUNNER_TEMP="${case_dir}" \
		LOG_FILE="${case_dir}/metadata.log" \
		DOCKERHUB_USERNAME="${FIXTURE_USERNAME}" \
		DOCKERHUB_TOKEN="${FIXTURE_TOKEN}" \
		REPOSITORY="${repository}" \
		WANT_PRIVATE="${want_private}" \
		SYNC_DESCRIPTION="${sync_description}" \
		SHORT_DESCRIPTION="${FIXTURE_DESCRIPTION}" \
		DESCRIPTION_FILE="${description_file}" \
		bash "${DOCKERHUB_SCRIPT}"
}

test_metadata_success() {
	local case_dir
	case_dir=$(new_case 'metadata-success')
	local description_file="${case_dir}/README.md"
	printf '%s' "${FIXTURE_FULL_DESCRIPTION}" >"${description_file}"
	write_metadata_curl_mock \
		"${case_dir}" \
		'success' \
		'{"is_private":false,"description":"fixture description","full_description":"fixture full description"}'

	run_metadata_case \
		"${case_dir}" \
		"${FIXTURE_REPOSITORY}" \
		false \
		true \
		"${description_file}" \
		0

	jq -e \
		--arg description "${FIXTURE_DESCRIPTION}" \
		--arg full_description "${FIXTURE_FULL_DESCRIPTION}" \
		'. == {is_private: false, description: $description, full_description: $full_description}' \
		"${case_dir}/patch-payload.json" >/dev/null || fail 'metadata success patch payload is wrong'
	assert_file_contains \
		"${case_dir}/curl-args-PATCH" \
		"https://hub.docker.com/v2/namespaces/fixture-org/repositories/fixture-image" \
		'metadata success modern endpoint'
	if grep -Fq -- "${FIXTURE_TOKEN}" "${case_dir}/curl-args-POST"; then
		fail 'metadata success leaked token through curl arguments'
	fi
}

test_metadata_visibility_only() {
	local case_dir
	case_dir=$(new_case 'metadata-visibility-only')
	write_metadata_curl_mock "${case_dir}" 'success' '{"is_private":true}'

	run_metadata_case \
		"${case_dir}" \
		"${FIXTURE_REPOSITORY}" \
		true \
		false \
		'' \
		0

	jq -e '. == {is_private: true}' "${case_dir}/patch-payload.json" >/dev/null ||
		fail 'metadata visibility only patch payload is wrong'
}

test_metadata_rejects_invalid_repository_before_network() {
	local case_dir
	case_dir=$(new_case 'metadata-invalid-repository')
	write_metadata_curl_mock "${case_dir}" 'success' '{"is_private":false}'

	run_metadata_case "${case_dir}" 'bad/repository/name' false false '' 1
	assert_file_absent "${case_dir}/curl-args-POST" 'metadata invalid repository must not authenticate'
}

test_metadata_fails_on_auth_patch_and_verification() {
	local mode
	for mode in auth_failure patch_failure read_failure; do
		local case_dir
		case_dir=$(new_case "metadata-${mode}")
		write_metadata_curl_mock "${case_dir}" "${mode}" '{"is_private":true}'

		run_metadata_case "${case_dir}" "${FIXTURE_REPOSITORY}" false false '' 1
	done
}

write_grype_mocks() {
	local case_dir=$1

	cat >"${case_dir}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
output_file=''
for ((index = 1; index <= $#; index++)); do
	if [[ "${!index}" == -o ]]; then
		next_index=$((index + 1))
		output_file="${!next_index}"
	fi
done
printf '%s\n' "$@" >"${case_dir}/grype-curl-args"
if [[ "${MOCK_DOWNLOAD_FAIL:-false}" == true ]]; then
	exit 22
fi
printf 'fixture tarball' >"${output_file}"
MOCK

	cat >"${case_dir}/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
cat >"${case_dir}/sha256-input"
if [[ "${MOCK_CHECKSUM_FAIL:-false}" == true ]]; then
	exit 1
fi
printf 'fixture tarball: OK\n'
MOCK

	cat >"${case_dir}/bin/tar" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
destination=''
for ((index = 1; index <= $#; index++)); do
	if [[ "${!index}" == -C ]]; then
		next_index=$((index + 1))
		destination="${!next_index}"
	fi
done
if [[ "${MOCK_EXTRACTION_FAIL:-false}" == true ]]; then
	exit 1
fi
cat >"${destination}/grype" <<'GRYPE'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
printf '%s\n' "$@" >"${case_dir}/grype-args"
output_file=''
for argument in "$@"; do
	case "${argument}" in
	sarif=*) output_file="${argument#sarif=}" ;;
	esac
done
if [[ "${MOCK_GRYPE_WRITES_SARIF:-true}" == true ]]; then
	printf '{"version":"2.1.0","runs":[]}' >"${output_file}"
fi
exit "${MOCK_GRYPE_STATUS:-0}"
GRYPE
chmod +x "${destination}/grype"
MOCK

	cat >"${case_dir}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
printf '%s\n' "$@" >"${case_dir}/docker-args"
cat >"${case_dir}/docker-stdin"
if [[ "${MOCK_DOCKER_LOGIN_FAIL:-false}" == true ]]; then
	exit 1
fi
MOCK

	cat >"${case_dir}/bin/uname" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "${MOCK_ARCH:-x86_64}"
MOCK

	chmod +x "${case_dir}/bin/curl" "${case_dir}/bin/sha256sum" "${case_dir}/bin/tar" "${case_dir}/bin/docker" "${case_dir}/bin/uname"
}

run_grype_case() {
	local case_dir=$1
	local fail_build=$2
	local expected_status=$3
	local grype_status=$4
	local checksum_fail=$5

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		RUNNER_TEMP="${case_dir}" \
		LOG_FILE="${case_dir}/grype.log" \
		GITHUB_OUTPUT="${case_dir}/github-output" \
		DOCKERHUB_USERNAME="${FIXTURE_USERNAME}" \
		DOCKERHUB_TOKEN="${FIXTURE_TOKEN}" \
		GRYPE_VERSION="${FIXTURE_VERSION}" \
		GRYPE_SHA256_LINUX_AMD64="${FIXTURE_SHA256}" \
		GRYPE_SHA256_LINUX_ARM64="${FIXTURE_SHA256}" \
		IMAGE='fixture-org/fixture-image:latest' \
		OUTPUT_FILE="${case_dir}/results.sarif" \
		SCAN_FAIL_BUILD="${fail_build}" \
		SCAN_SEVERITY='high' \
		MOCK_GRYPE_STATUS="${grype_status}" \
		MOCK_CHECKSUM_FAIL="${checksum_fail}" \
		bash "${GRYPE_SCRIPT}"
}

test_grype_success_and_threshold_behavior() {
	local case_dir
	case_dir=$(new_case 'grype-success')
	write_grype_mocks "${case_dir}"
	run_grype_case "${case_dir}" false 0 0 false
	assert_file_contains "${case_dir}/github-output" "sarif=${case_dir}/results.sarif" 'grype success GitHub output'
	assert_file_contains "${case_dir}/docker-args" 'login' 'grype success Docker login'
	if grep -Fq -- '--fail-on' "${case_dir}/grype-args"; then
		fail 'grype success unexpectedly enabled failure threshold'
	fi

	case_dir=$(new_case 'grype-threshold')
	write_grype_mocks "${case_dir}"
	run_grype_case "${case_dir}" true "${EXIT_THRESHOLD}" "${EXIT_THRESHOLD}" false
	assert_file_contains "${case_dir}/github-output" "sarif=${case_dir}/results.sarif" 'grype threshold GitHub output'
	assert_file_contains "${case_dir}/grype-args" '--fail-on' 'grype threshold parameter'
	assert_file_contains "${case_dir}/grype-args" 'high' 'grype threshold severity'
}

test_grype_stops_before_login_on_checksum_failure() {
	local case_dir
	case_dir=$(new_case 'grype-checksum-failure')
	write_grype_mocks "${case_dir}"
	run_grype_case "${case_dir}" false 1 0 true
	assert_file_absent "${case_dir}/docker-args" 'grype checksum failure must not log in'
	assert_file_absent "${case_dir}/grype-args" 'grype checksum failure must not execute scanner'
}

write_github_release_mocks() {
	local case_dir=$1

	cat >"${case_dir}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
readonly mode="${MOCK_RELEASE_MODE:?}"
readonly count_file="${case_dir}/gh-create-count"
printf '%s\n' "$@" >>"${case_dir}/gh-args"

if [[ "$1 $2" == 'release view' ]]; then
	case "${mode}" in
	published) printf 'false\n' ;;
	draft) printf 'true\n' ;;
	create_retry | create_failure) exit 1 ;;
	*) exit 1 ;;
	esac
	exit 0
fi

if [[ "$1 $2" == 'release edit' ]]; then
	[[ "${mode}" == draft ]]
	exit 0
fi

if [[ "$1 $2" == 'release create' ]]; then
	count=0
	if [[ -f "${count_file}" ]]; then
		count=$(<"${count_file}")
	fi
	count=$((count + 1))
	printf '%s\n' "${count}" >"${count_file}"
	if [[ "${mode}" == create_retry && "${count}" -ge 2 ]]; then
		exit 0
	fi
	exit 1
fi

exit 1
MOCK

	cat >"${case_dir}/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
MOCK

	chmod +x "${case_dir}/bin/gh" "${case_dir}/bin/sleep"
}

run_github_release_case() {
	local case_dir=$1
	local mode=$2
	local expected_status=$3

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		MOCK_RELEASE_MODE="${mode}" \
		RUNNER_TEMP="${case_dir}" \
		LOG_FILE="${case_dir}/github-release.log" \
		GH_TOKEN="${FIXTURE_TOKEN}" \
		GITHUB_REPOSITORY='fixture-org/fixture-repository' \
		GITHUB_REF_NAME='v1.2.3' \
		bash "${GITHUB_RELEASE_SCRIPT}"
}

test_github_release_idempotence_and_retry() {
	local mode
	for mode in published draft create_retry; do
		local case_dir
		case_dir=$(new_case "github-release-${mode}")
		write_github_release_mocks "${case_dir}"
		run_github_release_case "${case_dir}" "${mode}" 0

		case "${mode}" in
		published)
			if grep -Fqx -- 'create' "${case_dir}/gh-args"; then
				fail 'published GitHub release must not be recreated'
			fi
			;;
		draft) assert_file_contains "${case_dir}/gh-args" 'edit' 'GitHub release draft publish' ;;
		create_retry)
			assert_equals '2' "$(<"${case_dir}/gh-create-count")" 'GitHub release create retry count'
			;;
		esac
	done

	local failure_case
	failure_case=$(new_case 'github-release-failure')
	write_github_release_mocks "${failure_case}"
	run_github_release_case "${failure_case}" create_failure 1
	assert_equals '5' "$(<"${failure_case}/gh-create-count")" 'GitHub release create exhaustion count'
}

write_free_disk_space_mock() {
	local case_dir=$1

	cat >"${case_dir}/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
printf '%s\n' "$@" >>"${case_dir}/sudo-args"
if [[ "${MOCK_SUDO_FAIL:-false}" == true ]]; then
	exit 1
fi
MOCK

	chmod +x "${case_dir}/bin/sudo"
}

run_free_disk_space_case() {
	local case_dir=$1
	local runner_environment=$2
	local runner_os=$3
	local sudo_fail=$4
	local expected_status=$5

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		RUNNER_TEMP="${case_dir}" \
		LOG_FILE="${case_dir}/free-disk-space.log" \
		RUNNER_ENVIRONMENT="${runner_environment}" \
		RUNNER_OS="${runner_os}" \
		MOCK_SUDO_FAIL="${sudo_fail}" \
		bash "${FREE_DISK_SPACE_SCRIPT}"
}

test_free_disk_space_rejects_self_hosted_and_continues_optional_cleanup_failures() {
	local case_dir
	case_dir=$(new_case 'free-disk-space-self-hosted')
	write_free_disk_space_mock "${case_dir}"
	run_free_disk_space_case "${case_dir}" self-hosted Linux false 1
	assert_file_absent "${case_dir}/sudo-args" 'self-hosted disk cleanup must not run sudo'

	case_dir=$(new_case 'free-disk-space-non-linux')
	write_free_disk_space_mock "${case_dir}"
	run_free_disk_space_case "${case_dir}" github-hosted Windows false 1
	assert_file_absent "${case_dir}/sudo-args" 'non-Linux disk cleanup must not run sudo'

	case_dir=$(new_case 'free-disk-space-github-hosted')
	write_free_disk_space_mock "${case_dir}"
	run_free_disk_space_case "${case_dir}" github-hosted Linux true 0
	assert_file_contains "${case_dir}/sudo-args" 'rm' 'GitHub hosted disk cleanup removes runner tools'
	assert_file_contains "${case_dir}/sudo-args" 'apt-get' 'GitHub hosted disk cleanup removes packages'
	assert_file_contains "${case_dir}/sudo-args" 'docker' 'GitHub hosted disk cleanup removes images'
}

main() {
	test_metadata_success
	test_metadata_visibility_only
	test_metadata_rejects_invalid_repository_before_network
	test_metadata_fails_on_auth_patch_and_verification
	test_grype_success_and_threshold_behavior
	test_grype_stops_before_login_on_checksum_failure
	test_github_release_idempotence_and_retry
	test_free_disk_space_rejects_self_hosted_and_continues_optional_cleanup_failures
	log INFO 'docker tool command-boundary tests passed'
}

main "$@"
