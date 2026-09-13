#!/usr/bin/env bash
set -euo pipefail

readonly DOCKERHUB_API_BASE='https://hub.docker.com'
readonly LOG_FILE="${LOG_FILE:-${RUNNER_TEMP:-/tmp}/dockerhub-metadata.log}"

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

require_env DOCKERHUB_USERNAME
require_env DOCKERHUB_TOKEN
require_env REPOSITORY
require_env WANT_PRIVATE

sync_description=${SYNC_DESCRIPTION:-true}
case "${sync_description}" in
true | false) ;;
*)
	log ERROR "SYNC_DESCRIPTION must be true or false"
	exit 1
	;;
esac

case "${WANT_PRIVATE}" in
true | false) ;;
*)
	log ERROR "WANT_PRIVATE must be true or false"
	exit 1
	;;
esac

if [[ "${REPOSITORY}" != */* || "${REPOSITORY#*/}" == */* ]]; then
	log ERROR "REPOSITORY must be namespace/name"
	exit 1
fi

namespace=${REPOSITORY%%/*}
repository_name=${REPOSITORY#*/}
name_pattern='^[a-z0-9]+([._-][a-z0-9]+)*$'
if ! [[ "${namespace}" =~ ${name_pattern} && "${repository_name}" =~ ${name_pattern} ]]; then
	log ERROR "REPOSITORY must contain valid Docker Hub namespace and name"
	exit 1
fi

description_file=${DESCRIPTION_FILE:-}
if [[ -n "${description_file}" && (! -f "${description_file}" || ! -r "${description_file}") ]]; then
	log ERROR "DESCRIPTION_FILE is not a readable file"
	exit 1
fi

payload=$(jq -cn --argjson is_private "${WANT_PRIVATE}" '{is_private: $is_private}')
if [[ "${sync_description}" == true ]]; then
	payload=$(jq -c --arg description "${SHORT_DESCRIPTION:-}" '. + {description: $description}' <<<"${payload}")
fi
if [[ -n "${description_file}" ]]; then
	payload=$(jq -c --rawfile full_description "${description_file}" '. + {full_description: $full_description}' <<<"${payload}")
fi

if ! auth_config=$(mktemp "${RUNNER_TEMP:-/tmp}/dockerhub-auth.XXXXXX"); then
	log ERROR "could not create temporary Docker Hub auth config"
	exit 1
fi
cleanup() {
	if [[ -e "${auth_config}" ]]; then
		rm -f -- "${auth_config}"
	fi
}
trap cleanup EXIT

log DEBUG "authenticating Docker Hub repository=${REPOSITORY}"
jwt=$(jq -nc '{username: env.DOCKERHUB_USERNAME, password: env.DOCKERHUB_TOKEN}' |
	curl -sS --fail-with-body --retry 3 --retry-all-errors --retry-delay 1 \
		-X POST \
		-H 'Content-Type: application/json' \
		--data @- \
		"${DOCKERHUB_API_BASE}/v2/users/login/" |
	jq -er '.token') || {
	log ERROR "Docker Hub authentication failed"
	exit 1
}

if ! (
	umask 077
	printf 'header = "Authorization: Bearer %s"\n' "${jwt}" >"${auth_config}"
); then
	log ERROR "could not write temporary Docker Hub auth config"
	exit 1
fi

api="${DOCKERHUB_API_BASE}/v2/namespaces/${namespace}/repositories/${repository_name}"
log DEBUG "updating Docker Hub metadata repository=${REPOSITORY}"
if ! printf '%s' "${payload}" |
	curl -sS --fail-with-body --retry 3 --retry-all-errors --retry-delay 1 \
		--config "${auth_config}" \
		-H 'Content-Type: application/json' \
		--data-binary @- \
		-X PATCH \
		"${api}" \
		>/dev/null; then
	log ERROR "Docker Hub metadata update failed repository=${REPOSITORY}"
	exit 1
fi

actual=$(curl -sS --fail-with-body --retry 3 --retry-all-errors --retry-delay 1 \
	--config "${auth_config}" \
	"${api}") || {
	log ERROR "Docker Hub metadata verification read failed repository=${REPOSITORY}"
	exit 1
}

if ! jq -e --argjson is_private "${WANT_PRIVATE}" '.is_private == $is_private' <<<"${actual}" >/dev/null; then
	log ERROR "Docker Hub visibility verification failed repository=${REPOSITORY}"
	exit 1
fi
if [[ "${sync_description}" == true ]] &&
	! jq -e --arg description "${SHORT_DESCRIPTION:-}" '.description == $description' <<<"${actual}" >/dev/null; then
	log ERROR "Docker Hub short description verification failed repository=${REPOSITORY}"
	exit 1
fi
if [[ -n "${description_file}" ]] &&
	! jq -e --rawfile full_description "${description_file}" '.full_description == $full_description' <<<"${actual}" >/dev/null; then
	log ERROR "Docker Hub full description verification failed repository=${REPOSITORY}"
	exit 1
fi

if [[ -z "${description_file}" ]]; then
	log WARN "no full description file supplied; preserving existing remote full description"
fi
log INFO "Docker Hub metadata synchronized repository=${REPOSITORY}"
