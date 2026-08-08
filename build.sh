#!/usr/bin/env bash

#===============================================================================
# Claude Desktop Build Script (SUSE Fork)
# Repackages Claude Desktop (Electron app) for openSUSE/SLE Linux
#===============================================================================

# Global variables (set by functions, used throughout)
architecture=''
override_arch=''
distro_family=''  # suse or unknown
claude_nupkg_url=''
claude_nupkg_filename=''
claude_nupkg_sha1=''  # SHA-1 hash from RELEASES file for integrity verification
claude_version_override=''  # Pin a specific Claude version (e.g. 1.21459.0) instead of latest
claude_sha256_override=''  # Optional expected SHA-256 for the nupkg (verifies --exe / pinned downloads)
version=''
release_tag=''  # Optional release tag (e.g., v1.3.2+claude1.1.799) for unique package versions
build_format=''  # Will be set based on distro if not specified
cleanup_action='yes'
perform_cleanup=false
test_flags_mode=false
local_exe_path=''
source_dir=''  # Path to repo root for scripts/ and assets (default: project root)
node_pty_dir=''  # Path to pre-built node-pty package (skips npm install)
original_user=''
original_home=''
project_root=''
work_dir=''
app_staging_dir=''
chosen_electron_module_path=''
electron_var=''
electron_var_re=''
asar_exec=''
claude_extract_dir=''
electron_resources_dest=''
node_pty_build_dir=''
final_output_path=''
install_prefix='/usr/lib'

# Package metadata (constants)
readonly PACKAGE_NAME='claude-desktop'
readonly MAINTAINER='Claude Desktop Linux Maintainers'
readonly DESCRIPTION='Claude Desktop for Linux'
readonly WM_CLASS='Claude'
export WM_CLASS

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
source "$script_dir/scripts/_common.sh"
# shellcheck source=scripts/setup/detect-host.sh
source "$script_dir/scripts/setup/detect-host.sh"
# shellcheck source=scripts/setup/dependencies.sh
source "$script_dir/scripts/setup/dependencies.sh"
# shellcheck source=scripts/setup/download.sh
source "$script_dir/scripts/setup/download.sh"
# shellcheck source=scripts/staging/electron.sh
source "$script_dir/scripts/staging/electron.sh"
# shellcheck source=scripts/staging/icons.sh
source "$script_dir/scripts/staging/icons.sh"
# shellcheck source=scripts/staging/locales.sh
source "$script_dir/scripts/staging/locales.sh"
# shellcheck source=scripts/staging/ssh-helpers.sh
source "$script_dir/scripts/staging/ssh-helpers.sh"
# shellcheck source=scripts/staging/cowork-resources.sh
source "$script_dir/scripts/staging/cowork-resources.sh"
# shellcheck source=scripts/patches/_common.sh
source "$script_dir/scripts/patches/_common.sh"
# shellcheck source=scripts/patches/app-asar.sh
source "$script_dir/scripts/patches/app-asar.sh"
# shellcheck source=scripts/patches/tray.sh
source "$script_dir/scripts/patches/tray.sh"
# shellcheck source=scripts/patches/quick-window.sh
source "$script_dir/scripts/patches/quick-window.sh"
# shellcheck source=scripts/patches/claude-code.sh
source "$script_dir/scripts/patches/claude-code.sh"
# shellcheck source=scripts/patches/cowork.sh
source "$script_dir/scripts/patches/cowork.sh"
# shellcheck source=scripts/patches/wco-shim.sh
source "$script_dir/scripts/patches/wco-shim.sh"
# shellcheck source=scripts/patches/config.sh
source "$script_dir/scripts/patches/config.sh"
# shellcheck source=scripts/patches/org-plugins.sh
source "$script_dir/scripts/patches/org-plugins.sh"
# shellcheck source=scripts/patches/exit-accelerator.sh
source "$script_dir/scripts/patches/exit-accelerator.sh"
# shellcheck source=scripts/patches/virtiofsd-probe.sh
source "$script_dir/scripts/patches/virtiofsd-probe.sh"



#===============================================================================
# Packaging Functions
#===============================================================================

run_packaging() {
	section_header 'Call Packaging Script'

	local output_path=''

	case "$build_format" in
		rpm)
			echo "Calling RPM packaging script for $architecture..."
			chmod +x "scripts/packaging/rpm.sh" || exit 1
			if ! "scripts/packaging/rpm.sh" \
				"$version" "$architecture" "$work_dir" "$app_staging_dir" \
				"$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION" "$install_prefix"; then
				echo 'RPM packaging script failed.' >&2
				exit 1
			fi

			local pkg_file
			pkg_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}*.rpm" | head -n 1)
			echo 'RPM Build complete!'
			if [[ -n $pkg_file && -f $pkg_file ]]; then
				output_path="./$(basename "$pkg_file")"
				mv "$pkg_file" "$output_path" || exit 1
				echo "Package created at: $output_path"
			else
				echo 'Warning: Could not determine final .rpm file path.'
				output_path='Not Found'
			fi
			;;
		appimage)
			echo "Calling AppImage packaging script for $architecture..."
			chmod +x "scripts/packaging/appimage.sh" || exit 1
			if ! "scripts/packaging/appimage.sh" \
				"$version" "$architecture" "$work_dir" "$app_staging_dir" \
				"$PACKAGE_NAME"; then
				echo 'AppImage packaging script failed.' >&2
				exit 1
			fi

			local appimage_file
			appimage_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}-${architecture}.AppImage" | head -n 1)
			echo 'AppImage Build complete!'
			if [[ -n $appimage_file && -f $appimage_file ]]; then
				output_path="./$(basename "$appimage_file")"
				mv "$appimage_file" "$output_path" || exit 1
				echo "Package created at: $output_path"

				section_header 'Generate .desktop file for AppImage'
				local desktop_file="./${PACKAGE_NAME}-appimage.desktop"
				echo "Generating .desktop file for AppImage at $desktop_file..."
				cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $version)
Exec=$(basename "$output_path") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop (AppImage)
EOF
				echo '.desktop file generated.'
			else
				echo 'Warning: Could not determine final .AppImage file path.'
				output_path='Not Found'
			fi
			;;
	esac

	# Store for print_next_steps
	final_output_path="$output_path"
}

cleanup_build() {
	section_header 'Cleanup'
	if [[ $perform_cleanup != true ]]; then
		echo "Skipping cleanup of intermediate build files in $work_dir."
		return
	fi

	echo "Cleaning up intermediate build files in $work_dir..."
	if rm -rf "$work_dir"; then
		echo "Cleanup complete ($work_dir removed)."
	else
		echo 'Cleanup command failed.'
	fi
}

print_next_steps() {
	echo -e '\n\033[1;34m====== Next Steps ======\033[0m'

	case "$build_format" in
		rpm)
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				echo -e "To install the RPM package, run:"
				echo -e "   \033[1;32msudo zypper install $final_output_path\033[0m"
				echo -e "   (or \`sudo rpm -i $final_output_path\`)"
			else
				echo -e 'RPM package file not found. Cannot provide installation instructions.'
			fi
			;;
		appimage)
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				echo -e "AppImage created at: \033[1;36m$final_output_path\033[0m"
				echo -e '\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration'
				# shellcheck disable=SC2016  # backticks intentional for display
				echo -e 'and to handle the `claude://` login process correctly.'
				echo -e '\nTo install Gear Lever:'
				echo -e '   1. Install via Flatpak:'
				echo -e '      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m'
				echo -e '   2. Integrate your AppImage with just one click:'
				echo -e '      - Open Gear Lever'
				echo -e "      - Drag and drop \033[1;36m$final_output_path\033[0m into Gear Lever"
				echo -e "      - Click 'Integrate' to add it to your app menu"
				if [[ ${GITHUB_ACTIONS:-} == 'true' ]]; then
					echo -e '\n   This AppImage includes embedded update information!'
				else
					echo -e '\n   This locally-built AppImage does not include update information.'
					echo -e '   For automatic updates, download release versions: https://github.com/presire/claude-desktop-suse/releases'
				fi
			else
				echo -e 'AppImage file not found. Cannot provide usage instructions.'
			fi
			;;
	esac

	echo -e '\033[1;34m======================\033[0m'
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
	# Phase 1: Setup
	parse_arguments "$@"
	detect_architecture
	detect_distro
	check_system_requirements
	resolve_latest_url

	# Early exit for test mode
	if [[ $test_flags_mode == true ]]; then
		echo '--- Test Flags Mode Enabled ---'
		echo "Build Format: $build_format"
		echo "Target Architecture: $architecture"
		echo "Clean Action: $cleanup_action"
		echo "Install Prefix: $install_prefix"
		echo "Download URL: $claude_nupkg_url"
		echo "Nupkg: $claude_nupkg_filename"
		echo 'Exiting without build.'
		exit 0
	fi

	check_dependencies
	setup_work_directory
	setup_nodejs
	setup_electron_asar

	# Phase 2: Download and extract
	download_claude_installer

	# Phase 3: Patch and prepare
	patch_app_asar
	install_node_pty
	finalize_app_asar
	stage_electron
	process_icons
	copy_ssh_helpers
	copy_cowork_resources
	copy_locale_files

	cd "$project_root" || exit 1

	# Phase 4: Package
	run_packaging

	# Phase 5: Cleanup and finish
	cleanup_build

	echo 'Build process finished.'
	print_next_steps
}

# Run main with all script arguments
main "$@"

exit 0
