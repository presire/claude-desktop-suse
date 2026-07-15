#!/usr/bin/env bash
#
# verify-patches.sh
#
# Static-greps a patched main-process JS for the patch markers defined
# in a TSV (defaults to scripts/cowork-patch-markers.tsv). Exits
# non-zero on any miss and names the missing markers in the output.
#
# Defends against silent half-patched asars (issue #559 D6, PR #555).
# Reusable for non-cowork patch sets — pass any TSV of the same shape
# via the second arg.
#
# Usage:
#     verify-patches.sh <path> [markers-tsv]
#
# <path> may be:
#   * a JavaScript file (the index.js stub, a chunk, or a monolithic
#     main-process bundle)
#   * an .asar archive (extracted on the fly via npx @electron/asar)
#   * a directory containing app.asar.contents/.vite/build/index.js
#
# Code-split bundles (upstream 1.19367.0+) are resolved automatically:
# if index.js is a stub that require()s index.chunk-<hash>.js, the
# chunk is used as the grep target so markers that live in the chunk
# are found.
#
# Exit codes:
#   0  — every marker present.
#   1  — usage error or input not found.
#   2  — one or more markers missing (named on stderr).
#

set -u
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_markers_tsv="$script_dir/cowork-patch-markers.tsv"
markers_tsv="$default_markers_tsv"

# Source the shared patch helpers for _resolve_main_js (chunk
# resolution). This is the same resolver used by the build-time
# patch scripts, so verify and build cannot drift.
patches_common="$script_dir/patches/_common.sh"
if [[ -f $patches_common ]]; then
	# shellcheck source-path=SCRIPTDIR/patches source=patches/_common.sh
	source "$patches_common"
fi

usage() {
	cat <<-EOF >&2
		Usage: $(basename "$0") <path> [markers-tsv]

		<path> may be a .js file, an .asar archive, or a directory
		containing app.asar.contents/.vite/build/index.js. The script
		greps for patch markers (default: cowork, PR #555 / issue #559
		D6) and exits non-zero if any are missing.

		[markers-tsv] overrides the default TSV so the same script can
		verify other patch sets.
	EOF
}

# Parse the marker TSV into three parallel arrays. Skips comments
# and blank lines. Used by both the verify path here and by the
# BATS test, which sources this script (see _is_sourced below) to
# share parsing and avoid drift between the two consumers.
load_markers() {
	marker_names=()
	marker_patterns=()
	marker_samples=()

	if [[ ! -f $markers_tsv ]]; then
		echo "verify-patches: marker file not found:" \
			"$markers_tsv" >&2
		return 1
	fi

	local name pattern sample
	while IFS=$'\t' read -r name pattern sample; do
		[[ -z $name || $name == '#'* ]] && continue
		if [[ -z ${pattern:-} || -z ${sample:-} ]]; then
			echo "verify-patches: malformed row '$name'" \
				'in markers file' >&2
			return 1
		fi
		marker_names+=("$name")
		marker_patterns+=("$pattern")
		marker_samples+=("$sample")
	done < "$markers_tsv"

	if [[ ${#marker_names[@]} -eq 0 ]]; then
		echo 'verify-patches: no markers loaded' >&2
		return 1
	fi
}

# Temp extraction directory for .asar inputs. Set in the main shell
# (not a subshell) so the EXIT trap can reliably clean it up.
tmp_extract_dir=''
cleanup_tmp() {
	if [[ -n $tmp_extract_dir && -d $tmp_extract_dir ]]; then
		rm -rf "$tmp_extract_dir"
	fi
}
trap cleanup_tmp EXIT

# Resolve the input path to the actual main-process JS file and store
# it in the global resolved_main_js. For .asar inputs, extracts to a
# temp dir (cleaned up via cleanup_tmp). Then follows code-split chunk
# resolution via _resolve_main_js so markers in index.chunk-<hash>.js
# are found when index.js is a stub. Directory and .asar inputs also
# scan safe sibling chunks because upstream may split patch targets
# across content-hashed files.
#
# Called directly (not via command substitution) so tmp_extract_dir
# survives into the main shell for the EXIT trap.
resolved_main_js=''
marker_files=()
resolve_index_js() {
	local input="$1"
	resolved_main_js=''
	marker_files=()

	if [[ ! -e $input ]]; then
		echo "verify-patches: not found: $input" >&2
		return 1
	fi

	local raw_index_js=''

	if [[ -d $input ]]; then
		raw_index_js="$input/app.asar.contents/.vite/build/index.js"
		if [[ ! -f $raw_index_js ]]; then
			echo "verify-patches: directory does not contain" \
				"app.asar.contents/.vite/build/index.js:" \
				"$input" >&2
			return 1
		fi
	elif [[ $input == *.asar ]]; then
		if ! command -v npx > /dev/null 2>&1; then
			echo 'verify-patches: npx not found; install' \
				'Node.js or pre-extract the asar' >&2
			return 1
		fi
		tmp_extract_dir="$(mktemp -d)"
		if ! npx --yes @electron/asar extract "$input" \
			"$tmp_extract_dir" > /dev/null 2>&1; then
			echo "verify-patches: asar extraction failed:" \
				"$input" >&2
			return 1
		fi
		raw_index_js="$tmp_extract_dir/.vite/build/index.js"
		if [[ ! -f $raw_index_js ]]; then
			echo 'verify-patches: extracted asar lacks' \
				'.vite/build/index.js' >&2
			return 1
		fi
	else
		# Treat as a JS file — let grep decide whether the contents
		# are sensible.
		raw_index_js="$input"
	fi

	# Follow code-split chunk resolution. _resolve_main_js is read-only
	# (no temp dirs or side effects), so command substitution is safe.
	# Diagnostics go to stderr; only the resolved path comes via stdout.
	local chunk_resolved
	if ! chunk_resolved="$(_resolve_main_js "$raw_index_js")"; then
		return 1
	fi
	resolved_main_js="$chunk_resolved"
	marker_files=("$resolved_main_js")
	if [[ -d $input || $input == *.asar ]]; then
		local marker_dir candidate
		marker_dir="$(dirname "$resolved_main_js")"
		for candidate in "$marker_dir"/index.chunk-*.js; do
			[[ -f $candidate ]] || continue
			if [[ $candidate != "$resolved_main_js" ]]; then
				marker_files+=("$candidate")
			fi
		done
	fi
	return 0
}

main() {
	if [[ $# -lt 1 || $# -gt 2 ]]; then
		usage
		return 1
	fi

	case "$1" in
		-h | --help)
			usage
			return 0
			;;
	esac

	if [[ $# -eq 2 ]]; then
		markers_tsv="$2"
	fi

	# resolve_index_js sets resolved_main_js and tmp_extract_dir in
	# this shell (no command substitution) so the EXIT trap cleans up.
	if ! resolve_index_js "$1"; then
		return 1
	fi

	if ! load_markers; then
		return 1
	fi

	echo "Verifying patch markers in: ${marker_files[*]}"
	echo "Marker source: $markers_tsv"

	local i marker_file found missing_names=()
	for i in "${!marker_names[@]}"; do
		found=false
		for marker_file in "${marker_files[@]}"; do
			if grep -qP -- "${marker_patterns[$i]}" "$marker_file"; then
				found=true
				break
			fi
			done
		if [[ $found == true ]]; then
			printf '  OK   %s\n' "${marker_names[$i]}"
		else
			printf '  MISS %s\n' "${marker_names[$i]}" >&2
			missing_names+=("${marker_names[$i]}")
		fi
	done

	if [[ ${#missing_names[@]} -gt 0 ]]; then
		local joined
		joined="$(IFS=','; printf '%s' "${missing_names[*]}")"
		printf '\nverify-patches: %d/%d markers missing: %s\n' \
			"${#missing_names[@]}" "${#marker_names[@]}" "$joined" >&2
		return 2
	fi

	printf '\nAll %d patch markers present.\n' \
		"${#marker_names[@]}"
	return 0
}

# Library mode: when sourced (BATS test), expose load_markers and
# the markers_tsv path without running main.
_is_sourced() {
	[[ ${BASH_SOURCE[0]} != "${0}" ]]
}

if ! _is_sourced; then
	main "$@"
fi
