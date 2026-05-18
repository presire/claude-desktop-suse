#===============================================================================
# Common shell utilities: logging, command checks, checksum verification.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 not found"
		return 1
	else
		echo "$1 found"
		return 0
	fi
}

section_header() {
	echo -e "\033[1;36m--- $1 ---\033[0m"
}

section_footer() {
	echo -e "\033[1;36m--- End $1 ---\033[0m"
}

verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	# Strip BOM, whitespace, and non-hex characters so upstream metadata
	# that embeds a UTF-8 BOM or trailing whitespace doesn't cause a false
	# mismatch. Both hashes are reduced to a clean lowercase hex string.
	expected_hash=$(printf '%s' "$expected_hash" | tr -cd '0-9a-fA-F')

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-256 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")
	actual_hash=$(printf '%s' "$actual_hash" | tr -cd '0-9a-fA-F')

	if [[ ${actual_hash,,} != "${expected_hash,,}" ]]; then
		echo "SHA-256 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-256 verified: ${label}"
}

verify_sha1() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	# Strip BOM, whitespace, and non-hex characters so upstream metadata
	# that embeds a UTF-8 BOM or trailing whitespace doesn't cause a false
	# mismatch. Both hashes are reduced to a clean lowercase hex string.
	expected_hash=$(printf '%s' "$expected_hash" | tr -cd '0-9a-fA-F')

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-1 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-1 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha1sum "$file_path")
	actual_hash=$(printf '%s' "$actual_hash" | tr -cd '0-9a-fA-F')

	# Normalize both to lowercase for comparison (RELEASES file uses uppercase)
	if [[ ${actual_hash,,} != "${expected_hash,,}" ]]; then
		echo "SHA-1 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-1 verified: ${label}"
}
