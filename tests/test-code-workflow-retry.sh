#!/usr/bin/env bash
# Tests for the retry helper code-workflow.yml writes in its "Prepare retry
# helper" step. The helper is read out of the workflow file itself, so the test
# covers the exact text a run would execute.
#
# Run: bash tests/test-code-workflow-retry.sh
# Needs: bash, awk. No token or network access.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_DIR
readonly WORKFLOW="${REPOSITORY_DIR}/.github/workflows/code-workflow.yml"
readonly HELPER_START="<<'HELPER'"
readonly HELPER_END="HELPER"
readonly FAILURE_EXIT=7

failures=0
work_directory="$(mktemp -d)"
readonly work_directory
trap 'rm -r -- "${work_directory}"' EXIT

log() {
	local level="$1"
	shift

	printf '{"time":"%s","level":"%s","file":"%s","line":%d,"func":"%s","msg":"%s"}\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')" \
		"${level}" \
		"${BASH_SOURCE[1]##*/}" \
		"${BASH_LINENO[0]}" \
		"${FUNCNAME[1]:-main}" \
		"$*" >&2
}

# extract_helper writes the heredoc body between <<'HELPER' and HELPER,
# with the YAML block indentation removed.
extract_helper() {
	awk -v start="${HELPER_START}" -v end="${HELPER_END}" '
		index($0, start) { inside = 1; indent = ""; next }
		inside && $0 ~ "^[[:space:]]*" end "$" { exit }
		inside {
			if (indent == "") {
				match($0, /^[[:space:]]*/)
				indent = substr($0, 1, RLENGTH)
			}
			sub("^" indent, "")
			print
		}
	' "${WORKFLOW}" >"${work_directory}/run-with-retry.sh"

	if ! grep -q '^run_with_retry()' "${work_directory}/run-with-retry.sh"; then
		log ERROR "could not extract the retry helper from ${WORKFLOW}"
		exit 1
	fi
}

# run_case NAME MAX_ATTEMPTS COMMAND WANT_EXIT WANT_CALLS: runs the helper in a
# fresh shell and checks its exit code and how many times COMMAND ran. COMMAND
# appends a line to CALLS_FILE on every run.
run_case() {
	local name="$1"
	local max_attempts="$2"
	local command="$3"
	local want_exit="$4"
	local want_calls="$5"
	local calls_file="${work_directory}/${name}.calls"
	local got_exit=0
	local got_calls

	: >"${calls_file}"

	CALLS_FILE="${calls_file}" MAX_ATTEMPTS="${max_attempts}" BACKOFF_SECONDS=0 \
		bash -c 'set -euo pipefail
			source "$1"
			run_with_retry "$2" "$3"' \
		_ "${work_directory}/run-with-retry.sh" "${name}" "${command}" \
		>/dev/null 2>&1 || got_exit=$?

	got_calls="$(wc -l <"${calls_file}" | tr -d ' ')"

	if [ "${got_exit}" != "${want_exit}" ] || [ "${got_calls}" != "${want_calls}" ]; then
		log ERROR "case ${name}: exit ${got_exit} calls ${got_calls}, want exit ${want_exit} calls ${want_calls}"
		failures=$((failures + 1))
		return
	fi

	log INFO "case ${name}: passed"
}

# The case commands stay single-quoted on purpose: they expand inside the
# helper's shell, where CALLS_FILE is set, not here.
# shellcheck disable=SC2016
main() {
	extract_helper

	run_case first-try-passes 5 'echo run >>"${CALLS_FILE}"' 0 1
	run_case passes-on-third-try 5 \
		'echo run >>"${CALLS_FILE}"; [ "$(wc -l <"${CALLS_FILE}")" -ge 3 ]' 0 3
	run_case always-fails 5 \
		"echo run >>\"\${CALLS_FILE}\"; exit ${FAILURE_EXIT}" "${FAILURE_EXIT}" 5
	run_case one-attempt-means-no-retry 1 \
		"echo run >>\"\${CALLS_FILE}\"; exit ${FAILURE_EXIT}" "${FAILURE_EXIT}" 1
	run_case pipeline-failure-counts 2 \
		'echo run >>"${CALLS_FILE}"; false | true' 1 2
	run_case stops-at-first-failing-command 1 \
		'echo run >>"${CALLS_FILE}"; false; echo after >>"${CALLS_FILE}"' 1 1

	if [ "${failures}" -ne 0 ]; then
		log ERROR "retry helper tests failed count=${failures}"
		exit 1
	fi

	log INFO "retry helper tests passed"
}

main "$@"
