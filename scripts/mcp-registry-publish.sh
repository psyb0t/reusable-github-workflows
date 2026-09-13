#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_MCP_REGISTRY_API_BASE='https://registry.modelcontextprotocol.io/v0.1'
readonly DEFAULT_MCP_PUBLISHER='./mcp-publisher'
readonly HTTP_STATUS_OK='200'
readonly HTTP_STATUS_NOT_FOUND='404'
readonly DUPLICATE_VERSION_MESSAGE='invalid version: cannot publish duplicate version'
readonly MAX_VERIFICATION_ATTEMPTS=3
readonly VERIFICATION_RETRY_DELAY_SECONDS=1

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

require_env SERVER_JSON

server_json=${SERVER_JSON:-}
mcp_registry_api_base=${MCP_REGISTRY_API_BASE:-${DEFAULT_MCP_REGISTRY_API_BASE}}
mcp_publisher=${MCP_PUBLISHER:-${DEFAULT_MCP_PUBLISHER}}

if [[ ! -f "${server_json}" || ! -r "${server_json}" ]]; then
	log ERROR "SERVER_JSON is not a readable file"
	exit 1
fi
if ! command -v "${mcp_publisher}" >/dev/null 2>&1; then
	log ERROR "MCP_PUBLISHER is not executable"
	exit 1
fi

server_name=$(jq -er '.name // empty' "${server_json}") || {
	log ERROR 'SERVER_JSON must contain a name'
	exit 1
}
server_version=$(jq -er '.version // empty' "${server_json}") || {
	log ERROR 'SERVER_JSON must contain a version'
	exit 1
}
encoded_server_name=$(printf '%s' "${server_name}" | jq -sRr '@uri')
registry_url="${mcp_registry_api_base}/servers/${encoded_server_name}/versions/${server_version}"

if ! response_file=$(mktemp "${RUNNER_TEMP:-/tmp}/mcp-registry-response.XXXXXX"); then
	log ERROR 'could not create MCP Registry response file'
	exit 1
fi
if ! publisher_output_file=$(mktemp "${RUNNER_TEMP:-/tmp}/mcp-registry-publisher.XXXXXX"); then
	log ERROR 'could not create MCP Registry publisher output file'
	rm -f -- "${response_file}"
	exit 1
fi
cleanup() {
	rm -f -- "${response_file}" "${publisher_output_file}"
}
trap cleanup EXIT

registry_state=''

lookup_registry_version() {
	local http_status
	if ! http_status=$(curl -sS --retry "${MAX_VERIFICATION_ATTEMPTS}" --retry-all-errors --retry-delay "${VERIFICATION_RETRY_DELAY_SECONDS}" \
		--output "${response_file}" --write-out '%{http_code}' "${registry_url}"); then
		log ERROR "MCP Registry version lookup failed server_name=${server_name} version=${server_version}"
		return 1
	fi

	case "${http_status}" in
	"${HTTP_STATUS_OK}")
		if jq -e --slurpfile expected "${server_json}" '.server == $expected[0]' "${response_file}" >/dev/null; then
			registry_state='matching'
		else
			registry_state='mismatching'
		fi
		;;
	"${HTTP_STATUS_NOT_FOUND}") registry_state='missing' ;;
	*)
		log ERROR "MCP Registry version lookup returned unexpected status status=${http_status} server_name=${server_name} version=${server_version}"
		return 1
		;;
	esac
}

verify_registry_version() {
	local attempt
	for ((attempt = 1; attempt <= MAX_VERIFICATION_ATTEMPTS; attempt++)); do
		lookup_registry_version || return 1
		case "${registry_state}" in
		matching) return 0 ;;
		mismatching)
			log ERROR "MCP Registry version exists with different metadata server_name=${server_name} version=${server_version}"
			return 1
			;;
		missing)
			if ((attempt == MAX_VERIFICATION_ATTEMPTS)); then
				log ERROR "MCP Registry version is still missing after publish server_name=${server_name} version=${server_version}"
				return 1
			fi
			log WARN "MCP Registry version not visible yet server_name=${server_name} version=${server_version} attempt=${attempt}"
			sleep "${VERIFICATION_RETRY_DELAY_SECONDS}"
			;;
		esac
	done
}

lookup_registry_version || exit 1
case "${registry_state}" in
matching)
	log INFO "MCP Registry version already matches release server_name=${server_name} version=${server_version}"
	exit 0
	;;
mismatching)
	log ERROR "MCP Registry version exists with different metadata server_name=${server_name} version=${server_version}"
	exit 1
	;;
missing) log DEBUG "MCP Registry version is absent and will be published server_name=${server_name} version=${server_version}" ;;
esac

if ! "${mcp_publisher}" login github-oidc; then
	log ERROR "MCP Registry OIDC login failed server_name=${server_name} version=${server_version}"
	exit 1
fi
if "${mcp_publisher}" publish >"${publisher_output_file}" 2>&1; then
	verify_registry_version || exit 1
	log INFO "MCP Registry version published server_name=${server_name} version=${server_version}"
	exit 0
fi
if ! grep -Fq -- "${DUPLICATE_VERSION_MESSAGE}" "${publisher_output_file}"; then
	log ERROR "MCP Registry publish failed server_name=${server_name} version=${server_version}"
	exit 1
fi

log WARN "MCP Registry duplicate-version response received, verifying stored metadata server_name=${server_name} version=${server_version}"
verify_registry_version || exit 1
log INFO "MCP Registry version was published by a concurrent run server_name=${server_name} version=${server_version}"
