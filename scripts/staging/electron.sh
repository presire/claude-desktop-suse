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

# Collect every *.node under the given trees that is a Windows PE
# image (DOS "MZ" header) into the global array pe_native_modules. The
# Windows nupkg ships win32 builds that Linux cannot dlopen: node-pty's
# conpty.node / conpty_console_list.node, the replaced claude-native
# binding and office365-mcp's msal-node-runtime.node (loaded in a
# try/catch that degrades the same way when the file is absent). ELF
# and non-binary files are kept, so the result does not depend on the
# target architecture.
#
# Paths stay NUL-delimited end to end (a newline in a name must not
# split it into another path), and a failed listing or an unreadable
# header fails instead of reporting "no PE modules".
#
# Usage:   _list_pe_native_modules <dir>...
# Sets:    pe_native_modules (sorted per tree)
# Return:  0 on success, 1 when a tree cannot be listed or read
_list_pe_native_modules() {
	local root file magic list
	local -a found=()
	pe_native_modules=()
	list=$(mktemp) || return 1
	for root in "$@"; do
		[[ -d $root ]] || continue
		if ! (set -o pipefail
			find "$root" -type f -name '*.node' -print0 \
				| LC_ALL=C sort -z) > "$list"; then
			echo "Cannot list native modules under: $root" >&2
			rm -f -- "$list"
			return 1
		fi
		mapfile -d '' -t found < "$list"
		for file in "${found[@]}"; do
			if ! magic=$(set -o pipefail
				LC_ALL=C head -c 2 -- "$file" | tr -d '\0'); then
				echo "Cannot read native module header: $file" >&2
				rm -f -- "$list"
				return 1
			fi
			[[ $magic == 'MZ' ]] && pe_native_modules+=("$file")
		done
	done
	rm -f -- "$list"
	return 0
}

# Delete the Windows PE *.node files found by _list_pe_native_modules,
# plus their directory when that leaves it empty (prebuilds/win32-*).
# Idempotent: a second run finds nothing.
#
# Usage:   _prune_windows_native_modules <dir>...
_prune_windows_native_modules() {
	local file
	_list_pe_native_modules "$@" || return 1
	for file in "${pe_native_modules[@]}"; do
		rm -f -- "$file" || return 1
		rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$file")" \
			|| return 1
		echo "Removed Windows-only native module: $file"
	done
	echo "Windows-only native modules removed: ${#pe_native_modules[@]}"
}

finalize_app_asar() {
	# Both trees feed the packed output: asar extract materialised the
	# unpacked .node files into app.asar.contents, and the upstream
	# app.asar.unpacked copy is shipped as-is.
	_prune_windows_native_modules app.asar.contents \
		"$app_staging_dir/app.asar.unpacked" || exit 1

	"$asar_exec" pack app.asar.contents app.asar \
		--unpack '**/*.node' || exit 1

	mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native" || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		"$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js" || exit 1

	echo 'Copying cowork VM service daemon to unpacked directory...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		"$app_staging_dir/app.asar.unpacked/cowork-vm-service.js" || exit 1
	echo 'Cowork VM service daemon copied to unpacked'

	# install_node_pty records the layout it staged (build/Release or
	# prebuilds/linux-<arch>), which also avoids re-deriving the arch
	# here and copying a cross-arch prebuild.
	local pty_unpacked_root="$app_staging_dir/app.asar.unpacked"
	local pty_unpacked_dir="$pty_unpacked_root/node_modules/node-pty"
	local pty_src_root=''
	if [[ -n $node_pty_dir ]]; then
		pty_src_root="$node_pty_dir"
	elif [[ -n $node_pty_build_dir ]]; then
		pty_src_root="$node_pty_build_dir/node_modules/node-pty"
	fi
	local pty_native_rel="${node_pty_native_rel:-}"
	if [[ -z $pty_native_rel && -f $pty_src_root/build/Release/pty.node ]]; then
		pty_native_rel='build/Release'
	fi

	if [[ -n $pty_native_rel && -f $pty_src_root/$pty_native_rel/pty.node ]]; then
		echo 'Copying node-pty native binaries to unpacked directory...'
		mkdir -p "$pty_unpacked_dir/$(dirname "$pty_native_rel")" || exit 1
		cp -r --no-preserve=mode "$pty_src_root/$pty_native_rel" \
			"$pty_unpacked_dir/$(dirname "$pty_native_rel")/" || exit 1
		chmod +x "$pty_unpacked_dir/$pty_native_rel/"* 2>/dev/null || true
		echo "node-pty $pty_native_rel copied to unpacked"
	fi

	local pty_shipped='' pty_cand=''
	for pty_cand in "$pty_unpacked_dir"/build/*/pty.node "$pty_unpacked_dir"/prebuilds/*/pty.node; do
		if [[ -f $pty_cand ]]; then
			pty_shipped="${pty_cand#"$pty_unpacked_root/"}"
			break
		fi
	done
	if [[ -n $pty_shipped ]]; then
		echo "node-pty native binary unpacked: $pty_shipped"
	else
		echo 'node-pty native binaries not found - terminal features may not work'
	fi

	local unpacked_dir="$app_staging_dir/app.asar.unpacked"
	local expected_files=(
		"node_modules/@ant/claude-native/index.js"
		"cowork-vm-service.js"
	)
	local missing=0 ef
	for ef in "${expected_files[@]}"; do
		if [[ ! -f "$unpacked_dir/$ef" ]]; then
			echo "Repack invariance check FAILED: expected unpacked file missing: $ef" >&2
			missing=1
		fi
	done
	if ! _list_pe_native_modules "$unpacked_dir"; then
		echo 'Repack invariance check FAILED: cannot scan app.asar.unpacked' \
			'for Windows PE native modules' >&2
		missing=1
	fi
	for ef in "${pe_native_modules[@]}"; do
		echo "Repack invariance check FAILED: Windows PE native module unpacked: ${ef#"$unpacked_dir/"}" >&2
		missing=1
	done
	if (( missing == 1 )); then
		echo 'The app.asar.unpacked fileset drifted from expectations.' >&2
		echo 'This usually means asar pack or a staging step changed.' >&2
		exit 1
	fi
	echo 'Repack invariance check passed (all expected unpacked files present, no Windows PE native modules)'
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
