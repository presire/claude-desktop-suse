#===============================================================================
# Icon processing: extract exe icons with wrestool/icotool, copy app icon for
# BrowserWindow titlebar, optionally swap default tray icons for dark-mode
# variants (SUSE --dark flag), then convert tray icons to 100% opaque PNG so
# they render on Linux panels.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, project_root, work_dir, electron_resources_dest,
#   dark_tray_icons
# Modifies globals: (none)
#===============================================================================

process_icons() {
	section_header 'Icon Processing'

	cd "$claude_extract_dir" || exit 1
	local exe_path='lib/net45/claude.exe'
	if [[ ! -f $exe_path ]]; then
		echo "Cannot find claude.exe at expected path: $claude_extract_dir/$exe_path" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo "Extracting application icons from $exe_path..."
	if ! wrestool -x -t 14 "$exe_path" -o claude.ico; then
		echo 'Failed to extract icons from exe' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if ! icotool -x claude.ico; then
		echo 'Failed to convert icons' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	cp claude_*.png "$work_dir/" || exit 1
	echo "Application icons extracted and copied to $work_dir"

	cd "$project_root" || exit 1

	# Copy app icon to Electron resources for BrowserWindow titlebar icon.
	# Prefer 256x256 then fall back to largest available.
	local app_icon=''
	for candidate in "$work_dir"/claude_*_256x256x32.png; do
		[[ -f $candidate ]] && app_icon="$candidate" && break
	done
	if [[ -z $app_icon ]]; then
		app_icon=$(ls -S "$work_dir"/claude_*.png 2>/dev/null | head -1)
	fi
	if [[ -n $app_icon ]]; then
		cp "$app_icon" "$electron_resources_dest/claude-desktop.png"
		echo "Copied app icon to resources: claude-desktop.png"
	else
		echo 'Warning: No app icon found for BrowserWindow titlebar'
	fi

	# Process tray icons
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying and processing tray icon files for Linux...'
	if [[ ! -d $claude_locale_src ]]; then
		echo "Warning: Claude resources directory not found at $claude_locale_src"
		section_footer 'Icon Processing'
		return
	fi

	cp "$claude_locale_src/Tray"* "$electron_resources_dest/" 2>/dev/null || \
		echo 'Warning: No tray icon files found'

	# --dark: replace default tray icons with dark-mode variants
	if [[ $dark_tray_icons == true ]]; then
		echo 'Replacing default tray icons with dark-mode variants...'
		local base dark
		for dark in "$electron_resources_dest"/TrayIconTemplate-Dark*.png; do
			[[ ! -f $dark ]] && continue
			base="${dark/-Dark/}"
			cp "$dark" "$base"
			echo "  $(basename "$dark") -> $(basename "$base")"
		done
		local dark_ico="$electron_resources_dest/Tray-Win32-Dark.ico"
		local base_ico="$electron_resources_dest/Tray-Win32.ico"
		if [[ -f $dark_ico ]]; then
			cp "$dark_ico" "$base_ico" || exit 1
			echo "  $(basename "$dark_ico") -> $(basename "$base_ico")"
		fi
		local dark_linux="$electron_resources_dest/TrayIconLinux-Dark.png"
		local base_linux="$electron_resources_dest/TrayIconLinux.png"
		if [[ -f $dark_linux ]]; then
			cp "$dark_linux" "$base_linux" || exit 1
			echo "  $(basename "$dark_linux") -> $(basename "$base_linux")"
		fi
		echo 'Dark-mode tray icons installed as default'
	fi

	# Find ImageMagick command
	local magick_cmd=''
	command -v magick &> /dev/null && magick_cmd='magick'
	[[ -z $magick_cmd ]] && command -v convert &> /dev/null && magick_cmd='convert'

	if [[ -z $magick_cmd ]]; then
		echo 'Warning: ImageMagick not found - tray icons may appear invisible'
		echo 'Tray icon files copied (unprocessed)'
		section_footer 'Icon Processing'
		return
	fi

	echo "Processing tray icons for Linux visibility (using $magick_cmd)..."
	local icon_file icon_name
	for icon_file in "$electron_resources_dest"/TrayIconTemplate*.png; do
		[[ ! -f $icon_file ]] && continue
		icon_name=$(basename "$icon_file")
		if "$magick_cmd" "$icon_file" -channel A -fx 'a>0?1:0' +channel \
			"PNG32:$icon_file" 2>/dev/null; then
			echo "  Processed $icon_name (100% opaque)"
		else
			echo "  Failed to process $icon_name"
		fi
	done
	echo 'Tray icon files copied and processed'

	section_footer 'Icon Processing'
}
