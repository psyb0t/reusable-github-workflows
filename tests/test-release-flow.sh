#!/usr/bin/env bash
# Tests for the release-from-a-tag-without-rebuilding flow:
#   - scripts/wait-for-default-branch.sh (fake `gh` on PATH, no network)
#   - scripts/release-notes-release.sh (a real git repository in a temp dir,
#     a fake `gh` on PATH)
#
# Run: bash tests/test-release-flow.sh
# Needs: bash, jq, git. No token or network access.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
readonly WAIT_SCRIPT="${REPOSITORY_DIR}/scripts/wait-for-default-branch.sh"
readonly RELEASE_NOTES_SCRIPT="${REPOSITORY_DIR}/scripts/release-notes-release.sh"
readonly FIXTURE_REPOSITORY="fixture-org/fixture-repo"
readonly FIXTURE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
readonly FIXTURE_BRANCH="main"
readonly FIXTURE_WORKFLOW_PATH=".github/workflows/pipeline.yml"
readonly FIXTURE_OTHER_WORKFLOW_PATH=".github/workflows/other.yml"

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/release-flow.XXXXXX")
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

assert_file_contains() {
	local path=$1
	local expression=$2
	local context=$3

	if ! grep -Fq -- "${expression}" "${path}"; then
		fail "assertion failed context=${context} expression=${expression} path=${path}"
	fi
}

assert_file_absent() {
	local path=$1
	local context=$2

	if [[ -e "${path}" ]]; then
		fail "assertion failed context=${context} unexpected_path=${path}"
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

# ─────────────────────────────────────────────────────────────────────────
# wait-for-default-branch.sh
# ─────────────────────────────────────────────────────────────────────────

# Builds a fake `gh` that answers:
#   gh api "repos/.../actions/runs?...": the Nth call returns the Nth line of
#     LIST_RESPONSES (clamped to the last line once exhausted)
#   gh api "repos/.../actions/runs/<id>": the Nth call for that id returns the
#     Nth line of RUN_RESPONSES_<id> (same clamping)
write_wait_gh_mock() {
	local case_dir=$1

	cat >"${case_dir}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${TEST_CASE_DIR:?}"
url="$2"
printf '%s\n' "${url}" >>"${case_dir}/gh-calls"

if [[ "${url}" == *'/actions/runs?'* ]]; then
	count_file="${case_dir}/list-count"
	count=0
	[[ -f "${count_file}" ]] && count=$(<"${count_file}")
	count=$((count + 1))
	printf '%s\n' "${count}" >"${count_file}"

	response_file="${case_dir}/list-response-${count}"
	[[ -f "${response_file}" ]] || response_file="${case_dir}/list-response-last"
	cat "${response_file}"
	exit 0
fi

if [[ "${url}" == *'/actions/runs/'* ]]; then
	id="${url##*/}"
	count_file="${case_dir}/run-count-${id}"
	count=0
	[[ -f "${count_file}" ]] && count=$(<"${count_file}")
	count=$((count + 1))
	printf '%s\n' "${count}" >"${count_file}"

	response_file="${case_dir}/run-response-${id}-${count}"
	[[ -f "${response_file}" ]] || response_file="${case_dir}/run-response-${id}-last"
	cat "${response_file}"
	exit 0
fi

exit 1
MOCK
	chmod +x "${case_dir}/bin/gh"
}

list_response() {
	local -n _entries=$1
	jq -cn --argjson runs "$(printf '%s\n' "${_entries[@]}" | jq -cs '.')" '{workflow_runs: $runs}'
}

run_entry() {
	local id=$1 path=$2 created_at=$3
	jq -cn --argjson id "${id}" --arg path "${path}" --arg created_at "${created_at}" \
		'{id: $id, path: $path, created_at: $created_at}'
}

run_state_response() {
	local status=$1 conclusion=$2
	jq -cn --arg status "${status}" --arg conclusion "${conclusion}" '{status: $status, conclusion: $conclusion}'
}

run_wait_case() {
	local case_dir=$1 expected_status=$2
	shift 2

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		LOG_FILE="${case_dir}/wait.log" \
		GITHUB_OUTPUT="${case_dir}/github-output" \
		GH_TOKEN=fixture-token \
		REPOSITORY="${FIXTURE_REPOSITORY}" \
		SHA="${FIXTURE_SHA}" \
		BRANCH="${FIXTURE_BRANCH}" \
		WORKFLOW_PATH="${FIXTURE_WORKFLOW_PATH}" \
		POLL_SECONDS=0 \
		"$@" \
		bash "${WAIT_SCRIPT}"
}

test_wait_succeeds_immediately() {
	local case_dir
	case_dir=$(new_case 'wait-success')
	write_wait_gh_mock "${case_dir}"

	local entries=("$(run_entry 42 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')")
	list_response entries >"${case_dir}/list-response-last"
	run_state_response completed success >"${case_dir}/run-response-42-last"

	run_wait_case "${case_dir}" 0 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_contains "${case_dir}/github-output" 'run_id=42' 'immediate success writes run_id'
}

test_wait_in_progress_then_success() {
	local case_dir
	case_dir=$(new_case 'wait-in-progress-then-success')
	write_wait_gh_mock "${case_dir}"

	local entries=("$(run_entry 7 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')")
	list_response entries >"${case_dir}/list-response-last"
	run_state_response in_progress '' >"${case_dir}/run-response-7-1"
	run_state_response completed success >"${case_dir}/run-response-7-last"

	run_wait_case "${case_dir}" 0 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_contains "${case_dir}/github-output" 'run_id=7' 'in-progress-then-success writes run_id'
}

test_wait_fails_on_failed_conclusion() {
	local case_dir
	case_dir=$(new_case 'wait-failure')
	write_wait_gh_mock "${case_dir}"

	local entries=("$(run_entry 9 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')")
	list_response entries >"${case_dir}/list-response-last"
	run_state_response completed failure >"${case_dir}/run-response-9-last"

	run_wait_case "${case_dir}" 1 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_absent "${case_dir}/github-output" 'failed run must not write run_id'
}

test_wait_no_run_then_appears() {
	local case_dir
	case_dir=$(new_case 'wait-appears')
	write_wait_gh_mock "${case_dir}"

	local empty=()
	list_response empty >"${case_dir}/list-response-1"
	local entries=("$(run_entry 11 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')")
	list_response entries >"${case_dir}/list-response-last"
	run_state_response completed success >"${case_dir}/run-response-11-last"

	run_wait_case "${case_dir}" 0 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_contains "${case_dir}/github-output" 'run_id=11' 'run appearing on a later poll still succeeds'
}

test_wait_no_run_ever_fails_after_grace() {
	local case_dir
	case_dir=$(new_case 'wait-never-appears')
	write_wait_gh_mock "${case_dir}"

	# shellcheck disable=SC2034 # read through list_response's `local -n` nameref parameter
	local empty=()
	list_response empty >"${case_dir}/list-response-last"

	# Fractional minutes keep this test well under a couple of seconds.
	run_wait_case "${case_dir}" 1 APPEAR_GRACE_MINUTES=0.02 TIMEOUT_MINUTES=1
	assert_file_absent "${case_dir}/github-output" 'a run that never appears must not write run_id'
}

test_wait_ignores_other_workflow_runs() {
	local case_dir
	case_dir=$(new_case 'wait-other-workflow')
	write_wait_gh_mock "${case_dir}"

	local entries=(
		"$(run_entry 1 "${FIXTURE_OTHER_WORKFLOW_PATH}" '2026-01-01T00:00:05Z')"
		"$(run_entry 2 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')"
	)
	list_response entries >"${case_dir}/list-response-last"
	run_state_response completed success >"${case_dir}/run-response-2-last"

	run_wait_case "${case_dir}" 0 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_contains "${case_dir}/github-output" 'run_id=2' 'a run of a different workflow path must be ignored'
}

test_wait_newest_run_wins() {
	local case_dir
	case_dir=$(new_case 'wait-newest-wins')
	write_wait_gh_mock "${case_dir}"

	# shellcheck disable=SC2034 # read through list_response's `local -n` nameref parameter
	local entries=(
		"$(run_entry 100 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:00:00Z')"
		"$(run_entry 200 "${FIXTURE_WORKFLOW_PATH}" '2026-01-01T00:05:00Z')"
	)
	list_response entries >"${case_dir}/list-response-last"
	run_state_response completed success >"${case_dir}/run-response-200-last"
	run_state_response completed failure >"${case_dir}/run-response-100-last"

	run_wait_case "${case_dir}" 0 APPEAR_GRACE_MINUTES=1 TIMEOUT_MINUTES=1
	assert_file_contains "${case_dir}/github-output" 'run_id=200' 'the newest matching run by created_at must win'
}

# ─────────────────────────────────────────────────────────────────────────
# release-notes-release.sh
# ─────────────────────────────────────────────────────────────────────────

write_release_notes_gh_mock() {
	local case_dir=$1
	local release_exists=$2

	cat >"${case_dir}/bin/gh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail

readonly case_dir="${case_dir}"
readonly release_exists="${release_exists}"
printf '%s\n' "\$@" >>"\${case_dir}/gh-args"

if [[ "\$1 \$2" == 'release view' ]]; then
	[[ "\${release_exists}" == true ]]
	exit \$?
fi

if [[ "\$1 \$2" == 'release create' || "\$1 \$2" == 'release edit' ]]; then
	for ((i = 1; i <= \$#; i++)); do
		if [[ "\${!i}" == '--notes-file' ]]; then
			j=\$((i + 1))
			cp "\${!j}" "\${case_dir}/captured-notes.txt"
		fi
	done
	exit 0
fi

exit 1
MOCK
	chmod +x "${case_dir}/bin/gh"
}

# A real repository with a real "origin" remote (actions/checkout's own
# setup), so `git fetch --force origin refs/tags/<t>:refs/tags/<t>` has
# something real to fetch from.
new_git_case() {
	local name=$1
	local case_dir
	case_dir=$(new_case "${name}")

	local origin="${case_dir}/origin.git"
	git init -q --bare "${origin}"

	local work="${case_dir}/work"
	git clone -q "${origin}" "${work}"
	git -C "${work}" config user.email 'tester@example.com'
	git -C "${work}" config user.name 'tester'
	printf 'fixture\n' >"${work}/README.md"
	git -C "${work}" add README.md
	git -C "${work}" commit -q -m 'initial commit'
	git -C "${work}" push -q origin HEAD

	printf '%s\n' "${case_dir}"
}

run_release_notes_case() {
	local case_dir=$1 work=$2 tag=$3 changelog_file=$4 expected_status=$5

	run_expected "${expected_status}" env \
		PATH="${case_dir}/bin:${PATH}" \
		TEST_CASE_DIR="${case_dir}" \
		LOG_FILE="${case_dir}/release-notes.log" \
		GH_TOKEN=fixture-token \
		TAG="${tag}" \
		CHANGELOG_FILE="${changelog_file}" \
		PRERELEASE_MATCH='(alpha|beta|rc)' \
		bash -c "cd '${work}' && exec bash '${RELEASE_NOTES_SCRIPT}'"
}

test_release_notes_from_annotated_tag_body() {
	local case_dir work
	case_dir=$(new_git_case 'release-tag-body')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" false

	git -C "${work}" tag -a v1.0.0 -m v1.0.0 -m 'first release notes line' -m 'second line'
	git -C "${work}" push -q origin v1.0.0

	run_release_notes_case "${case_dir}" "${work}" v1.0.0 '' 0
	assert_file_contains "${case_dir}/gh-args" '--notes-file' 'annotated body release uses notes-file'
	assert_file_absent "${case_dir}/gh-args-generate" 'sanity: no stray marker file'
	if ! grep -Fq 'first release notes line' "${case_dir}/captured-notes.txt"; then
		fail 'annotated tag body did not reach the release notes'
	fi
	if grep -Fq -- '--generate-notes' "${case_dir}/gh-args"; then
		fail 'annotated tag body release must not fall back to --generate-notes'
	fi
}

test_release_notes_empty_annotated_body_falls_back() {
	local case_dir work
	case_dir=$(new_git_case 'release-empty-body')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" false

	git -C "${work}" tag -a v1.0.1 -m v1.0.1
	git -C "${work}" push -q origin v1.0.1

	run_release_notes_case "${case_dir}" "${work}" v1.0.1 '' 0
	assert_file_contains "${case_dir}/gh-args" '--generate-notes' 'empty annotated body falls back to generated notes'
}

test_release_notes_lightweight_tag_generates() {
	local case_dir work
	case_dir=$(new_git_case 'release-lightweight')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" false

	git -C "${work}" tag v1.0.2
	git -C "${work}" push -q origin v1.0.2

	run_release_notes_case "${case_dir}" "${work}" v1.0.2 '' 0
	assert_file_contains "${case_dir}/gh-args" '--generate-notes' 'lightweight tag must use generated notes'
}

test_release_notes_changelog_file_wins() {
	local case_dir work
	case_dir=$(new_git_case 'release-changelog-wins')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" false

	git -C "${work}" tag -a v1.0.3 -m v1.0.3 -m 'tag body that must be ignored'
	git -C "${work}" push -q origin v1.0.3
	printf 'changelog body wins\n' >"${work}/CHANGELOG.md"

	run_release_notes_case "${case_dir}" "${work}" v1.0.3 CHANGELOG.md 0
	assert_file_contains "${case_dir}/captured-notes.txt" 'changelog body wins' 'changelog_file must win over the tag body'
	if grep -Fq 'tag body that must be ignored' "${case_dir}/captured-notes.txt"; then
		fail 'changelog_file must win over the tag body'
	fi
}

test_release_notes_existing_release_edited_only_for_owned_sources() {
	local case_dir work
	case_dir=$(new_git_case 'release-existing-tag-body')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" true

	git -C "${work}" tag -a v1.0.4 -m v1.0.4 -m 'repair this body'
	git -C "${work}" push -q origin v1.0.4

	run_release_notes_case "${case_dir}" "${work}" v1.0.4 '' 0
	assert_file_contains "${case_dir}/gh-args" 'edit' 'an existing release must be repaired when notes came from the tag body'
	if grep -Fqx -- 'create' "${case_dir}/gh-args"; then
		fail 'an existing release must not be recreated'
	fi

	case_dir=$(new_git_case 'release-existing-generated')
	work="${case_dir}/work"
	write_release_notes_gh_mock "${case_dir}" true

	git -C "${work}" tag v1.0.5
	git -C "${work}" push -q origin v1.0.5

	run_release_notes_case "${case_dir}" "${work}" v1.0.5 '' 0
	if grep -Fqx -- 'edit' "${case_dir}/gh-args"; then
		fail 'an existing release must be left alone when notes would come from --generate-notes'
	fi
	assert_file_absent "${case_dir}/captured-notes.txt" 'no notes file is written when the release is left alone'
}

main() {
	test_wait_succeeds_immediately
	test_wait_in_progress_then_success
	test_wait_fails_on_failed_conclusion
	test_wait_no_run_then_appears
	test_wait_no_run_ever_fails_after_grace
	test_wait_ignores_other_workflow_runs
	test_wait_newest_run_wins

	test_release_notes_from_annotated_tag_body
	test_release_notes_empty_annotated_body_falls_back
	test_release_notes_lightweight_tag_generates
	test_release_notes_changelog_file_wins
	test_release_notes_existing_release_edited_only_for_owned_sources

	log INFO 'release flow tests passed'
}

main "$@"
