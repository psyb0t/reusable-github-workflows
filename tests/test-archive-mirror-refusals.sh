#!/bin/bash
# Run: bash tests/test-archive-mirror-refusals.sh
# Needs: bash, awk, jq. Executes workflow helpers with fake curl/git, no network.
set -euo pipefail
trap 'printf "command failed at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
work_directory=$(mktemp -d)
readonly work_directory
trap 'rm -r -- "${work_directory}"' EXIT

log() {
	printf '%s\n' "$1" >&2
}

# Execute the Save pages step, including its failure tally.
extract_helpers() {
	awk '
		index($0, "      - name: Save pages") { step = 1 }
		step && index($0, "        run: |") { inside = 1; next }
		inside && index($0, "  software-heritage:") == 1 { exit }
		inside { print substr($0, 11) }
	' "${REPOSITORY_DIR}/.github/workflows/archive.yml" >"${work_directory}/archive.sh"

	awk '
		index($0, "          report_push_quota() {") == 1 { inside = 1 }
		inside && index($0, "          if [ -z ") == 1 { exit }
		inside { print substr($0, 11) }
	' "${REPOSITORY_DIR}/.github/workflows/git-mirror.yml" >"${work_directory}/mirror.sh"
}

assert_contains() {
	if ! grep -Fq -- "$2" "$1"; then
		log "missing expected output: $2"
		cat "$1" >&2
		exit 1
	fi
}

run_archive() (
	export SOURCE=fixture/repo INCLUDE_HOMEPAGE=false EXTRA_URLS=''
	export CAPTURE_OUTLINKS=false CAPTURE_SCREENSHOT=false FAIL_ON_ERROR=true
	export MAX_ATTEMPTS=3 BACKOFF=0 URL_TIMEOUT=1
	export ACCESS_KEY=EXAMPLE-DO-NOT-USE SECRET_KEY=EXAMPLE-DO-NOT-USE
	# shellcheck disable=SC2329
	# The extracted workflow calls this command boundary stub.
	curl() {
		printf 'call\n' >>"${calls_file}"
		jq -nc --arg refusal "${refusal}" '{status: "error", status_ext: $refusal}'
		printf '\n200\n'
	}
	# shellcheck disable=SC2329
	# The extracted workflow calls this command boundary stub.
	sleep() {
		log "unexpected sleep"
		exit 99
	}
	# shellcheck disable=SC1091
	# The fixture is extracted from the workflow immediately before this call.
	source "${work_directory}/archive.sh"
)

archive_case() {
	local refusal="$1" want_exit="$2" annotation="$3" detail="$4"
	local calls_file="${work_directory}/archive.calls"
	local output="${work_directory}/archive.output" got_exit=0
	: >"${calls_file}"
	run_archive >"${output}" 2>&1 || got_exit=$?
	if [ "${got_exit}" -ne "${want_exit}" ] || [ "$(wc -l <"${calls_file}")" -ne 1 ]; then
		cat "${output}" >&2
		log "archive case ${refusal}: unexpected exit ${got_exit} or call count"
		exit 1
	fi
	assert_contains "${output}" "${annotation}"
	assert_contains "${output}" "${detail}"
	if [ "${want_exit}" -eq 0 ]; then
		assert_contains "${output}" 'requested 1 page(s), 0 did not confirm'
		if grep -Fq '::error::' "${output}"; then
			log 'unexpected archive error annotation'
			exit 1
		fi
	else
		assert_contains "${output}" '::error::1 page(s) were not archived and fail_on_error is true'
	fi
	log "passed: ${refusal}"
}

run_mirror() (
	MAX_ATTEMPTS=3 BACKOFF=0
	# shellcheck disable=SC1091
	# The fixture is extracted from the workflow immediately before this call.
	source "${work_directory}/mirror.sh"
	# shellcheck disable=SC2329
	# The extracted retry helper invokes git through its argument array.
	git() {
		printf 'call\n' >>"${calls_file}"
		printf '%s\n' "${push_output}" >&2
		if [ "${succeed_on_third}" = true ] && [ "$(wc -l <"${calls_file}")" -eq 3 ]; then
			return 0
		fi
		return 1
	}
	# shellcheck disable=SC2329
	# The extracted retry helper calls this command boundary stub.
	sleep() {
		printf '%s\n' "$1" >>"${sleeps_file}"
	}
	retry git push
)

mirror_case() {
	local push_output="$1" want_calls="$2" want_exit="$3" detail="$4"
	local succeed_on_third="${5:-false}"
	local calls_file="${work_directory}/mirror.calls"
	local sleeps_file="${work_directory}/mirror.sleeps"
	local output="${work_directory}/mirror.output" got_exit=0
	: >"${calls_file}"
	: >"${sleeps_file}"
	run_mirror >"${output}" 2>&1 || got_exit=$?
	if [ "${got_exit}" -ne "${want_exit}" ] || [ "$(wc -l <"${calls_file}")" -ne "${want_calls}" ] ||
		[ "$(wc -l <"${sleeps_file}")" -ne "$((want_calls - 1))" ]; then
		cat "${output}" >&2
		log "mirror case: unexpected exit ${got_exit}, call count, or sleep count"
		exit 1
	fi
	assert_contains "${output}" "${detail}"
	if [ "${want_calls}" -eq 1 ] && grep -Fq 'gave up after' "${output}"; then
		log 'quota rejection fell through to retry exhaustion'
		exit 1
	fi
	log "passed: ${push_output}"
}

main() {
	extract_helpers
	archive_case error:too-many-daily-captures-host 0 '::warning::' 'nothing was archived'
	archive_case error:too-many-daily-captures 0 '::notice::' "today's snapshots stand"
	archive_case error:blocked-url 1 '::warning::' 'returned no job'
	archive_case error:too-many-daily-captures-host-other 1 '::warning::' 'returned no job'
	archive_case '' 1 '::warning::' 'returned no job'
	mirror_case $'remote: Forgejo: Quota exceeded\n ! [remote rejected] main -> main (pre-receive hook declined)' \
		1 1 "::error::Codeberg (Forgejo): the account's storage quota is exhausted; free space or have the quota raised"
	mirror_case 'remote: Gitea: Quota exceeded' \
		1 1 "::error::Codeberg (Gitea): the account's storage quota is exhausted; free space or have the quota raised"
	mirror_case 'remote: pre-receive hook declined' 3 1 '::error::gave up after 3 attempt(s)'
	mirror_case 'fatal: connection reset' 3 0 'attempt 2 failed; retrying' true
	log 'archive and mirror refusal tests passed'
}

main "$@"
