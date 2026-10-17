# shellcheck shell=bash
# Renders the prompt templates under scripts/prompts/. Sourced by
# regen-fix.sh and regen-context.sh.
#
#   render_prompt TEMPLATE NAME=VALUE ...
#
# A line that holds only {{NAME}} is replaced by VALUE's lines and dropped when
# VALUE is empty. Any other {{NAME}} is replaced in place. A placeholder without
# a value, or a value without a placeholder, is an error, so a template and its
# caller cannot drift apart silently.

readonly PROMPT_TEMPLATE_DIR="${BASH_SOURCE[0]%/*}/prompts"

render_prompt() {
	local template="${PROMPT_TEMPLATE_DIR}/$1"
	shift
	local -A values=()
	local -A used=()
	local pair name line value

	# Bash 5.2 expands & in a ${var//pat/rep} replacement; values are literal.
	shopt -u patsub_replacement 2>/dev/null || true

	for pair in "$@"; do
		values["${pair%%=*}"]="${pair#*=}"
	done

	while IFS= read -r line || [[ -n "${line}" ]]; do
		if [[ "${line}" =~ ^\{\{([A-Z_]+)\}\}$ ]]; then
			name=${BASH_REMATCH[1]}
			if [[ ! -v "values[${name}]" ]]; then
				log ERROR "prompt placeholder has no value template=${template##*/} name=${name}"
				return 1
			fi
			used["${name}"]=1
			value=${values[${name}]%$'\n'}
			[[ -n "${value}" ]] && printf '%s\n' "${value}"
			continue
		fi
		for name in "${!values[@]}"; do
			if [[ "${line}" == *"{{${name}}}"* ]]; then
				used["${name}"]=1
				line=${line//"{{${name}}}"/"${values[${name}]}"}
			fi
		done
		if [[ "${line}" =~ \{\{[A-Z_]+\}\} ]]; then
			log ERROR "prompt placeholder has no value template=${template##*/} name=${BASH_REMATCH[0]}"
			return 1
		fi
		printf '%s\n' "${line}"
	done <"${template}"

	for name in "${!values[@]}"; do
		if [[ ! -v "used[${name}]" ]]; then
			log ERROR "prompt value has no placeholder template=${template##*/} name=${name}"
			return 1
		fi
	done
}
