#!/usr/bin/env bash
set -euo pipefail

readonly MAX_ATTEMPTS=5
readonly RETRY_DELAY_SECONDS=1
readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/github-release.log}"

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

release_state() {
	gh release view "${GITHUB_REF_NAME}" --json isDraft --jq '.isDraft'
}

publish_draft() {
	gh release edit "${GITHUB_REF_NAME}" --draft=false >/dev/null
}

create_release() {
	gh release create "${GITHUB_REF_NAME}" --verify-tag >/dev/null
}

exec > >(tee -a "${LOG_FILE}") 2>&1

require_env GH_TOKEN
require_env GITHUB_REF_NAME
require_env GITHUB_REPOSITORY

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
	if state=$(release_state); then
		case "${state}" in
		false)
			log INFO "GitHub release already published repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME}"
			exit 0
			;;
		true)
			log WARN "GitHub release draft exists repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempt=${attempt}"
			if publish_draft; then
				log INFO "GitHub release draft published repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME}"
				exit 0
			fi
			log WARN "GitHub release draft publish failed repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempt=${attempt}"
			;;
		*)
			log ERROR "GitHub release state is invalid repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} state=${state}"
			exit 1
			;;
		esac
	else
		log DEBUG "GitHub release does not exist or could not be read repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempt=${attempt}"
		if create_release; then
			log INFO "GitHub release created repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME}"
			exit 0
		fi
		log WARN "GitHub release create failed repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempt=${attempt}"
	fi

	if ((attempt < MAX_ATTEMPTS)); then
		log INFO "retrying GitHub release repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempt=${attempt}"
		sleep "${RETRY_DELAY_SECONDS}"
	fi
done

log ERROR "GitHub release could not be published repository=${GITHUB_REPOSITORY} tag=${GITHUB_REF_NAME} attempts=${MAX_ATTEMPTS}"
exit 1
