#!/usr/bin/env bats
#
# node-pty-staging.bats
# Covers the node-pty native-binary pipeline that produced the
# "node-pty native binaries not found - terminal features may not work"
# warning:
#   - install_node_pty() must install the prebuild-carrying release with
#     --ignore-scripts (npm >= 11 blocks lifecycle scripts, so the old
#     `npm install node-pty` produced no pty.node at all),
#   - it must stage prebuilds/<platform>-<arch>/pty.node as well as
#     build/Release/pty.node into app.asar.contents,
#   - it must fail loudly when no Linux binary is available,
#   - finalize_app_asar() must report the binary it actually shipped and
#     warn only when there is none.
#
# No network: the npm call is replaced by a stub on PATH, and asar is
# replaced by a stub that emulates `pack <src> <dest> --unpack '**/*.node'`.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	work_dir="$TEST_TMP/work"
	app_staging_dir="$TEST_TMP/stage"
	project_root="$TEST_TMP"
	node_pty_dir=''
	node_pty_build_dir=''
	node_pty_native_rel=''
	asar_exec="$TEST_TMP/bin/asar"
	source_dir="$TEST_TMP/src"
	NPM_ARGS_FILE="$TEST_TMP/npm-args"

	mkdir -p "$work_dir" \
		"$app_staging_dir/app.asar.contents/node_modules" \
		"$TEST_TMP/bin" \
		"$source_dir/scripts"
	printf 'exports.stub = true\n' > "$source_dir/scripts/claude-native-stub.js"
	printf '// stub daemon\n' > "$source_dir/scripts/cowork-vm-service.js"

	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/../scripts/_common.sh"
	# shellcheck source=scripts/patches/cowork.sh
	source "$SCRIPT_DIR/../scripts/patches/cowork.sh"
	# shellcheck source=scripts/staging/electron.sh
	source "$SCRIPT_DIR/../scripts/staging/electron.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

host_arch() {
	case "$(uname -m)" in
		x86_64 | amd64) printf 'x64\n' ;;
		aarch64 | arm64) printf 'arm64\n' ;;
		*) printf '\n' ;;
	esac
}

# Stub npm: records argv and materialises the package layout node-pty
# ships, which carries a prebuilds/ dir per architecture.
# $STUB_WITH_NATIVE=0 leaves out every native binary.
write_npm_stub() {
	local with_native="${1:-1}"
	cat > "$TEST_TMP/bin/npm" << 'NPM_STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$NPM_ARGS_FILE"
pkg='node_modules/node-pty'
mkdir -p "$pkg/lib" "$pkg/prebuilds/linux-x64" "$pkg/prebuilds/linux-arm64"
printf 'exports.pty = true\n' > "$pkg/lib/index.js"
printf '{"name":"node-pty","version":"1.2.0-beta.14"}\n' > "$pkg/package.json"
if [[ "${STUB_WITH_NATIVE:-1}" == '1' ]]; then
	: > "$pkg/prebuilds/linux-x64/pty.node"
	: > "$pkg/prebuilds/linux-arm64/pty.node"
fi
exit 0
NPM_STUB
	chmod +x "$TEST_TMP/bin/npm"
	STUB_WITH_NATIVE="$with_native"
	export STUB_WITH_NATIVE NPM_ARGS_FILE
	PATH="$TEST_TMP/bin:$PATH"
	export PATH
}

reject_npm() {
	cat > "$TEST_TMP/bin/npm" << 'NPM_REJECT'
#!/usr/bin/env bash
echo 'stub npm must not be reached on the --node-pty-dir path' >&2
exit 9
NPM_REJECT
	chmod +x "$TEST_TMP/bin/npm"
	PATH="$TEST_TMP/bin:$PATH"
	export PATH
}

# Prebuilt node-pty tree, as --node-pty-dir / the Nix store provides it.
make_prebuilt_pty() {
	local root="$1" rel="$2"
	mkdir -p "$root/lib" "$root/$(dirname "$rel")"
	printf 'exports.pty = true\n' > "$root/lib/index.js"
	printf '{"name":"node-pty","version":"1.2.0-beta.14"}\n' > "$root/package.json"
	printf 'stub-native\n' > "$root/$rel"
}

# Stub asar: `pack <src> <dest> --unpack <glob>`. Copies every *.node
# under <src> into <dest>.unpacked, mirroring the real CLI's tracked
# unpacked entry.
write_asar_stub() {
	cat > "$TEST_TMP/bin/asar" << 'ASAR_STUB'
#!/usr/bin/env bash
[[ $1 == 'pack' ]] || {
	echo "stub asar: unsupported command $1" >&2
	exit 2
}
src="$2"
dest="$3"
: > "$dest"
[[ -d $src ]] || exit 0
while IFS= read -r -d '' f; do
	rel="${f#"$src"/}"
	mkdir -p "$dest.unpacked/$(dirname "$rel")"
	cp "$f" "$dest.unpacked/$rel"
done < <(find "$src" -name '*.node' -type f -print0)
exit 0
ASAR_STUB
	chmod +x "$TEST_TMP/bin/asar"
}

@test "install_node_pty installs the pinned prebuild release with --ignore-scripts" {
	write_npm_stub 1

	run install_node_pty
	[[ "$status" -eq 0 ]]

	grep -qx -- '--ignore-scripts' "$NPM_ARGS_FILE"
	grep -qx -- '--no-audit' "$NPM_ARGS_FILE"
	grep -qx -- 'node-pty@1.2.0-beta.14' "$NPM_ARGS_FILE"
	[[ "$output" == *'node-pty@1.2.0-beta.14 installed successfully'* ]]
}

@test "install_node_pty stages only the host-arch prebuild out of several" {
	local arch other
	arch="$(host_arch)"
	[[ -n $arch ]] || skip "unsupported host architecture $(uname -m)"
	if [[ $arch == 'x64' ]]; then other='arm64'; else other='x64'; fi
	write_npm_stub 1

	run install_node_pty
	[[ "$status" -eq 0 ]]

	local contents="$app_staging_dir/app.asar.contents/node_modules/node-pty"
	[[ -f "$contents/prebuilds/linux-$arch/pty.node" ]]
	[[ ! -d "$contents/prebuilds/linux-$other" ]]
	[[ -f "$contents/lib/index.js" ]]
	[[ "$output" == *"node-pty prebuilds/linux-$arch staged"* ]]
}

@test "install_node_pty stages the --arch target prebuild, not the host one" {
	local arch target_arch target_dir other_dir
	arch="$(host_arch)"
	[[ -n $arch ]] || skip "unsupported host architecture $(uname -m)"
	if [[ $arch == 'x64' ]]; then
		target_arch='arm64'; target_dir='arm64'; other_dir='x64'
	else
		target_arch='amd64'; target_dir='x64'; other_dir='arm64'
	fi
	write_npm_stub 1

	architecture="$target_arch" run install_node_pty
	[[ "$status" -eq 0 ]]

	local contents="$app_staging_dir/app.asar.contents/node_modules/node-pty"
	[[ -f "$contents/prebuilds/linux-$target_dir/pty.node" ]]
	[[ ! -d "$contents/prebuilds/linux-$other_dir" ]]
}

@test "install_node_pty fails loudly when the install produced no native binary" {
	local arch
	arch="$(host_arch)"
	[[ -n $arch ]] || skip "unsupported host architecture $(uname -m)"
	write_npm_stub 0

	run install_node_pty
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"Error: node-pty has no native binary for linux-$arch"* ]]
}

@test "install_node_pty still stages build/Release from --node-pty-dir" {
	reject_npm
	node_pty_dir="$TEST_TMP/prebuilt-pty"
	make_prebuilt_pty "$node_pty_dir" 'build/Release/pty.node'

	run install_node_pty
	[[ "$status" -eq 0 ]]

	[[ -f "$app_staging_dir/app.asar.contents/node_modules/node-pty/build/Release/pty.node" ]]
	[[ "$output" == *'node-pty build/Release staged'* ]]
}

@test "install_node_pty picks the --arch target prebuild from a --node-pty-dir with both" {
	reject_npm
	node_pty_dir="$TEST_TMP/prebuilt-pty"
	make_prebuilt_pty "$node_pty_dir" 'prebuilds/linux-x64/pty.node'
	make_prebuilt_pty "$node_pty_dir" 'prebuilds/linux-arm64/pty.node'
	local contents="$app_staging_dir/app.asar.contents/node_modules/node-pty"

	architecture='amd64' run install_node_pty
	[[ $status -eq 0 ]]
	[[ -f $contents/prebuilds/linux-x64/pty.node ]]
	[[ ! -d $contents/prebuilds/linux-arm64 ]]

	architecture='arm64' run install_node_pty
	[[ $status -eq 0 ]]
	[[ -f $contents/prebuilds/linux-arm64/pty.node ]]
	[[ ! -d $contents/prebuilds/linux-x64 ]]
}

@test "install_node_pty refuses a --node-pty-dir that only has another arch" {
	reject_npm
	node_pty_dir="$TEST_TMP/prebuilt-pty"
	make_prebuilt_pty "$node_pty_dir" 'prebuilds/linux-arm64/pty.node'

	architecture='amd64' run install_node_pty
	[[ $status -ne 0 ]]
	[[ $output == *'no node-pty native binary for linux-x64'* ]]
}

@test "finalize_app_asar reports the unpacked prebuild and does not warn" {
	local arch
	arch="$(host_arch)"
	[[ -n $arch ]] || skip "unsupported host architecture $(uname -m)"
	write_asar_stub
	node_pty_build_dir="$TEST_TMP/ptydir"
	node_pty_native_rel="prebuilds/linux-$arch"
	make_prebuilt_pty "$node_pty_build_dir/node_modules/node-pty" "prebuilds/linux-$arch/pty.node"
	mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty"
	cp -r "$node_pty_build_dir/node_modules/node-pty/lib" \
		"$app_staging_dir/app.asar.contents/node_modules/node-pty/lib"
	cp "$node_pty_build_dir/node_modules/node-pty/package.json" \
		"$app_staging_dir/app.asar.contents/node_modules/node-pty/package.json"
	mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty/prebuilds/linux-$arch"
	cp "$node_pty_build_dir/node_modules/node-pty/prebuilds/linux-$arch/pty.node" \
		"$app_staging_dir/app.asar.contents/node_modules/node-pty/prebuilds/linux-$arch/pty.node"

	cd "$app_staging_dir" || return 1
	run finalize_app_asar
	[[ "$status" -eq 0 ]]

	[[ -f "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-$arch/pty.node" ]]
	[[ "$output" == *"node-pty native binary unpacked: node_modules/node-pty/prebuilds/linux-$arch/pty.node"* ]]
	[[ "$output" != *'may not work'* ]]
}

@test "finalize_app_asar drops Windows PE .node files from both trees and keeps ELF" {
	write_asar_stub
	local contents="$app_staging_dir/app.asar.contents"
	local unpacked="$app_staging_dir/app.asar.unpacked"
	mkdir -p "$contents/node_modules/node-pty/prebuilds/linux-x64" \
		"$contents/resources/office365-mcp" \
		"$unpacked/node_modules/node-pty/prebuilds/win32-x64" \
		"$unpacked/resources/office365-mcp"
	printf '\177ELF\002\001\001' \
		> "$contents/node_modules/node-pty/prebuilds/linux-x64/pty.node"
	printf 'MZ\220\000' > "$contents/resources/office365-mcp/msal-node-runtime.node"
	printf 'MZ\220\000' > "$contents/resources/office365-mcp/msalruntime.dll"
	printf 'MZ\220\000' > "$unpacked/node_modules/node-pty/prebuilds/win32-x64/conpty.node"
	printf 'MZ\220\000' \
		> "$unpacked/node_modules/node-pty/prebuilds/win32-x64/conpty_console_list.node"

	cd "$app_staging_dir" || return 1
	run finalize_app_asar
	[[ $status -eq 0 ]]
	[[ $output == *'Windows-only native modules removed: 3'* ]]
	[[ $output == *'no Windows PE native modules'* ]]

	[[ -f $unpacked/node_modules/node-pty/prebuilds/linux-x64/pty.node ]]
	[[ ! -e $unpacked/node_modules/node-pty/prebuilds/win32-x64 ]]
	[[ ! -e $unpacked/resources/office365-mcp/msal-node-runtime.node ]]
	[[ ! -e $contents/resources/office365-mcp/msal-node-runtime.node ]]
	# Only .node files are in scope; other payload stays as shipped.
	[[ -f $contents/resources/office365-mcp/msalruntime.dll ]]

	run finalize_app_asar
	[[ $status -eq 0 ]]
	[[ $output == *'Windows-only native modules removed: 0'* ]]
}

@test "finalize_app_asar fails when a PE .node reaches app.asar.unpacked after pack" {
	cat > "$TEST_TMP/bin/asar" << 'ASAR_STUB'
#!/usr/bin/env bash
: > "$3"
mkdir -p "$3.unpacked/node_modules/node-pty/prebuilds/win32-x64"
printf 'MZ' > "$3.unpacked/node_modules/node-pty/prebuilds/win32-x64/conpty.node"
ASAR_STUB
	chmod +x "$TEST_TMP/bin/asar"

	cd "$app_staging_dir" || return 1
	run finalize_app_asar
	[[ $status -ne 0 ]]
	[[ $output == *'Windows PE native module unpacked: node_modules/node-pty/prebuilds/win32-x64/conpty.node'* ]]
}

@test "PE prune keeps a newline in a name as one path (no stray delete)" {
	local tree="$TEST_TMP/nl"
	mkdir -p "$tree"
	printf 'MZ\220\000' > "$tree/first"$'\n'"victim.node"
	printf 'keep' > "$TEST_TMP/victim.node"
	printf 'keep' > "$tree/first"

	cd "$TEST_TMP" || return 1
	run _prune_windows_native_modules "$tree"
	[[ $status -eq 0 ]]
	[[ $output == *'Windows-only native modules removed: 1'* ]]
	[[ ! -e $tree/first$'\n'victim.node ]]
	[[ -f $TEST_TMP/victim.node ]]
	[[ -f $tree/first ]]
}

@test "PE scan fails instead of passing when a header cannot be read" {
	(( EUID != 0 )) || skip 'root reads mode-000 files'
	local tree="$TEST_TMP/unreadable"
	mkdir -p "$tree"
	printf 'MZ' > "$tree/locked.node"
	chmod 000 "$tree/locked.node"

	run _prune_windows_native_modules "$tree"
	chmod 600 "$tree/locked.node"
	[[ $status -ne 0 ]]
	[[ $output == *'Cannot read native module header'* ]]
	[[ -f $tree/locked.node ]]
}

@test "finalize_app_asar warns only when no node-pty binary was unpacked" {
	write_asar_stub
	mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty/lib"
	printf 'exports.pty = true\n' > "$app_staging_dir/app.asar.contents/node_modules/node-pty/lib/index.js"
	printf '{"name":"node-pty","version":"1.2.0-beta.14"}\n' \
		> "$app_staging_dir/app.asar.contents/node_modules/node-pty/package.json"

	cd "$app_staging_dir" || return 1
	run finalize_app_asar
	[[ "$status" -eq 0 ]]

	[[ "$output" == *'node-pty native binaries not found - terminal features may not work'* ]]
}
