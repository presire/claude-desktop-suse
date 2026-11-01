#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # @testごとにサブシェルで動くため、環境変数の変更は意図したもの
#
# @file launcher-disable-gpu.bats
# @brief scripts/launcher-common.shのbuild_electron_argsがCLAUDE_DISABLE_GPUを扱う様子を確認する
#
# 環境変数CLAUDE_DISABLE_GPUは、#583で追跡しているChromiumのGPUプロセスが
# FATALで起動に失敗する問題を避けるために、利用者が明示的に選ぶ回避策である
# CLAUDE_DISABLE_GPU=1を指定した場合は--disable-gpuだけを追加する
# ソフトウェアラスタライザはGPUを無効にしたときのフォールバックとして
# 残す必要があるため、併せて無効にはしない
# XRDPセッションと同時に成立した場合も、同じフラグを二重に並べないことを確認する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"               # このテストファイルがあるディレクトリ
LAUNCHER_COMMON="${SCRIPT_DIR}/../scripts/launcher-common.sh"                # 検証対象のランチャー共通処理

#
# @brief テスト用の一時ディレクトリを用意し、loginctlの代替を置いてからlauncher-common.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global log_file 起動ログの書き出し先 (本関数で設定する)
# @global PATH loginctlの代替を先頭に追加する (本関数で変更する)
# @note loginctlの代替はXRDPではないセッションを既定で返すため、
#       テストがMOCK_LOGINCTL_TYPEを上書きしない限り判定材料はCLAUDE_DISABLE_GPUだけになる
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# 実機のloginctlに左右されないよう、PATHの先頭に差し替え用のスクリプトを置く
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/loginctl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_LOGINCTL_TYPE:-x11}"
SHIM
	chmod +x "$TEST_TMP/bin/loginctl"
	export PATH="$TEST_TMP/bin:$PATH"

	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"

	unset CLAUDE_DISABLE_GPU
	unset XRDP_SESSION
	unset XDG_SESSION_ID
	unset MOCK_LOGINCTL_TYPE

	# shellcheck disable=SC1090
	source "$LAUNCHER_COMMON"

	# shellcheck disable=SC2034 # 読み込んだlauncher-common.shのbuild_electron_argsが参照する
	is_wayland=false
	# shellcheck disable=SC2034 # 読み込んだlauncher-common.shのbuild_electron_argsが参照する
	use_x11_on_wayland=true
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
# @note setupが途中で失敗してTEST_TMPが未定義の場合でも失敗せずに終わるよう、
#       存在を確認してから削除する
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief electron_argsに指定したフラグが含まれているかを確認する
# @param $1 探すフラグ
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
# CLAUDE_DISABLE_GPU=1を指定したときはフラグを追加する
# =============================================================================

@test "disable-gpu: CLAUDE_DISABLE_GPU=1 adds flags + logs message" {
	export CLAUDE_DISABLE_GPU=1

	build_electron_args rpm

	args_contain '--disable-gpu'
	# ソフトウェアラスタライザはGPUプロセスを無効にしたときの
	# Chromium側のフォールバックであり、併せて無効にすると起動が中断されることがある
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
	grep -q 'CLAUDE_DISABLE_GPU=1' "$log_file"
}

# =============================================================================
# XRDPセッションと重なった場合でもフラグを重複させない
# =============================================================================

@test "disable-gpu: with XRDP_SESSION, flags added exactly once (no dup)" {
	export CLAUDE_DISABLE_GPU=1
	export XRDP_SESSION=1
	export XDG_SESSION_ID=5
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args rpm

	[[ "$(args_count '--disable-gpu')" -eq 1 ]]
	[[ "$(args_count '--disable-software-rasterizer')" -eq 0 ]]
	# 2つの検出結果はそれぞれ診断に使えるためどちらもログに残すが、
	# electron_argsへ入れるフラグは1組だけにする
	grep -q 'XRDP session detected' "$log_file"
	grep -q 'CLAUDE_DISABLE_GPU=1' "$log_file"
}

# =============================================================================
# 指定がない状態ではフラグを追加しない
# =============================================================================

@test "disable-gpu: unset — flags NOT added" {
	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: empty string — flags NOT added" {
	export CLAUDE_DISABLE_GPU=''

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: =0 — flags NOT added (only literal '1' opts in)" {
	export CLAUDE_DISABLE_GPU=0

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: =true — flags NOT added (no boolean aliases)" {
	# 判定が値の完全一致であることを固定するテスト
	# 別名を受け付けるように変える場合は、このテストも合わせて更新する
	# 完全一致のみという扱いはCLAUDE_USE_WAYLANDの既存の判定に揃えている
	export CLAUDE_DISABLE_GPU=true

	build_electron_args rpm

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

# =============================================================================
# 直前の起動がGPUプロセスのFATALで終わっていたかの検出
# =============================================================================

@test "gpu scan: detects paired signatures in a single section" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -eq 0 ]]
}

@test "gpu scan: selects the penultimate section" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start ---
Current launch is healthy.
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -eq 0 ]]
}

@test "gpu scan: retains the middle section across three launches" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
First launch was healthy.
--- Claude Desktop AppImage Start ---
Previous launch hit GPU process FATAL - disabling GPU
--- Claude Desktop Launcher Start ---
Current launch is healthy.
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -eq 0 ]]
}

@test "gpu scan: rejects incomplete GPU signature" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -ne 0 ]]
}

# ログは上流のclaude-desktop-debian #946から移植した仕組みで切り替わる
# setup_logging()はサイズ上限を超えたログを、セッションの見出しを書く前に
# launcher.log.1へ退避するため、その回の直前の起動内容は.1側に残る

@test "gpu scan: finds the previous launch in launcher.log.1 after rotation" {
	cat > "$log_file.1" <<'LOG'
--- Claude Desktop Launcher Start ---
Older healthy launch.
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
LOG
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -eq 0 ]]
}

@test "gpu scan: healthy previous launch in launcher.log.1 is not a hit" {
	cat > "$log_file.1" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start ---
Recovered launch was healthy.
LOG
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -ne 0 ]]
}

@test "gpu scan: ignores launcher.log.1 once the live log has two sections" {
	cat > "$log_file.1" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
LOG
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
Previous launch was healthy.
--- Claude Desktop Launcher Start ---
LOG

	run _previous_launch_hit_gpu_fatal
	[[ $status -ne 0 ]]
}

@test "gpu scan: empty live log without launcher.log.1 is not a hit" {
	: > "$log_file"
	rm -f "$log_file.1"

	run _previous_launch_hit_gpu_fatal
	[[ $status -eq 1 ]]
}
