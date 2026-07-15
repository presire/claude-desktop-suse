#===============================================================================
# Add Ctrl+Q accelerator to the Exit menu item.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

patch_exit_accelerator() {
	echo 'Patching Exit menu item to add Ctrl+Q accelerator...'
	local index_js="$main_js"

	if grep -q 'description:"Menu item for exiting the application"}),click:' "$index_js"; then
		sed -i 's/description:"Menu item for exiting the application"}),click:/description:"Menu item for exiting the application"}),accelerator:"CmdOrCtrl+Q",click:/g' \
			"$index_js"
		echo '  Added CmdOrCtrl+Q accelerator to Exit menu item'
	else
		echo '  Exit menu item pattern not found or already patched'
	fi
	echo '##############################################################'
}
