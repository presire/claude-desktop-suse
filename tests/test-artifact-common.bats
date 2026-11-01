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
