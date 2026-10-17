#!/usr/bin/env bash
# Promotes an already-pushed per-commit tag to a release tag for one
# docker-image-workflow build target, without rebuilding. Used when
# `promote_on_tag: true`: the default-branch push run that built this commit
# (with `push_sha_tag: true`) already pushed every platform under the sha
# tag, and this re-points the release tag at the exact same manifests and
# digests via `docker buildx imagetools create`, so a tag release never
# re-executes a build.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/docker-promote.log}"
readonly MAX_ATTEMPTS=3
readonly RETRY_BASE_SECONDS=10

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

# Retries a transient registry/network failure. Not a substitute for the
# missing-source check below, which is a real, non-transient condition.
retry() {
	local attempt=1 delay
	while true; do
		if "$@"; then
			return 0
		fi

		if ((attempt >= MAX_ATTEMPTS)); then
			return 1
		fi

		delay=$((RETRY_BASE_SECONDS * (2 ** (attempt - 1))))
		log WARN "attempt ${attempt} failed, retrying in ${delay}s cmd=$*"
		sleep "${delay}"
		attempt=$((attempt + 1))
	done
}

main() {
	require_env REPOSITORY
	require_env RELEASE_TAG
	require_env SOURCE_SHA

	local tag_prefix="${TAG_PREFIX:-}" tag_suffix="${TAG_SUFFIX:-}"
	local source_tag dest_tag

	source_tag="${REPOSITORY}:${tag_prefix}sha-${SOURCE_SHA}${tag_suffix}"
	dest_tag="${REPOSITORY}:${tag_prefix}${RELEASE_TAG}${tag_suffix}"

	if ! retry docker buildx imagetools inspect "${source_tag}" >/dev/null; then
		log ERROR "source sha tag not found source=${source_tag}; the default-branch run must push it with push_sha_tag: true; use wait-for-default-branch.yml before this job"
		exit 1
	fi

	if ! retry docker buildx imagetools create --tag "${dest_tag}" "${source_tag}"; then
		log ERROR "promotion failed source=${source_tag} dest=${dest_tag}"
		exit 1
	fi

	log INFO "promoted image source=${source_tag} dest=${dest_tag}"
}

main "$@"
