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
		# Not "*-*.json": several shipped locales have no region suffix
		# (am.json, da.json, ru.json, ...). See tests/locale-staging.bats.
		local -a locale_jsons=("$claude_locale_src/"*.json)
		if [[ -f ${locale_jsons[0]} ]]; then
			cp "${locale_jsons[@]}" "$electron_resources_dest/" || exit 1
			echo 'Claude locale JSON files copied to Electron resources directory'
		else
			# 4.x: locales ship inside app.asar (resources/i18n) only.
			echo 'No locale JSON next to app.asar; the bundle ships them inside app.asar'
		fi
	else
		echo "Warning: Claude locale source directory not found at $claude_locale_src"
	fi

	echo "app.asar processed and staged in $app_staging_dir"
}
