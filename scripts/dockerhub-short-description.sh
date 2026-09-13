#!/usr/bin/env bash
set -euo pipefail

readonly MAX_SHORT_DESCRIPTION_BYTES=100
readonly TRUNCATION_SUFFIX='...'

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

if ! command -v python3 >/dev/null 2>&1; then
	log ERROR 'python3 is required to truncate Docker Hub descriptions safely'
	exit 1
fi

python3 -c '
import sys

maximum_bytes = int(sys.argv[1])
suffix = sys.argv[2]
description = sys.stdin.read()

if len(description.encode("utf-8")) <= maximum_bytes:
    sys.stdout.write(description)
    raise SystemExit(0)

available_bytes = maximum_bytes - len(suffix.encode("utf-8"))
characters = []
used_bytes = 0
for character in description:
    character_bytes = len(character.encode("utf-8"))
    if used_bytes + character_bytes > available_bytes:
        break
    characters.append(character)
    used_bytes += character_bytes

sys.stdout.write("".join(characters) + suffix)
' "${MAX_SHORT_DESCRIPTION_BYTES}" "${TRUNCATION_SUFFIX}" || {
	log ERROR 'could not truncate Docker Hub short description'
	exit 1
}
