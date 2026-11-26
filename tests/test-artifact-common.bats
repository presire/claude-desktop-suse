#!/usr/bin/env bats
#
# @file test-artifact-common.bats
# @brief 成果物検証の共通ヘルパー(tests/test-artifact-common.sh)のテスト
#
# test-artifact-rpm.shとtest-artifact-appimage.shが依存する
# ヘルパーの契約を固定する
# rpm側の検証はchrome-sandboxに対してassert_setuidを呼ぶ
#
# 権限の確認が実際の状態に反応することも確かめる
# setuidビットを外した固定データでは、必ずFAILに転じなければならない

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ

#
# @brief テスト用の一時ディレクトリを用意し、検証用の共通ヘルパーを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	# shellcheck source=tests/test-artifact-common.sh
	source "$SCRIPT_DIR/test-artifact-common.sh"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief ヘッダだけを持つ検査用のASARを作る
# @param $1 出力先
# @param $2 ヘッダのJSON
# @note 実物と同じく、4バイト目のペイロード長、12バイト目の
#       ヘッダ文字列長、16バイト目からのJSONという並びにする
#
write_test_asar() {
	local asar_file="$1" header_json="$2"
	node -e '
const fs = require("fs");
const json = Buffer.from(process.argv[2], "utf8");
const payload = Buffer.alloc(8 + json.length);
payload.writeUInt32LE(json.length + 4, 0);
payload.writeUInt32LE(json.length, 4);
json.copy(payload, 8);
const prefix = Buffer.alloc(8);
prefix.writeUInt32LE(4, 0);
prefix.writeUInt32LE(payload.length, 4);
fs.writeFileSync(process.argv[1], Buffer.concat([prefix, payload]));
' "$asar_file" "$header_json"
}

#
# @brief ELF64ヘッダだけを持つ検査用のバイナリを作る
# @param $1 出力先
# @param $2 e_machineの値 (x86_64は62、aarch64は183)
#
write_test_elf() {
	local elf_file="$1" machine="$2"
	node -e '
const fs = require("fs");
const header = Buffer.alloc(64);
header[0] = 0x7f;
header[1] = 0x45;
header[2] = 0x4c;
header[3] = 0x46;
header[4] = 2;
header[5] = 1;
header[6] = 1;
header.writeUInt16LE(Number(process.argv[2]), 18);
fs.writeFileSync(process.argv[1], header);
' "$elf_file" "$machine"
}

@test "all helpers invoked by RPM/AppImage validators are defined" {
	# test-artifact-rpm.shとtest-artifact-appimage.shが参照するヘルパーは、
	# すべてここに定義されていなければならない
	# 定義漏れ(setuid確認の欠落はこのテスト群が塞ぐ)は、
	# インストール後のテストで初めてcommand not foundとして露見してしまう
	local helpers=(
		pass
		fail
		skip
		print_summary
		assert_file_exists
		assert_dir_exists
		assert_executable
		assert_setuid
		assert_contains
		assert_command_succeeds
		assert_no_pe_native_modules
		assert_asar_no_compile_cache
		assert_asar_unpacked_entries
		assert_elf_arch
		assert_package_chain
		validate_app_contents
		run_version_flag_test
		run_launch_smoke_test
		_launch_smoke_cleanup
	)
	local h
	for h in "${helpers[@]}"; do
		[[ $(declare -F "$h") == "$h" ]]
	done
}

@test "assert_setuid: PASS on a fixture with the setuid bit" {
	local fixture="$TEST_TMP/chrome-sandbox"
	touch "$fixture"
	chmod u+s "$fixture"
	_pass_count=0
	_fail_count=0
	assert_setuid "$fixture" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "assert_setuid: FAIL on a fixture without the setuid bit (mutation check)" {
	local fixture="$TEST_TMP/chrome-sandbox"
	touch "$fixture"
	chmod 0755 "$fixture"
	_pass_count=0
	_fail_count=0
	assert_setuid "$fixture" || true
	# setuidビットの無い固定データでは、確認が失敗しなければならない
	# ここがPASSのままなら確認は形だけで、
	# chrome-sandboxのsetuidビットを落とした再パッケージが検出されずに出荷されてしまう
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_no_pe_native_modules: PASS on ELF and non-binary .node files" {
	local dir="$TEST_TMP/unpacked"
	mkdir -p "$dir/node_modules/node-pty/prebuilds/linux-x64"
	printf '\177ELF\002\001\001' > "$dir/node_modules/node-pty/prebuilds/linux-x64/pty.node"
	: > "$dir/empty.node"
	_pass_count=0
	_fail_count=0
	assert_no_pe_native_modules "$dir" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "assert_no_pe_native_modules: FAIL names a shipped PE .node (mutation check)" {
	local dir="$TEST_TMP/unpacked"
	mkdir -p "$dir/node_modules/node-pty/prebuilds/win32-x64"
	printf 'MZ\220\000' > "$dir/node_modules/node-pty/prebuilds/win32-x64/conpty.node"
	_pass_count=0
	_fail_count=0
	run assert_no_pe_native_modules "$dir"
	[[ $output == *'node_modules/node-pty/prebuilds/win32-x64/conpty.node'* ]]
	assert_no_pe_native_modules "$dir" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_no_pe_native_modules: FAIL when a header cannot be read" {
	(( EUID != 0 )) || skip 'root reads mode-000 files'
	local dir="$TEST_TMP/unreadable"
	mkdir -p "$dir"
	printf 'MZ' > "$dir/locked.node"
	chmod 000 "$dir/locked.node"
	run assert_no_pe_native_modules "$dir"
	chmod 600 "$dir/locked.node"
	[[ $output == *'[FAIL] Cannot read .node header'* ]]
	[[ $output != *'[PASS]'* ]]
}

@test "assert_no_pe_native_modules: FAIL on a missing directory" {
	_pass_count=0
	_fail_count=0
	assert_no_pe_native_modules "$TEST_TMP/absent" 2>/dev/null || true
	(( _fail_count == 1 ))
}

@test "print_summary: skips pass by default" {
	run bash -c 'source "$1"; skip x; print_summary' _ \
		"$SCRIPT_DIR/test-artifact-common.sh"
	[[ $status -eq 0 ]]
}

@test "print_summary: ARTIFACT_FAIL_ON_SKIP=1 turns a skip into exit 1" {
	ARTIFACT_FAIL_ON_SKIP=1 run bash -c \
		'source "$1"; pass y; skip x; print_summary' _ \
		"$SCRIPT_DIR/test-artifact-common.sh"
	[[ $status -eq 1 ]]
	[[ $output == *'ARTIFACT_FAIL_ON_SKIP=1'* ]]

	ARTIFACT_FAIL_ON_SKIP=1 run bash -c \
		'source "$1"; pass y; print_summary' _ \
		"$SCRIPT_DIR/test-artifact-common.sh"
	[[ $status -eq 0 ]]
}

@test "run_version_flag_test: PASS on matching prefix" {
	local mock="$TEST_TMP/mock-version"
	printf '#!/usr/bin/env bash\necho "claude-desktop 1.1.8629"\n' > "$mock"
	chmod +x "$mock"
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' 'claude-desktop 1.1.8629' exact "$mock" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "run_version_flag_test: FAIL on empty expected prefix (fail-closed)" {
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' '' exact /bin/true || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "run_version_flag_test: FAIL on mismatching prefix (mutation check)" {
	local mock="$TEST_TMP/mock-version"
	printf '#!/usr/bin/env bash\necho "claude-desktop 1.1.8629"\n' > "$mock"
	chmod +x "$mock"
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' 'wrong-package 0.0.0' exact "$mock" || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "run_version_flag_test: exact policy rejects corrupt suffix" {
	local mock="$TEST_TMP/mock-version"
	printf '#!/usr/bin/env bash\necho "claude-desktop 1.1.8629-corrupt"\n' > "$mock"
	chmod +x "$mock"
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' 'claude-desktop 1.1.8629' exact "$mock" || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "run_version_flag_test: rpm policy accepts numeric release suffix" {
	local mock="$TEST_TMP/mock-version"
	printf '#!/usr/bin/env bash\necho "claude-desktop 1.1.8629-1.3.3"\n' > "$mock"
	chmod +x "$mock"
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' 'claude-desktop 1.1.8629' rpm "$mock" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "run_version_flag_test: rpm policy rejects corrupt release suffix" {
	local mock="$TEST_TMP/mock-version"
	printf '#!/usr/bin/env bash\necho "claude-desktop 1.1.8629-corrupt"\n' > "$mock"
	chmod +x "$mock"
	_pass_count=0
	_fail_count=0
	run_version_flag_test 'test-label' 'claude-desktop 1.1.8629' rpm "$mock" || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "run_launch_smoke_test: SKIP when launch tools missing" {
	_pass_count=0
	_fail_count=0
	_skip_count=0
	PATH="$TEST_TMP" run_launch_smoke_test 'test' '' /bin/true || true
	# xvfb-run、dbus-run-session、setsidがPATHに無い場合は、
	# 理由を付けてSKIPしなければならない
	# 失敗にしてはいけない
	(( _pass_count == 0 ))
	(( _fail_count == 0 ))
	(( _skip_count == 1 ))
}

@test "assert_asar_no_compile_cache: PASS when the header has no compile-cache" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" \
		'{"files":{"package.json":{"size":1,"offset":"0"}}}'
	_pass_count=0
	_fail_count=0
	assert_asar_no_compile_cache "$asar" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "assert_asar_no_compile_cache: FAIL on a root compile-cache (mutation check)" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" \
		'{"files":{"compile-cache":{"files":{"index.js.x64.jsc":{"size":1,"offset":"0"}}}}}'
	_pass_count=0
	_fail_count=0
	run assert_asar_no_compile_cache "$asar"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'compile-cache'* ]]
	assert_asar_no_compile_cache "$asar" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_asar_no_compile_cache: names a nested file under compile-cache" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" \
		'{"files":{"compile-cache":{"files":{"nested":{"files":{"a.jsc":{"size":1,"offset":"0"}}}}}}}'
	_pass_count=0
	_fail_count=0
	run assert_asar_no_compile_cache "$asar"
	[[ $output == *'compile-cache/nested/a.jsc'* ]]
	assert_asar_no_compile_cache "$asar" 2>/dev/null || true
	(( _fail_count == 1 ))
}

@test "assert_asar_unpacked_entries: PASS when the header marks files unpacked" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" \
		'{"files":{"node_modules":{"files":{"@ant":{"files":{"claude-native":{"files":{"index.js":{"size":1,"offset":"0","unpacked":true}}}}}}},"cowork-vm-service.js":{"size":1,"offset":"0","unpacked":true}}}'
	_pass_count=0
	_fail_count=0
	assert_asar_unpacked_entries "$asar" \
		'node_modules/@ant/claude-native/index.js' \
		'cowork-vm-service.js' || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "assert_asar_unpacked_entries: FAIL when a present entry is not unpacked (mutation check)" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" \
		'{"files":{"node_modules":{"files":{"@ant":{"files":{"claude-native":{"files":{"index.js":{"size":1,"offset":"0"}}}}}}}}}'
	_pass_count=0
	_fail_count=0
	run assert_asar_unpacked_entries "$asar" \
		'node_modules/@ant/claude-native/index.js'
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'not-unpacked'* ]]
	assert_asar_unpacked_entries "$asar" \
		'node_modules/@ant/claude-native/index.js' 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_asar_unpacked_entries: FAIL when the header has no entry" {
	local asar="$TEST_TMP/app.asar"
	write_test_asar "$asar" '{"files":{"package.json":{"size":1,"offset":"0"}}}'
	_pass_count=0
	_fail_count=0
	run assert_asar_unpacked_entries "$asar" 'cowork-vm-service.js'
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'missing='* ]]
	assert_asar_unpacked_entries "$asar" 'cowork-vm-service.js' \
		2>/dev/null || true
	(( _fail_count == 1 ))
}

@test "assert_elf_arch: PASS on x86_64 ELF and on amd64 spelling" {
	local elf="$TEST_TMP/pty.node"
	write_test_elf "$elf" 62
	_pass_count=0
	_fail_count=0
	assert_elf_arch "$elf" amd64 || true
	assert_elf_arch "$elf" x86_64 || true
	(( _pass_count == 2 ))
	(( _fail_count == 0 ))
}

@test "assert_elf_arch: FAIL on an aarch64 ELF checked as amd64 (mutation check)" {
	local elf="$TEST_TMP/pty.node"
	write_test_elf "$elf" 183
	_pass_count=0
	_fail_count=0
	run assert_elf_arch "$elf" amd64
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'arm64'* ]]
	[[ $output == *'amd64'* ]]
	assert_elf_arch "$elf" amd64 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_elf_arch: FAIL on a non-ELF file" {
	local elf="$TEST_TMP/pty.node"
	printf 'MZ\220\000' > "$elf"
	_pass_count=0
	_fail_count=0
	run assert_elf_arch "$elf" amd64
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'Not a valid ELF64'* ]]
	assert_elf_arch "$elf" amd64 2>/dev/null || true
	(( _fail_count == 1 ))
}

@test "assert_package_chain: PASS on the SUSE entry chain" {
	local app="$TEST_TMP/app"
	mkdir -p "$app/.vite/build"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		"require('./frame-fix-wrapper.js');" \
		"require('./.vite/build/launcher.js');" \
		> "$app/frame-fix-entry.js"
	printf '%s\n' '// original main' > "$app/.vite/build/launcher.js"
	_pass_count=0
	_fail_count=0
	assert_package_chain "$app" || true
	(( _pass_count == 1 ))
	(( _fail_count == 0 ))
}

@test "assert_package_chain: FAIL when originalMain is missing (mutation check)" {
	local app="$TEST_TMP/app"
	mkdir -p "$app"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/other.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		"require('./frame-fix-wrapper.js');" \
		"require('./.vite/build/other.js');" \
		> "$app/frame-fix-entry.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'originalMain'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_package_chain: FAIL when the originalMain file is missing" {
	local app="$TEST_TMP/app"
	mkdir -p "$app"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		"require('./frame-fix-wrapper.js');" \
		"require('./.vite/build/launcher.js');" \
		> "$app/frame-fix-entry.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'originalMain file is missing'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_package_chain: FAIL when originalMain is required before the wrapper" {
	local app="$TEST_TMP/app"
	mkdir -p "$app/.vite/build"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		"require('./.vite/build/launcher.js');" \
		"require('./frame-fix-wrapper.js');" \
		> "$app/frame-fix-entry.js"
	printf '%s\n' '// original main' > "$app/.vite/build/launcher.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'requires originalMain before frame-fix-wrapper.js'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_package_chain: FAIL when the wrapper require is commented out" {
	local app="$TEST_TMP/app"
	mkdir -p "$app/.vite/build"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		"// require('./frame-fix-wrapper.js');" \
		"require('./.vite/build/launcher.js');" \
		> "$app/frame-fix-entry.js"
	printf '%s\n' '// original main' > "$app/.vite/build/launcher.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'does not require the wrapper and originalMain at top level'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_package_chain: FAIL when the wrapper require is in a multiline comment" {
	local app="$TEST_TMP/app"
	mkdir -p "$app/.vite/build"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		'/*' \
		"require('./frame-fix-wrapper.js');" \
		'*/' \
		"require('./.vite/build/launcher.js');" \
		> "$app/frame-fix-entry.js"
	printf '%s\n' '// original main' > "$app/.vite/build/launcher.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'does not require the wrapper and originalMain at top level'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}

@test "assert_package_chain: FAIL when the wrapper require is inside an unused function" {
	local app="$TEST_TMP/app"
	mkdir -p "$app/.vite/build"
	printf '%s\n' \
		'{"main":"frame-fix-entry.js","originalMain":".vite/build/launcher.js","desktopName":"claude-desktop.desktop"}' \
		> "$app/package.json"
	printf '%s\n' \
		'function unused() {' \
		"	require('./frame-fix-wrapper.js');" \
		'}' \
		"require('./.vite/build/launcher.js');" \
		> "$app/frame-fix-entry.js"
	printf '%s\n' '// original main' > "$app/.vite/build/launcher.js"
	_pass_count=0
	_fail_count=0
	run assert_package_chain "$app"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'does not require the wrapper and originalMain at top level'* ]]
	assert_package_chain "$app" 2>/dev/null || true
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
}
