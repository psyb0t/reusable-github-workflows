#!/usr/bin/env bash
# Push an Apify Actor and wait for its build. Called by apify-publish.yml.
#
# Environment:
#   APIFY_TOKEN      required; read by the apify CLI
#   ACTOR_DIR        directory holding .actor/actor.json (default .)
#   RELEASE_TAG      release tag such as v1.2.3; sets the Actor version
#   ACTOR_VERSION    explicit Actor version (MAJOR.MINOR); wins over RELEASE_TAG
#   BUILD_TAG        build tag applied to a successful build (default latest)
#   BASE_IMAGE       optional image such as psyb0t/app; when set, the Actor
#                    Dockerfile's FROM line for it is pinned to
#                    BASE_IMAGE:BASE_IMAGE_TAG@<digest> before the push
#   BASE_IMAGE_TAG   tag of BASE_IMAGE to pin (default RELEASE_TAG)
#   WAIT_SECONDS     how long to wait for the build (default 3600)
#   MAX_ATTEMPTS     push attempts (default 4)
#   BACKOFF_SECONDS  wait before the second push attempt, doubled after each
#                    failure (default 30)
#   APIFY_BIN, DOCKER_BIN  overridable for tests
set -euo pipefail

readonly DEFAULT_ACTOR_DIR='.'
readonly DEFAULT_BUILD_TAG='latest'
readonly DEFAULT_WAIT_SECONDS=3600
readonly DEFAULT_MAX_ATTEMPTS=4
readonly DEFAULT_BACKOFF_SECONDS=30
readonly ACTOR_JSON='.actor/actor.json'
readonly SEMVER_TAG_RE='^v?([0-9]+)\.([0-9]+)\.[0-9]+([-+].*)?$'
readonly ACTOR_VERSION_RE='^[0-9]+\.[0-9]+$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'

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

# actor_version prints MAJOR.MINOR from ACTOR_VERSION or RELEASE_TAG.
actor_version() {
	local explicit=$1 tag=$2

	if [[ -n "${explicit}" ]]; then
		if [[ ! "${explicit}" =~ ${ACTOR_VERSION_RE} ]]; then
			log ERROR "ACTOR_VERSION must be MAJOR.MINOR value=${explicit}"
			return 1
		fi
		printf '%s\n' "${explicit}"
		return 0
	fi
	if [[ "${tag}" =~ ${SEMVER_TAG_RE} ]]; then
		printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi
	log ERROR "cannot derive an Actor version: set ACTOR_VERSION or use a vX.Y.Z tag tag=${tag}"
	return 1
}

# dockerfile_path prints the Dockerfile the platform builds: the "dockerfile"
# field of actor.json (relative to .actor/), else .actor/Dockerfile, else
# Dockerfile, the order the platform documents.
dockerfile_path() {
	local dir=$1 configured

	configured="$(jq -r '.dockerfile // empty' "${dir}/${ACTOR_JSON}")"
	if [[ -n "${configured}" ]]; then
		printf '%s\n' "${dir}/.actor/${configured}"
		return 0
	fi
	if [[ -f "${dir}/.actor/Dockerfile" ]]; then
		printf '%s\n' "${dir}/.actor/Dockerfile"
		return 0
	fi
	printf '%s\n' "${dir}/Dockerfile"
}

# resolve_digest prints the manifest digest of IMAGE:TAG.
resolve_digest() {
	local reference=$1 digest

	digest="$("${DOCKER_BIN}" buildx imagetools inspect "${reference}" --format '{{json .Manifest}}' |
		jq -r '.digest // empty')"
	if [[ ! "${digest}" =~ ${DIGEST_RE} ]]; then
		log ERROR "could not resolve a digest reference=${reference}"
		return 1
	fi
	printf '%s\n' "${digest}"
}

# pin_base_image rewrites every FROM line that names IMAGE (with any tag or
# digest) to IMAGE:TAG@DIGEST. Fails when no FROM line names IMAGE.
pin_base_image() {
	local dockerfile=$1 image=$2 tag=$3 digest=$4 pinned tmp

	if [[ ! -f "${dockerfile}" ]]; then
		log ERROR "Dockerfile not found path=${dockerfile}"
		return 1
	fi
	pinned="${image}:${tag}@${digest}"
	tmp="$(mktemp)"
	awk -v image="${image}" -v pinned="${pinned}" '
		BEGIN { found = 0 }
		{
			if (toupper($1) == "FROM") {
				for (i = 2; i <= NF; i++) {
					if ($i ~ /^--/) continue
					ref = $i
					sub(/@.*/, "", ref)
					base = ref
					if (match(ref, /:[^\/]*$/)) base = substr(ref, 1, RSTART - 1)
					if (base == image) { $i = pinned; found = 1 }
					break
				}
			}
			print
		}
		END { if (!found) exit 3 }
	' "${dockerfile}" >"${tmp}" || {
		local status=$?
		rm -f "${tmp}"
		if [[ ${status} -eq 3 ]]; then
			log ERROR "no FROM line names the base image image=${image} dockerfile=${dockerfile}"
		fi
		return 1
	}
	mv "${tmp}" "${dockerfile}"
	log INFO "pinned base image dockerfile=${dockerfile} reference=${pinned}"
}

# push_once runs one push that returns as soon as the build is queued and
# prints the build ID. Fails without printing when no build was created.
push_once() {
	local dir=$1 version=$2 build_tag=$3 output build_id errors

	errors="$(mktemp)"
	# stdout carries the JSON; the CLI writes warnings and notices to stderr.
	if ! output="$("${APIFY_BIN}" push --dir "${dir}" --version "${version}" \
		--build-tag "${build_tag}" --wait-for-finish 0 --force --json 2>"${errors}")"; then
		log WARN "apify push failed stderr=$(tail -c 2000 "${errors}") stdout=${output}"
		rm -f "${errors}"
		return 1
	fi
	rm -f "${errors}"
	build_id="$(jq -r '(.id // .buildId // .build.id // .data.id) // empty' <<<"${output}" 2>/dev/null || true)"
	if [[ -z "${build_id}" ]]; then
		log WARN "apify push printed no build ID output=${output}"
		return 1
	fi
	printf '%s\n' "${build_id}"
}

# push_with_retry retries pushes that created no build. A push that created a
# build is never repeated, so a failed build is not rebuilt.
push_with_retry() {
	local dir=$1 version=$2 build_tag=$3 attempts=$4 backoff=$5 attempt build_id

	for ((attempt = 1; attempt <= attempts; attempt += 1)); do
		if build_id="$(push_once "${dir}" "${version}" "${build_tag}")"; then
			printf '%s\n' "${build_id}"
			return 0
		fi
		if ((attempt < attempts)); then
			log WARN "push attempt failed, retrying attempt=${attempt} delay_seconds=${backoff}"
			sleep "${backoff}"
			backoff=$((backoff * 2))
		fi
	done
	log ERROR "apify push failed after ${attempts} attempt(s)"
	return 1
}

main() {
	local dir="${ACTOR_DIR:-${DEFAULT_ACTOR_DIR}}"
	local build_tag="${BUILD_TAG:-${DEFAULT_BUILD_TAG}}"
	local wait_seconds="${WAIT_SECONDS:-${DEFAULT_WAIT_SECONDS}}"
	local attempts="${MAX_ATTEMPTS:-${DEFAULT_MAX_ATTEMPTS}}"
	local backoff="${BACKOFF_SECONDS:-${DEFAULT_BACKOFF_SECONDS}}"
	local release_tag="${RELEASE_TAG:-}"
	local version dockerfile digest build_id base_tag

	APIFY_BIN="${APIFY_BIN:-apify}"
	DOCKER_BIN="${DOCKER_BIN:-docker}"

	if [[ -z "${APIFY_TOKEN:-}" ]]; then
		log ERROR "APIFY_TOKEN is empty; pass the apify_token secret"
		return 1
	fi
	if [[ ! -f "${dir}/${ACTOR_JSON}" ]]; then
		log ERROR "actor.json not found path=${dir}/${ACTOR_JSON}"
		return 1
	fi
	version="$(actor_version "${ACTOR_VERSION:-}" "${release_tag}")"

	if [[ -n "${BASE_IMAGE:-}" ]]; then
		base_tag="${BASE_IMAGE_TAG:-${release_tag}}"
		if [[ -z "${base_tag}" ]]; then
			log ERROR "BASE_IMAGE is set but there is no tag to pin: set BASE_IMAGE_TAG or push a tag"
			return 1
		fi
		dockerfile="$(dockerfile_path "${dir}")"
		digest="$(resolve_digest "${BASE_IMAGE}:${base_tag}")"
		pin_base_image "${dockerfile}" "${BASE_IMAGE}" "${base_tag}" "${digest}"
	fi

	log INFO "pushing Actor dir=${dir} version=${version} build_tag=${build_tag}"
	build_id="$(push_with_retry "${dir}" "${version}" "${build_tag}" "${attempts}" "${backoff}")"
	log INFO "build queued build_id=${build_id}"

	# Exit code 0 only when the build SUCCEEDED; a timeout is a failure.
	if ! "${APIFY_BIN}" builds wait "${build_id}" --timeout "${wait_seconds}"; then
		log ERROR "Actor build did not succeed build_id=${build_id}"
		"${APIFY_BIN}" builds log "${build_id}" 2>&1 | tail -n 100 >&2 || true
		return 1
	fi
	log INFO "Actor build succeeded build_id=${build_id} version=${version} build_tag=${build_tag}"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf 'Apify Actor version %s built (build %s, tag %s).\n' \
			"${version}" "${build_id}" "${build_tag}" >>"${GITHUB_STEP_SUMMARY}"
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
