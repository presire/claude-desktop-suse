#!/usr/bin/env bats
#
# test-artifact-common.bats
# Tests for shared artifact-validation helpers in tests/test-artifact-common.sh.
# Locks the helper contract that test-artifact-rpm.sh and
# test-artifact-appimage.sh depend on (including assert_setuid, which
# the rpm validator invokes on chrome-sandbox), and proves the
# permission assertion is mutation-sensitive: a non-setuid fixture
# must flip it to FAIL.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	# shellcheck source=tests/test-artifact-common.sh
	source "$SCRIPT_DIR/test-artifact-common.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "all helpers invoked by RPM/AppImage validators are defined" {
	# Every helper referenced by test-artifact-rpm.sh and
	# test-artifact-appimage.sh must exist here; a missing definition
	# (the assert_setuid gap this suite closes) would otherwise surface
	# only at install-test time as a bash 'command not found'.
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
	# A non-setuid fixture must trip the assertion: if this stays PASS,
	# the guard is decoration and a repack that drops chrome-sandbox's
	# setuid bit would ship undetected.
	(( _pass_count == 0 ))
	(( _fail_count == 1 ))
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
	# The function must SKIP (pass with skip reason) when xvfb-run /
	# dbus-run-session / setsid are not in PATH — never fail.
	(( _pass_count == 0 ))
	(( _fail_count == 0 ))
	(( _skip_count == 1 ))
}
