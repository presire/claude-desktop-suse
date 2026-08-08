#===============================================================================
# Host detection and argument parsing (SUSE): architecture, distro,
# requirements, CLI flag processing, latest-version resolution.
#
# Sourced by: build.sh
# Sourced globals: (none read on entry)
# Modifies globals:
#   architecture, distro_family, original_user, original_home,
#   project_root, work_dir, app_staging_dir, build_format,
#   cleanup_action, perform_cleanup, test_flags_mode, local_exe_path,
#   release_tag, source_dir, node_pty_dir, install_prefix,
#   dark_tray_icons, claude_nupkg_url, claude_nupkg_filename,
#   claude_nupkg_sha1
#===============================================================================

detect_architecture() {
	section_header 'Architecture Detection'
	echo 'Detecting system architecture...'

	local raw_arch
	if [[ -n ${override_arch:-} ]]; then
		echo "Architecture override via --arch: $override_arch"
		raw_arch="$override_arch"
	else
		raw_arch=$(uname -m) || {
			echo 'Failed to detect architecture' >&2
			exit 1
		}
		echo "Detected machine architecture: $raw_arch"
	fi

	case "$raw_arch" in
		x86_64|amd64)
			architecture='amd64'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64|arm64)
			architecture='arm64'
			echo 'Configured for arm64 (aarch64) build.'
			;;
		*)
			echo "Unsupported architecture: $raw_arch. This script supports x86_64 (amd64) and aarch64 (arm64)." >&2
			exit 1
			;;
	esac

	echo "Target Architecture: $architecture"
	section_footer 'Architecture Detection'
}

detect_distro() {
	section_header 'Distribution Detection'
	echo 'Detecting Linux distribution family...'

	if [[ -f /etc/SUSE-brand || -f /etc/SuSE-release ]]; then
		distro_family='suse'
		echo "Detected SUSE-based distribution"
	elif grep -qi 'suse\|opensuse' /etc/os-release 2>/dev/null; then
		distro_family='suse'
		echo "Detected SUSE-based distribution (via os-release)"
	else
		distro_family='unknown'
		echo "Warning: Could not detect SUSE distribution"
		echo "  RPM build may not work correctly on unsupported distributions"
	fi

	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	section_footer 'Distribution Detection'
}

check_system_requirements() {
	# Allow running as root in CI/container environments
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			echo 'This script should not be run using sudo or as the root user.' >&2
			echo 'It will prompt for sudo password when needed for specific actions.' >&2
			echo 'Please run as a normal user.' >&2
			exit 1
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	if [[ -z $original_home ]]; then
		echo "Could not determine home directory for user $original_user." >&2
		exit 1
	fi
	echo "Running as user: $original_user (Home: $original_home)"

	# Check for NVM and source it if found
	if [[ -d $original_home/.nvm ]]; then
		echo "Found NVM installation for user $original_user, checking for Node.js 20+..."
		export NVM_DIR="$original_home/.nvm"
		if [[ -s $NVM_DIR/nvm.sh ]]; then
			# shellcheck disable=SC1091
			\. "$NVM_DIR/nvm.sh"
			local node_bin_path=''
			node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || \
				find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

			if [[ -n $node_bin_path && -d $node_bin_path ]]; then
				echo "Adding NVM Node bin path to PATH: $node_bin_path"
				export PATH="$node_bin_path:$PATH"
			else
				echo 'Warning: Could not determine NVM Node bin path.'
			fi
		else
			echo 'Warning: nvm.sh script not found or not sourceable.'
		fi
	fi

	echo 'System Information:'
	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	echo "Target Architecture: $architecture"
}

parse_arguments() {
	section_header 'Argument Parsing'

	project_root="$(pwd)"
	work_dir="$project_root/build"
	app_staging_dir="$work_dir/electron-app"

	build_format='rpm'
	dark_tray_icons=false

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-p|--prefix|-s|--source-dir|--node-pty-dir|-a|--arch|--claude-version|--claude-sha256)
				if [[ -z ${2:-} || $2 == -* ]]; then
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				case "$1" in
					-b|--build) build_format="$2" ;;
					-c|--clean) cleanup_action="$2" ;;
					-e|--exe) local_exe_path="$2" ;;
					-r|--release-tag) release_tag="$2" ;;
					-p|--prefix) install_prefix="$2" ;;
					-s|--source-dir) source_dir="$2" ;;
					--node-pty-dir) node_pty_dir="$2" ;;
					-a|--arch) override_arch="$2" ;;
					--claude-version) claude_version_override="$2" ;;
					--claude-sha256) claude_sha256_override="$2" ;;
				esac
				shift 2
				;;
			--dark)
				dark_tray_icons=true
				shift
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
		-h|--help)
			echo "Usage: $0 [options]"
			echo ''
			echo 'Build options:'
			echo '  --build rpm|appimage'
			echo '      Package format to build.'
			echo '      Default: rpm'
			echo ''
			echo '  --clean yes|no'
			echo '      Remove intermediate build files after packaging.'
			echo '      Default: yes'
			echo ''
			echo '  --exe /path/to/installer.exe'
			echo '      Use a local Claude installer instead of downloading it.'
			echo ''
			echo '  --claude-version X.Y.Z'
			echo '      Download a specific Claude version instead of the latest'
			echo '      (e.g. 1.21459.0). Useful when the newest release is not'
			echo '      yet supported by the patch scripts. The RELEASES checksum'
			echo '      is used when available; otherwise the download is not'
			echo '      checksum-verified (a warning is printed).'
			echo ''
			echo '  --claude-sha256 HASH'
			echo '      Expected SHA-256 of the downloaded Claude nupkg. Verifies'
			echo '      --exe and --claude-version downloads, which otherwise have'
			echo '      no RELEASES checksum. The build aborts on mismatch.'
			echo ''
			echo '  --arch amd64|arm64'
			echo '      Override the target architecture for cross-building.'
			echo '      Default: host architecture (x86_64 -> amd64, aarch64 -> arm64)'
			echo ''
			echo '  --prefix /path'
			echo '      Installation prefix for packaged files.'
			echo '      Default: /usr/lib'
			echo '      Installs to: <prefix>/claude-desktop'
			echo ''
			echo '  --source-dir /path'
			echo '      Repository root containing scripts/ and assets/.'
			echo '      Default: current working directory'
			echo ''
			echo '  --node-pty-dir /path'
			echo '      Use a pre-built node-pty package and skip npm install.'
			echo ''
			echo '  --release-tag TAG'
			echo '      Append a wrapper version suffix to the package version.'
			echo '      Example: v1.3.2+claude1.1.799'
			echo ''
			echo '  --dark'
			echo '      Replace default tray icons with dark-mode variants.'
			echo ''
			echo '  --test-flags'
			echo '      Parse flags, print the resolved configuration, and exit.'
			echo ''
			echo '  -h, --help'
			echo '      Show this help text.'
			exit 0
			;;
			*)
				echo "Unknown option: $1" >&2
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# source_dir is where scripts/assets live (default: project_root)
	source_dir="${source_dir:-$project_root}"

	# Validate arguments
	build_format="${build_format,,}"
	cleanup_action="${cleanup_action,,}"

	if [[ ! -d $source_dir ]]; then
		echo "Error: --source-dir path does not exist: $source_dir" >&2
		exit 1
	fi
	if [[ -n $node_pty_dir && ! -d $node_pty_dir ]]; then
		echo "Error: --node-pty-dir path does not exist: $node_pty_dir" >&2
		exit 1
	fi
	if [[ -n $claude_version_override && ! $claude_version_override =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "Error: --claude-version must be a version like 1.21459.0 (got: '$claude_version_override')" >&2
		exit 1
	fi
	if [[ -n $claude_sha256_override && ! $claude_sha256_override =~ ^[0-9a-fA-F]{64}$ ]]; then
		echo "Error: --claude-sha256 must be a 64-character hex SHA-256 (got: '$claude_sha256_override')" >&2
		exit 1
	fi

	if [[ $build_format != 'rpm' && $build_format != 'appimage' ]]; then
		echo "Invalid build format specified: '$build_format'. Must be 'rpm' or 'appimage'." >&2
		exit 1
	fi

	# Warn if building RPM on non-SUSE system
	if [[ $build_format == 'rpm' && $distro_family != 'suse' ]]; then
		echo "Warning: Building .rpm package on non-SUSE system ($distro_family). This may fail." >&2
	fi
	if [[ $cleanup_action != 'yes' && $cleanup_action != 'no' ]]; then
		echo "Invalid cleanup option specified: '$cleanup_action'. Must be 'yes' or 'no'." >&2
		exit 1
	fi

	echo "Selected build format: $build_format"
	echo "Cleanup intermediate files: $cleanup_action"
	echo "Install prefix: $install_prefix"

	[[ $cleanup_action == 'yes' ]] && perform_cleanup=true

	section_footer 'Argument Parsing'
}

resolve_latest_url() {
	# Skip if using a local installer
	if [[ -n $local_exe_path ]]; then
		echo 'URL resolution skipped: using local installer (--exe)'
		return 0
	fi

	section_header 'URL Resolution'

	# Map architecture to URL path component
	local arch_path
	case "$architecture" in
		amd64) arch_path='x64' ;;
		arm64) arch_path='arm64' ;;
	esac

	local releases_url="https://downloads.claude.ai/releases/win32/${arch_path}/RELEASES"

	# RELEASES is fetched in both modes: for the latest version it names the
	# nupkg, and in either mode it may carry the SHA-1 for our target file.
	# When a version is pinned we tolerate a fetch failure and continue
	# unverified, since the download URL can be constructed without RELEASES.
	local releases_content=''
	if ! releases_content=$(wget -qO- "$releases_url" 2>&1); then
		if [[ -z $claude_version_override ]]; then
			echo "Error: Failed to fetch RELEASES file from $releases_url" >&2
			exit 1
		fi
		echo "Warning: Could not fetch RELEASES from $releases_url;" \
			'proceeding with the pinned version without a checksum.' >&2
		releases_content=''
	fi

	local nupkg_suffix='full'
	[[ $arch_path == 'arm64' ]] && nupkg_suffix='arm64-full'

	if [[ -n $claude_version_override ]]; then
		# Pinned: construct the nupkg name directly from the version.
		claude_nupkg_filename="AnthropicClaude-${claude_version_override}-${nupkg_suffix}.nupkg"
		echo "Using pinned Claude version: $claude_version_override"
	else
		# Latest: take the newest full nupkg entry from RELEASES.
		echo "Fetching latest version from $releases_url..."
		local latest_nupkg
		latest_nupkg=$(echo "$releases_content" | grep -oP 'AnthropicClaude-[0-9.]+-full\.nupkg' | tail -1)
		if [[ -z $latest_nupkg ]]; then
			# Try arm64-specific pattern
			latest_nupkg=$(echo "$releases_content" | grep -oP 'AnthropicClaude-[0-9.]+-arm64-full\.nupkg' | tail -1)
		fi
		if [[ -z $latest_nupkg ]]; then
			echo 'Error: Could not find latest nupkg in RELEASES file' >&2
			exit 1
		fi
		claude_nupkg_filename="$latest_nupkg"
	fi

	claude_nupkg_url="https://downloads.claude.ai/releases/win32/${arch_path}/${claude_nupkg_filename}"

	# Extract SHA-1 hash from RELEASES file (format: "SHA1 filename size").
	# Always present for the latest; present for a pinned version only if
	# RELEASES still lists it.
	claude_nupkg_sha1=$(echo "$releases_content" \
		| grep -F "$claude_nupkg_filename" \
		| awk '{print $1}' | tail -1) || true

	echo "Nupkg: $claude_nupkg_filename"
	echo "Download URL: $claude_nupkg_url"
	if [[ -n $claude_nupkg_sha1 ]]; then
		echo "Expected SHA-1: $claude_nupkg_sha1"
	elif [[ -n $claude_version_override ]]; then
		echo "Note: RELEASES has no SHA-1 for pinned version" \
			"$claude_version_override; download will not be" \
			'checksum-verified.' >&2
	fi

	section_footer 'URL Resolution'
}
