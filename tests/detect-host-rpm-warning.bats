#!/usr/bin/env bats
#
# detect-host-rpm-warning.bats
# The "Building .rpm package on non-SUSE system" warning depends on
# distro_family, which detect_distro() sets after parse_arguments() has
# run. The warning must come from detect_distro(), never from argument
# parsing (where distro_family is still empty and the warning printed
# "non-SUSE system ()" on SUSE hosts).

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	cd "$TEST_TMP" || return 1
	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=scripts/setup/detect-host.sh
	source "$SCRIPT_DIR/setup/detect-host.sh"
	unset distro_family
}

teardown() {
	cd / || return 1
	rm -rf "$TEST_TMP"
}

@test "parse_arguments --build rpm does not print the non-SUSE warning" {
	run parse_arguments --build rpm --clean yes
	[[ $status -eq 0 ]]
	[[ $output != *'non-SUSE system'* ]]
}

@test "detect_distro owns the non-SUSE RPM warning" {
	local body
	body=$(declare -f detect_distro)
	[[ $body == *'non-SUSE system'* ]]
	body=$(declare -f parse_arguments)
	[[ $body != *'non-SUSE system'* ]]
}

@test "detect_distro warns about an RPM build only off SUSE" {
	local is_suse=0
	if [[ -f /etc/SUSE-brand || -f /etc/SuSE-release ]] ||
		grep -qi 'suse\|opensuse' /etc/os-release 2>/dev/null; then
		is_suse=1
	fi

	build_format='rpm' run detect_distro
	[[ $status -eq 0 ]]
	if (( is_suse )); then
		[[ $output != *'non-SUSE system'* ]]
	else
		[[ $output == *'non-SUSE system (unknown)'* ]]
	fi

	build_format='appimage' run detect_distro
	[[ $status -eq 0 ]]
	[[ $output != *'non-SUSE system'* ]]
}
