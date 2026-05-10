#===============================================================================
# Electron staging: finalize app.asar (pack with --unpack for native modules,
# copy native stubs and cowork daemon) and copy the Electron module tree into
# the staging directory with correct permissions.
#
# Sourced by: build.sh
# Sourced globals:
#   asar_exec, app_staging_dir, source_dir, node_pty_dir, node_pty_build_dir,
#   chosen_electron_module_path
# Modifies globals: electron_resources_dest
#===============================================================================

finalize_app_asar() {
	# Pack with --unpack so native modules (.node) are extracted
	# into app.asar.unpacked/ AND tracked in the asar manifest as
	# unpacked. Electron's asar->.unpacked redirect requires the
	# manifest entry to exist; otherwise loaders that require()
	# files from inside the asar get MODULE_NOT_FOUND.
	"$asar_exec" pack app.asar.contents app.asar \
		--unpack '**/*.node' || exit 1

	mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native" || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		"$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js" || exit 1

	# Copy cowork VM service daemon (must be unpacked for child_process.fork)
	echo 'Copying cowork VM service daemon to unpacked directory...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		"$app_staging_dir/app.asar.unpacked/cowork-vm-service.js" || exit 1
	echo 'Cowork VM service daemon copied to unpacked'

	# Copy node-pty native binaries
	local pty_release_dir=''
	if [[ -n $node_pty_dir && -d $node_pty_dir/build/Release ]]; then
		pty_release_dir="$node_pty_dir/build/Release"
	elif [[ -n $node_pty_build_dir && -d $node_pty_build_dir/node_modules/node-pty/build/Release ]]; then
		pty_release_dir="$node_pty_build_dir/node_modules/node-pty/build/Release"
	fi

	if [[ -n $pty_release_dir ]]; then
		echo 'Copying node-pty native binaries to unpacked directory...'
		mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release" || exit 1
		cp -r --no-preserve=mode "$pty_release_dir/"* \
			"$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/" || exit 1
		chmod +x "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/"* 2>/dev/null || true
		echo 'node-pty native binaries copied'
	else
		echo 'node-pty native binaries not found - terminal features may not work'
	fi
}

stage_electron() {
	echo 'Copying chosen electron installation to staging area...'
	mkdir -p "$app_staging_dir/node_modules/" || exit 1
	local electron_dir_name
	electron_dir_name=$(basename "$chosen_electron_module_path")
	echo "Copying from $chosen_electron_module_path to $app_staging_dir/node_modules/"
	cp -a "$chosen_electron_module_path" "$app_staging_dir/node_modules/" || exit 1

	local staged_electron_bin="$app_staging_dir/node_modules/$electron_dir_name/dist/electron"
	if [[ -f $staged_electron_bin ]]; then
		echo "Setting executable permission on staged Electron binary: $staged_electron_bin"
		chmod +x "$staged_electron_bin" || exit 1
	else
		echo "Warning: Staged Electron binary not found at expected path: $staged_electron_bin"
	fi

	# Copy Electron locale files
	local electron_resources_src="$chosen_electron_module_path/dist/resources"
	electron_resources_dest="$app_staging_dir/node_modules/$electron_dir_name/dist/resources"
	if [[ -d $electron_resources_src ]]; then
		echo 'Copying Electron locale resources...'
		mkdir -p "$electron_resources_dest" || exit 1
		cp -a "$electron_resources_src"/* "$electron_resources_dest/" || exit 1
		echo 'Electron locale resources copied'
	else
		echo "Warning: Electron resources directory not found at $electron_resources_src"
	fi
}
