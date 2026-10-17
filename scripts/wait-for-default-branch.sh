#!/usr/bin/env bash
# Waits for the default-branch push run of THIS SAME workflow file, for THIS
# SAME commit, to finish successfully. A tag is pushed moments after the
# commit it tags, so the matching push run can still be registering when this
# starts (APPEAR_GRACE_MINUTES), can still be in progress (TIMEOUT_MINUTES),
# or can have failed. Each is a different, clearly reported outcome. On
# success, writes run_id to GITHUB_OUTPUT so the caller can pull that run's
# artifacts (an image tag, a coverage file) instead of rebuilding.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/wait-for-default-branch.log}"
readonly DEFAULT_TIMEOUT_MINUTES=120
readonly DEFAULT_POLL_SECONDS=30
readonly DEFAULT_APPEAR_GRACE_MINUTES=10
readonly RUN_EVENT=push

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

require_env() {
	local name=$1
	if [[ -z "${!name:-}" ]]; then
		log ERROR "required environment variable is empty name=${name}"
		exit 1
	fi
}

exec > >(tee -a "${LOG_FILE}") 2>&1

# Minutes may be fractional (tests use e.g. 0.05 to keep real wait times
# short); awk does the float arithmetic, date -d/+ is not portable to BSD.
deadline_from_now() {
	local minutes=$1
	awk -v now="$(date -u '+%s')" -v m="${minutes}" 'BEGIN { printf "%d", now + (m * 60) }'
}

now_epoch() {
	date -u '+%s'
}

run_url() {
	local id=$1
	printf 'https://github.com/%s/actions/runs/%s' "${REPOSITORY}" "${id}"
}

# Echoes the id of the newest (by created_at) run of WORKFLOW_PATH on BRANCH
# for SHA, or nothing when there is none yet.
find_matching_run() {
	local response
	response=$(gh api "repos/${REPOSITORY}/actions/runs?head_sha=${SHA}&branch=${BRANCH}&event=${RUN_EVENT}&per_page=100")
	jq -r --arg path "${WORKFLOW_PATH}" \
		'[.workflow_runs[] | select(.path == $path)] | sort_by(.created_at) | last | .id // empty' \
		<<<"${response}"
}

# Sets RUN_STATUS and RUN_CONCLUSION from the current state of RUN_ID. A
# re-run of a run keeps the same id and its status/conclusion already reflect
# the latest attempt, so a plain re-fetch is always enough.
read_run_state() {
	local id=$1 response
	response=$(gh api "repos/${REPOSITORY}/actions/runs/${id}")
	RUN_STATUS=$(jq -r '.status' <<<"${response}")
	RUN_CONCLUSION=$(jq -r '.conclusion' <<<"${response}")
}

wait_for_run_to_appear() {
	local appear_grace_minutes=$1 deadline run_id
	deadline=$(deadline_from_now "${appear_grace_minutes}")

	while true; do
		run_id=$(find_matching_run)
		if [[ -n "${run_id}" ]]; then
			printf '%s' "${run_id}"
			return 0
		fi

		if ((($(now_epoch)) >= deadline)); then
			log ERROR "no ${BRANCH} push run of ${WORKFLOW_PATH} for ${SHA}; push the commit to ${BRANCH} before tagging it"
			return 1
		fi

		log DEBUG "default-branch run not registered yet repository=${REPOSITORY} branch=${BRANCH} sha=${SHA} path=${WORKFLOW_PATH}"
		sleep "${POLL_SECONDS}"
	done
}

wait_for_run_to_complete() {
	local run_id=$1 timeout_minutes=$2 deadline
	deadline=$(deadline_from_now "${timeout_minutes}")

	while true; do
		read_run_state "${run_id}"

		if [[ "${RUN_STATUS}" == completed ]]; then
			return 0
		fi

		if ((($(now_epoch)) >= deadline)); then
			log ERROR "timed out waiting for default-branch run to complete run_id=${run_id} status=${RUN_STATUS} run_url=$(run_url "${run_id}")"
			return 1
		fi

		log DEBUG "default-branch run still in progress run_id=${run_id} status=${RUN_STATUS}"
		sleep "${POLL_SECONDS}"
	done
}

main() {
	require_env GH_TOKEN
	require_env REPOSITORY
	require_env SHA
	require_env BRANCH
	require_env WORKFLOW_PATH

	local timeout_minutes="${TIMEOUT_MINUTES:-${DEFAULT_TIMEOUT_MINUTES}}"
	POLL_SECONDS="${POLL_SECONDS:-${DEFAULT_POLL_SECONDS}}"
	local appear_grace_minutes="${APPEAR_GRACE_MINUTES:-${DEFAULT_APPEAR_GRACE_MINUTES}}"

	local run_id
	run_id=$(wait_for_run_to_appear "${appear_grace_minutes}") || exit 1

	log INFO "found default-branch run repository=${REPOSITORY} branch=${BRANCH} sha=${SHA} path=${WORKFLOW_PATH} run_id=${run_id} run_url=$(run_url "${run_id}")"

	wait_for_run_to_complete "${run_id}" "${timeout_minutes}" || exit 1

	if [[ "${RUN_CONCLUSION}" != success ]]; then
		log ERROR "default-branch run did not succeed run_id=${run_id} conclusion=${RUN_CONCLUSION} run_url=$(run_url "${run_id}"); fix ${BRANCH} and re-run or re-tag"
		exit 1
	fi

	log INFO "default-branch run succeeded run_id=${run_id} run_url=$(run_url "${run_id}")"

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'run_id=%s\n' "${run_id}" >>"${GITHUB_OUTPUT}"
	fi
}

main "$@"
