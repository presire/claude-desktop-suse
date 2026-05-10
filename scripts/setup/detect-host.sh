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
	raw_arch=$(uname -m) || {
		echo 'Failed to detect architecture' >&2
		exit 1
	}
	echo "Detected machine architecture: $raw_arch"

	case "$raw_arch" in
		x86_64)
			architecture='amd64'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64)
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
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-p|--prefix|-s|--source-dir|--node-pty-dir)
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
				echo "Usage: $0 [--build rpm|appimage] [--clean yes|no] [--exe /path/to/installer.exe] [--prefix /path] [--source-dir /path] [--node-pty-dir /path] [--release-tag TAG] [--dark] [--test-flags]"
				echo '  --build: Specify the build format (rpm or appimage).'
				echo "           Default: rpm"
				echo '  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes'
				echo '  --exe:   Use a local Claude installer exe instead of downloading'
				echo "  --prefix: Installation prefix for the package (default: /usr/lib)"
				echo "            Package installs to <prefix>/claude-desktop"
				echo '  --source-dir: Path to repo root for scripts/ and assets (default: project root)'
				echo '  --node-pty-dir: Path to pre-built node-pty package (skips npm install)'
				echo '  --release-tag: Release tag (e.g., v1.3.2+claude1.1.799) to append wrapper version to package'
				echo '  --dark: Replace default tray icons with dark-mode variants (white icons for dark panels)'
				echo '  --test-flags: Parse flags, print results, and exit without building.'
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
	echo "Fetching latest version from $releases_url..."

	local releases_content
	if ! releases_content=$(wget -qO- "$releases_url" 2>&1); then
		echo "Error: Failed to fetch RELEASES file from $releases_url" >&2
		exit 1
	fi

	# Find the latest full nupkg entry (last one in the file)
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
	claude_nupkg_url="https://downloads.claude.ai/releases/win32/${arch_path}/${claude_nupkg_filename}"

	# Extract SHA-1 hash from RELEASES file (format: "SHA1 filename size")
	claude_nupkg_sha1=$(echo "$releases_content" \
		| grep -F "$claude_nupkg_filename" \
		| awk '{print $1}' | tail -1) || true

	echo "Latest nupkg: $claude_nupkg_filename"
	echo "Download URL: $claude_nupkg_url"
	if [[ -n $claude_nupkg_sha1 ]]; then
		echo "Expected SHA-1: $claude_nupkg_sha1"
	fi

	section_footer 'URL Resolution'
}
