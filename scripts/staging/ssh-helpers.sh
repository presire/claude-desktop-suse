#===============================================================================
# SSH helper staging: copy architecture-specific claude-ssh binary into the
# Electron resources directory.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, electron_resources_dest, architecture
# Modifies globals: (none)
#===============================================================================

copy_ssh_helpers() {
	section_header 'SSH Helpers'

	local ssh_src="$claude_extract_dir/lib/net45/resources/claude-ssh"
	local ssh_dest="$electron_resources_dest/claude-ssh"
	local binary_name="claude-ssh-linux-$architecture"

	if [[ ! -d "$ssh_src" ]]; then
		echo "Warning: SSH helpers not found at $ssh_src"
		section_footer 'SSH Helpers'
		return
	fi

	mkdir -p "$ssh_dest" || exit 1
	cp "$ssh_src/version.txt" "$ssh_dest/" || exit 1
	cp "$ssh_src/$binary_name" "$ssh_dest/" || exit 1
	chmod +x "$ssh_dest/$binary_name"

	echo "Copied SSH helper files:"
	echo "  version.txt"
	echo "  $binary_name"

	section_footer 'SSH Helpers'
}
