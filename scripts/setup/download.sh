#===============================================================================
# Claude installer download and extraction (SUSE).
#
# Two paths are supported:
#   1. --exe <local installer>: copy and 7z-extract the .exe, then locate
#      the nupkg inside.
#   2. Direct nupkg download: fetch the nupkg URL resolved by
#      resolve_latest_url() and verify against the SHA-1 from RELEASES.
#
# Sourced by: build.sh
# Sourced globals:
#   work_dir, claude_nupkg_filename, claude_nupkg_url, claude_nupkg_sha1,
#   local_exe_path, project_root, release_tag
# Modifies globals:
#   claude_extract_dir, version, claude_nupkg_filename
#===============================================================================

download_claude_installer() {
	section_header 'Download Claude Installer'

	claude_extract_dir="$work_dir/claude-extract"
	mkdir -p "$claude_extract_dir" || exit 1

	if [[ -n $local_exe_path ]]; then
		# Local exe path: extract exe first, then find nupkg inside
		echo "Using local Claude installer: $local_exe_path"
		if [[ ! -f $local_exe_path ]]; then
			echo "Local installer file not found: $local_exe_path" >&2
			exit 1
		fi

		local claude_exe_path="$work_dir/$(basename "$local_exe_path")"
		cp "$local_exe_path" "$claude_exe_path" || exit 1
		echo 'Local installer copied to build directory'

		echo "Extracting exe to find nupkg..."
		if ! 7z x -y "$claude_exe_path" -o"$claude_extract_dir"; then
			echo 'Failed to extract installer exe' >&2
			exit 1
		fi

		cd "$claude_extract_dir" || exit 1
		local nupkg_path
		nupkg_path=$(find . -maxdepth 1 -name 'AnthropicClaude-*-full.nupkg' | head -1)
		if [[ -z $nupkg_path ]]; then
			echo "Could not find AnthropicClaude nupkg in extracted exe" >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		claude_nupkg_filename=$(basename "$nupkg_path")
		echo "Found nupkg in exe: $claude_nupkg_filename"
	else
		# Direct nupkg download
		echo "Downloading $claude_nupkg_filename for $architecture..."
		echo "URL: $claude_nupkg_url"
		cd "$claude_extract_dir" || exit 1
		if ! wget -O "$claude_nupkg_filename" "$claude_nupkg_url"; then
			echo "Failed to download nupkg from $claude_nupkg_url" >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo "Download complete: $claude_nupkg_filename"

		if [[ -n $claude_nupkg_sha1 ]]; then
			if ! verify_sha1 "$claude_nupkg_filename" \
				"$claude_nupkg_sha1" 'Claude nupkg'; then
				cd "$project_root" || exit 1
				exit 1
			fi
		fi
	fi

	# Extract version from nupkg filename
	version=$(echo "$claude_nupkg_filename" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
	if [[ -z $version ]]; then
		echo "Could not extract version from nupkg filename: $claude_nupkg_filename" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Detected Claude version: $version"

	# Extract wrapper version from release tag if provided
	# (e.g., v1.3.2+claude1.1.799 -> 1.3.2)
	if [[ -n $release_tag ]]; then
		local wrapper_version
		wrapper_version=$(echo "$release_tag" | LC_ALL=C grep -oP '^v\K[0-9]+\.[0-9]+\.[0-9]+(?=\+claude)')
		if [[ -n $wrapper_version ]]; then
			version="${version}-${wrapper_version}"
			echo "Package version with wrapper suffix: $version"
		else
			echo "Warning: Could not extract wrapper version from release tag: $release_tag" >&2
		fi
	fi

	echo "Extracting nupkg..."
	if ! 7z x -y "$claude_nupkg_filename"; then
		echo 'Failed to extract nupkg' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo 'Resources extracted from nupkg'

	cd "$project_root" || exit 1
}
