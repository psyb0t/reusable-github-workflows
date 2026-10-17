#!/usr/bin/env bash
# Release step of release-workflow.yml. Cuts, or repairs, one GitHub release
# for TAG. Runs in a checkout of that tag with full history (fetch-depth: 0).
#
# Release notes precedence:
#   1. CHANGELOG_FILE, when set and present on disk (unchanged behavior).
#   2. Else the ANNOTATED tag's own message body, when it is non-blank: the
#      text below the "vX.Y.Z" subject line of `git tag -a -m`, signature
#      block excluded. A lightweight tag has no body, so this falls
#      through for it, and so does a blank annotated body.
#   3. Else gh's own --generate-notes (commits since the previous tag, the
#      only behavior a lightweight tag or an empty annotated body ever had).
#
# A release that already exists is repaired (gh release edit --notes-file)
# only when the notes came from (1) or (2): the caller's own words win over
# whatever created the release first, such as docker-image-workflow's
# built-in release job. A release whose notes would come from (3) is left
# alone, exactly as before this script existed.
set -euo pipefail

readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/release-notes-release.log}"

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

# Drops leading and trailing blank lines; keeps blank lines in the middle.
trim_blank_lines() {
	tr -d '\r' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

release_exists() {
	gh release view "$1" >/dev/null 2>&1
}

# Writes the annotated tag's message body (signature block excluded) to
# stdout and returns 0 when it is non-blank. Returns 1 for a lightweight tag
# or a blank annotated body, in which case nothing is written.
annotated_tag_body() {
	local tag=$1 ref body signature
	ref="refs/tags/${tag}"

	# actions/checkout can leave a dereferenced (lightweight-looking) copy of
	# an annotated tag ref; re-fetching the real tag object makes this read
	# the actual message regardless of how the checkout step resolved it. A
	# failure here is not fatal: the checkout may already carry the real
	# object, so the next checks still get a fair try.
	if ! git fetch --force origin "${ref}:${ref}" >/dev/null 2>&1; then
		log WARN "could not fetch ${ref} from origin tag=${tag}; using whatever the checkout already has"
	fi

	if [[ "$(git cat-file -t "${ref}" 2>/dev/null || true)" != tag ]]; then
		log DEBUG "tag=${tag} is lightweight; no annotated body available"
		return 1
	fi

	body="$(git for-each-ref --format='%(contents:body)' "${ref}")"
	signature="$(git for-each-ref --format='%(contents:signature)' "${ref}")"
	if [[ -n "${signature}" ]]; then
		body="${body%"${signature}"}"
	fi
	body="$(printf '%s' "${body}" | trim_blank_lines)"

	if [[ -z "${body// /}" ]]; then
		log DEBUG "tag=${tag} annotated body is blank"
		return 1
	fi

	printf '%s\n' "${body}"
}

# Sets NOTES_SOURCE to changelog, tag_body or generated, and for the first two
# writes the resolved notes to NOTES_FILE.
resolve_notes() {
	local tag=$1

	if [[ -n "${CHANGELOG_FILE}" && -f "${CHANGELOG_FILE}" ]]; then
		NOTES_SOURCE=changelog
		cp "${CHANGELOG_FILE}" "${NOTES_FILE}"
		return 0
	fi

	if annotated_tag_body "${tag}" >"${NOTES_FILE}"; then
		NOTES_SOURCE=tag_body
		return 0
	fi

	NOTES_SOURCE=generated
}

main() {
	require_env GH_TOKEN
	require_env TAG
	require_env PRERELEASE_MATCH
	CHANGELOG_FILE="${CHANGELOG_FILE:-}"

	# Not `local`: the EXIT trap below runs after main() has already
	# returned, once its local variables are gone, so the path it cleans up
	# must live in a variable that survives that long.
	NOTES_FILE="$(mktemp)"
	trap 'rm -f -- "${NOTES_FILE}"' EXIT

	local notes_source
	resolve_notes "${TAG}"
	notes_source="${NOTES_SOURCE}"
	log INFO "resolved release notes tag=${TAG} source=${notes_source}"

	if release_exists "${TAG}"; then
		case "${notes_source}" in
		changelog | tag_body)
			gh release edit "${TAG}" --notes-file "${NOTES_FILE}"
			log INFO "release already existed tag=${TAG}; repaired its body source=${notes_source}"
			;;
		*)
			log INFO "release already exists tag=${TAG}; nothing to do source=${notes_source}"
			;;
		esac
		return 0
	fi

	local args=(--title "${TAG}")

	if printf '%s' "${TAG}" | grep -qiE "${PRERELEASE_MATCH}"; then
		args+=(--prerelease)
	fi

	case "${notes_source}" in
	changelog | tag_body) args+=(--notes-file "${NOTES_FILE}") ;;
	generated) args+=(--generate-notes) ;;
	esac

	gh release create "${TAG}" "${args[@]}"
	log INFO "created release tag=${TAG} notes_source=${notes_source}"
}

main "$@"
