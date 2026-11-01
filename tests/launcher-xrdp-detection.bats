#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # @testごとにサブシェルで動くため、環境変数の変更は意図したもの
#
# @file launcher-xrdp-detection.bats
# @brief scripts/launcher-common.shのbuild_electron_argsがXRDPセッションを検出する様子を確認する
#
# XRDPで接続したセッションではGPU合成を無効にしないと、
# Electronのウィンドウが真っ白になる
#
# 検出は独立した2つの手掛かりを使う
#   1. XRDP_SESSION環境変数 (xrdpのセッション初期化が設定する)
#   2. loginctl show-session $XDG_SESSION_ID -p Type --value の結果がxrdp
#
# テストではloginctlをPATH上の代替に差し替え、build_electron_argsを
# 呼んだあとのelectron_args配列とログファイルを確認する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LAUNCHER_COMMON="${SCRIPT_DIR}/../scripts/launcher-common.sh"

#
# @brief loginctlの代替とログ出力先を用意し、launcher-common.shを読み込む
#
setup() {
	# PATH上の代替とログファイルを置くための分離した一時ディレクトリ
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# loginctlの代替をPATHの先頭に置く
	# MOCK_LOGINCTL_TYPEが標準出力の値、
	# MOCK_LOGINCTL_EXITが終了コードを決める
	# どちらも呼び出し時に環境変数から読むため、@testごとに個別に設定できる
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/loginctl" <<'SHIM'
#!/usr/bin/env bash
# Test shim for loginctl. Honours MOCK_LOGINCTL_TYPE and
# MOCK_LOGINCTL_EXIT from the environment.
if [[ -n ${MOCK_LOGINCTL_TRACE:-} ]]; then
	printf 'loginctl %s\n' "$*" >> "$MOCK_LOGINCTL_TRACE"
fi
if [[ ${MOCK_LOGINCTL_EXIT:-0} -ne 0 ]]; then
	exit "$MOCK_LOGINCTL_EXIT"
fi
printf '%s\n' "${MOCK_LOGINCTL_TYPE:-}"
SHIM
	chmod +x "$TEST_TMP/bin/loginctl"
	export PATH="$TEST_TMP/bin:$PATH"

	# log_message()は$log_fileへ追記する
	# 既定の出力先は一時ディレクトリ内のファイルで、中身を確認するテストは
	# このパスをそのまま読む
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"

	# 外側のシェルから引き継いだXRDPとセッションの環境変数を消し、
	# 毎回同じ状態から始める
	unset XRDP_SESSION
	unset XDG_SESSION_ID
	unset MOCK_LOGINCTL_TYPE
	unset MOCK_LOGINCTL_EXIT
	unset MOCK_LOGINCTL_TRACE

	# shellcheck disable=SC1090
	source "$LAUNCHER_COMMON"

	# build_electron_argsはis_waylandとuse_x11_on_waylandを参照する
	# XRDPの処理はこれらより前に走るが、後続の分岐が未定義変数で
	# エラーにならないよう、値を入れておく
	# shellcheck disable=SC2034 # 読み込んだlauncher-common.shのbuild_electron_argsが参照するため
	is_wayland=false
	# shellcheck disable=SC2034 # 読み込んだlauncher-common.shのbuild_electron_argsが参照するため
	use_x11_on_wayland=true
}

#
# @brief テスト用の一時ディレクトリを片付ける
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief electron_argsに指定したフラグが含まれているかを確認する
# @param $1 確認するフラグ
# @return 0 = 含まれている、1 = 含まれていない
#
args_contain() {
	local needle="$1"
	local arg
	# shellcheck disable=SC2154 # electron_argsは読み込んだlauncher-common.shのbuild_electron_argsが設定する
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && return 0
	done
	return 1
}

#
# @brief electron_argsの中で指定したフラグが現れる回数を数える
# @param $1 数えるフラグ
# @stdout 出現回数
#
args_count() {
	local needle="$1"
	local arg count=0
	# shellcheck disable=SC2154 # electron_argsは読み込んだlauncher-common.shのbuild_electron_argsが設定する
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && ((count++))
	done
	printf '%d' "$count"
}

# =============================================================================
# XRDPを検出した場合 : フラグを追加する
# =============================================================================

@test "xrdp: XRDP_SESSION set, loginctl reports x11 — flags added" {
	export XRDP_SESSION=1
	export XDG_SESSION_ID=5
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args rpm

	args_contain '--disable-gpu'
	# ソフトウェアラスタライザはGPUプロセスを無効にしたときの
	# Chromium側のフォールバックであり、併せて無効にすると起動が中断されることがある
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
	grep -q 'XRDP session detected' "$log_file"
}

@test "xrdp: XRDP_SESSION unset, loginctl reports xrdp — flags added" {
	export XDG_SESSION_ID=7
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args rpm

	args_contain '--disable-gpu'
	# ソフトウェアラスタライザはGPUプロセスを無効にしたときの
	# Chromium側のフォールバックであり、併せて無効にすると起動が中断されることがある
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
	grep -q 'XRDP session detected' "$log_file"
}

@test "xrdp: both signals fire — flags added exactly once (no dup)" {
	export XRDP_SESSION=1
	export XDG_SESSION_ID=9
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args rpm

	[[ "$(args_count '--disable-gpu')" -eq 1 ]]
	[[ "$(args_count '--disable-software-rasterizer')" -eq 0 ]]
	[[ "$(grep -c 'XRDP session detected' "$log_file")" -eq 1 ]]
}

# =============================================================================
# ローカルセッション : フラグを追加しない
# =============================================================================

@test "local: XRDP_SESSION unset, loginctl reports x11 — flags NOT added" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
	run grep -q 'XRDP session detected' "$log_file"
	[[ "$status" -ne 0 ]]
}

@test "local: XRDP_SESSION unset, loginctl reports wayland — flags NOT added" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=wayland

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: loginctl exits nonzero — flags NOT added (graceful)" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_EXIT=1

	build_electron_args rpm || true

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: XDG_SESSION_ID unset — loginctl not invoked, flags NOT added" {
	export MOCK_LOGINCTL_TRACE="$TEST_TMP/loginctl-trace.log"
	: > "$MOCK_LOGINCTL_TRACE"

	build_electron_args rpm

	# loginctlの代替は一度も呼ばれていないはず
	[[ ! -s "$MOCK_LOGINCTL_TRACE" ]]

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: XRDP_SESSION empty string — flags NOT added" {
	# [[ -n ${XRDP_SESSION:-} ]] が、exportされた空の値では偽になることを固定する
	# このテストが失敗するようになったら、ガードの意味が変わったということ
	export XRDP_SESSION=''
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}
