#===============================================================================
# Locale file staging: copy Claude i18n JSON into Electron's resources dir.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, electron_resources_dest, app_staging_dir
# Modifies globals: (none)
#===============================================================================

copy_locale_files() {
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying Claude locale JSON files to Electron resources directory...'
	if [[ -d $claude_locale_src ]]; then
		cp "$claude_locale_src/"*-*.json "$electron_resources_dest/" || exit 1
		echo 'Claude locale JSON files copied to Electron resources directory'
	else
		echo "Warning: Claude locale source directory not found at $claude_locale_src"
	fi

	echo "app.asar processed and staged in $app_staging_dir"
}
