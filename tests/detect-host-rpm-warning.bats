#!/usr/bin/env bats
#
# @file detect-host-rpm-warning.bats
# @brief SUSE以外でrpmをビルドしようとしたときの警告を、どこが出すかのテスト
#
# 警告の要否はdistro_familyに依存し、その値はdetect_distro()が設定する
# 引数の解析時点ではdistro_familyはまだ空で、
# SUSEのホストでも「non-SUSE system ()」と表示されていた
# そのため警告は引数の解析ではなくdetect_distro()だけが出すようにする
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"  # 検証対象のスクリプトがあるディレクトリ

#
# @brief テスト用の一時ディレクトリへ移動し、検証対象のスクリプトを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global SCRIPT_DIR 検証対象のスクリプトがあるディレクトリ (参照のみ)
# @note ディストリビューション検出前の状態から始めるためdistro_familyを消す
#
setup() {
	TEST_TMP=$(mktemp -d)
	cd "$TEST_TMP" || return 1
	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=scripts/setup/detect-host.sh
	source "$SCRIPT_DIR/setup/detect-host.sh"
	unset distro_family
}

#
# @brief 元のディレクトリへ戻り、テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
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
