#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2317,SC2329  # fixtureの$はリテラル、各BATSの@testは独自のサブシェルで走りヘルパーを間接的に呼ぶ (SC2317はshellcheck 0.10未満で出る)
#
# @file launcher-common.bats
# @brief scripts/launcher-common.shのランチャー補助関数を検証する
#
# ログ出力、表示バックエンドの判定、Electron引数の組み立て、
# 残留プロセスとソケットの後始末、設定のバックアップまで、
# 起動処理が前提とする補助関数をまとめて確認する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

#
# @brief electron_argsに指定の値が含まれるかを調べる
# @param $1 探す値 (グロブパターンも可、例 : '*WaylandWindowDecorations*')
# @global electron_args (参照のみ) build_electron_argsが組み立てた引数
# @return 0 = 見つかった、1 = 見つからない
#
has_electron_arg() {
	local pattern="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		# shellcheck disable=SC2254,SC2053 # グロブパターンとして意図的に比較する
		[[ $arg == $pattern ]] && return 0
	done
	return 1
}

#
# @brief 指定の終了コードを返すunshareのスタブを置く
# @param $1 スタブが返す終了コード
# @global _CLAUDE_UNSHARE (本関数で設定する) スタブのパス
# @global TEST_TMP (参照のみ) スタブと引数ログの置き場所
# @note 失敗時はseccompで拒否されたときと同じエラーを出力し、
#       引数は$TEST_TMP/unshare.argsに残す
#
_stub_unshare() {
	mkdir -p "$TEST_TMP/bin"
	cat > "$_CLAUDE_UNSHARE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/unshare.args"
[[ $1 -eq 0 ]] || echo 'unshare: unshare failed: Operation not permitted' >&2
exit $1
EOF
	chmod +x "$_CLAUDE_UNSHARE"
}

#
# @brief ユーザー名前空間のプローブにAppArmorのsysctl制限を報告させる
# @global _CLAUDE_USERNS_AA (参照のみ) 制限状態を書き込むファイル
#
_restrict_userns() {
	echo 1 > "$_CLAUDE_USERNS_AA"
}

#
# @brief PATHの先頭にdbus-sendのスタブを置く
# @param $1 スタブの種類 (kwallet6 = 応答する、secrets-ok = kwalletd6以外なら応答する、他は失敗)
# @global TEST_TMP (参照のみ) スタブの置き場所
# @note PATHの先頭に入れるため、以降のdbus-send呼び出しはこのスタブが受ける
#
_stub_dbus_send() {
	mkdir -p "$TEST_TMP/bin"
	case "${1:-fail}" in
		# kwallet6が応答する形
		kwallet6)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
echo 'boolean true'
STUB
			;;
		# kwallet6以外のパスワードストアが応答する形
		secrets-ok)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *kwalletd6* ]] && exit 1
exit 0
STUB
			;;
		# どのバックエンドも応答しない
		*)
			printf '#!/usr/bin/env bash\nexit 1\n' \
				> "$TEST_TMP/bin/dbus-send"
			;;
	esac
	chmod +x "$TEST_TMP/bin/dbus-send"
	export PATH="$TEST_TMP/bin:$PATH"
}

#
# @brief テストごとの隔離環境を作り、ランチャーの補助関数を読み込む
# @global TEST_TMP (本関数で設定する) テスト専用ディレクトリ
# @global HOME / XDG_CACHE_HOME / XDG_CONFIG_HOME / XDG_RUNTIME_DIR (本関数で設定する) 一時領域へ隔離する
# @global _CLAUDE_USERNS_MAX / _CLAUDE_USERNS_CLONE / _CLAUDE_USERNS_AA (本関数で設定する) プローブ用の擬似sysctl
# @global _CLAUDE_UNSHARE (本関数で設定する) unshareのスタブのパス
# @note window manager classは@@WM_CLASS@@をClaudeに置換してから読み込む
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# ファイルシステムに触れる関数をすべて一時ディレクトリへ向ける
	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	export XDG_RUNTIME_DIR="$TEST_TMP/run"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"

	# ホストの表示環境が漏れないよう、ディスプレイとWaylandの変数を消す
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset CLAUDE_USE_WAYLAND
	unset NIRI_SOCKET
	unset XDG_CURRENT_DESKTOP
	unset XDG_SESSION_TYPE
	unset CLAUDE_MENU_BAR
	unset CLAUDE_TITLEBAR_STYLE
	unset COWORK_VM_BACKEND
	unset ELECTRON_USE_SYSTEM_TITLE_BAR
	unset GTK_IM_MODULE
	unset XMODIFIERS
	unset QT_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_DISABLE_GPU
	unset CLAUDE_PASSWORD_STORE
	unset CLAUDE_FORCE_SANDBOX
	unset CLAUDE_TRAY_USE_DARK_ICON

	# ホストのuserns sysctlをAppImageのサンドボックス判定から切り離す (#884)
	# 既定は名前空間サンドボックスを開始できるホスト
	export _CLAUDE_USERNS_MAX="$TEST_TMP/userns-max"
	export _CLAUDE_USERNS_CLONE="$TEST_TMP/userns-clone"
	export _CLAUDE_USERNS_AA="$TEST_TMP/userns-aa"
	echo 63432 > "$_CLAUDE_USERNS_MAX"
	echo 1 > "$_CLAUDE_USERNS_CLONE"
	echo 0 > "$_CLAUDE_USERNS_AA"
	export _CLAUDE_UNSHARE="$TEST_TMP/bin/unshare"
	_stub_unshare 0

	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/launcher-common.sh"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/doctor.sh"
	sed -i 's/@@WM_CLASS@@/Claude/' "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
}

#
# @brief テスト専用ディレクトリを削除する
# @return 常に0 (後片付けの失敗でテスト結果を変えない)
#
teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# setup_logging : ログディレクトリとログファイルを用意する
# =============================================================================

@test "setup_logging: creates log directory and sets log_file" {
	run setup_logging
	[[ $status -eq 0 ]]
	[[ -d "$XDG_CACHE_HOME/claude-desktop-suse" ]]
}

@test "setup_logging: sets log_file under XDG_CACHE_HOME" {
	setup_logging
	[[ $log_file == "$XDG_CACHE_HOME/claude-desktop-suse/launcher.log" ]]
}

@test "setup_logging: falls back to HOME/.cache when XDG_CACHE_HOME unset" {
	unset XDG_CACHE_HOME
	setup_logging
	[[ $log_dir == "$HOME/.cache/claude-desktop-suse" ]]
	[[ -d "$HOME/.cache/claude-desktop-suse" ]]
}

# =============================================================================
# log_message : タイムスタンプ付きのログ行を書き出す
# =============================================================================

@test "log_message: appends message to log file" {
	setup_logging
	log_message "test message one"
	log_message "test message two"
	[[ -f $log_file ]]
	run cat "$log_file"
	[[ "${lines[0]}" == "test message one" ]]
	[[ "${lines[1]}" == "test message two" ]]
}

@test "log_message: joins multiple arguments" {
	setup_logging
	log_message "first fragment" "second fragment"

	run cat "$log_file"
	[[ $status -eq 0 ]]
	[[ $output == "first fragment second fragment" ]]
}

@test "log_message: is a no-op before logging is configured" {
	unset log_file

	run log_message "message before setup"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "setup_logging: rotates oversized log and keeps two generations" {
	local log_path="$XDG_CACHE_HOME/claude-desktop-suse/launcher.log"
	mkdir -p "$(dirname "$log_path")"
	printf 'oldest\n' > "$log_path.2"
	printf 'older\n' > "$log_path.1"
	truncate -s 5242881 "$log_path"

	run setup_logging
	[[ $status -eq 0 ]]
	[[ -f $log_path.1 ]]
	[[ -f $log_path.2 ]]
	[[ ! -f $log_path.3 ]]
	[[ $(stat -c '%s' "$log_path.1") -eq 5242881 ]]
	[[ $(<"$log_path.2") == 'older' ]]
}

@test "setup_logging: leaves log below rotation threshold unchanged" {
	local log_path="$XDG_CACHE_HOME/claude-desktop-suse/launcher.log"
	mkdir -p "$(dirname "$log_path")"
	printf 'small\n' > "$log_path"

	run setup_logging
	[[ $status -eq 0 ]]
	[[ ! -e $log_path.1 ]]
	[[ $(<"$log_path") == 'small' ]]
}

# =============================================================================
# log_session_env : セッション環境変数を1つのブロックにまとめて記録する
# =============================================================================

@test "log_session_env: emits env={ ... } block with all required keys" {
	setup_logging
	XDG_SESSION_TYPE='wayland'
	WAYLAND_DISPLAY='wayland-0'
	DISPLAY=':0'
	XDG_CURRENT_DESKTOP='KDE'
	GTK_IM_MODULE='ibus'
	# shellcheck disable=SC2034 # log_session_env()の${!key}経由で間接的に読まれる
	XMODIFIERS='@im=ibus'
	# shellcheck disable=SC2034 # log_session_env()の${!key}経由で間接的に読まれる
	QT_IM_MODULE='ibus'
	CLAUDE_USE_WAYLAND='1'
	CLAUDE_TITLEBAR_STYLE='hybrid'
	CLAUDE_PASSWORD_STORE='basic'
	CLAUDE_GTK_IM_MODULE='xim'
	CLAUDE_DISABLE_GPU='1'
	log_session_env

	run cat "$log_file"
	# 行全体の完全一致なら、ブロックの構造 (開閉の波括弧が単独行にあること) と
	# キーごとの書式を1回の比較で固定できる
	[[ "${lines[0]}"  == 'env={' ]]
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=wayland' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=wayland-0' ]]
	[[ "${lines[3]}"  == '  DISPLAY=:0' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=KDE' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=ibus' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=@im=ibus' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=ibus' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=1' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=hybrid' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=basic' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=xim' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=1' ]]
	[[ "${lines[13]}" == '  CLAUDE_TRAY_USE_DARK_ICON=' ]]
	[[ "${lines[14]}" == '}' ]]
}

@test "log_session_env: unset/empty values render as 'KEY=' (no value)" {
	setup_logging
	# setup()で他の変数はすべてunsetしてあり、ここでは空文字列の分岐だけを確認する
	# 空文字列は未設定と同じ扱いでなければならない
	GTK_IM_MODULE=''
	unset CLAUDE_PASSWORD_STORE
	log_session_env

	run cat "$log_file"
	# 行全体の完全一致で、=より後ろに値がないことまで確かめる
	# *'KEY='* のような部分一致ではKEY=valueにも一致してしまう
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=' ]]
	[[ "${lines[3]}"  == '  DISPLAY=' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=' ]]
}

# =============================================================================
# check_display : DISPLAYとWAYLAND_DISPLAYの組み合わせを確認する
# =============================================================================

@test "check_display: fails when no display variables set" {
	unset DISPLAY
	unset WAYLAND_DISPLAY
	run check_display
	[[ $status -ne 0 ]]
}

@test "check_display: succeeds with DISPLAY set" {
	DISPLAY=":0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with WAYLAND_DISPLAY set" {
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with both set" {
	DISPLAY=":0"
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

# =============================================================================
# detect_display_backend : X11とWaylandのどちらで起動するかを決める
# =============================================================================

@test "detect_display_backend: X11 session sets is_wayland=false" {
	DISPLAY=":0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == false ]]
}

@test "detect_display_backend: Wayland session sets is_wayland=true" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
}

@test "detect_display_backend: defaults to XWayland on Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: CLAUDE_USE_WAYLAND=1 forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via NIRI_SOCKET forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via XDG_CURRENT_DESKTOP forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri in colon-separated XDG_CURRENT_DESKTOP" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri:GNOME"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri case-insensitive detection" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="NIRI"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: non-Niri Wayland keeps XWayland default" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="sway"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: Niri not forced when CLAUDE_USE_WAYLAND already set" {
	# CLAUDE_USE_WAYLAND=1がすでにネイティブを強制しており、Niriの判定は競合しない
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

# =============================================================================
# _userns_sandbox_block_reason : ユーザー名前空間のサンドボックスを使えない理由を返す (#884)
# =============================================================================

@test "_userns_sandbox_block_reason: userns available - returns 1, no output" {
	run _userns_sandbox_block_reason
	[[ $status -eq 1 ]]
	[[ -z $output ]]
}

@test "_userns_sandbox_block_reason: max_user_namespaces=0 - blocked" {
	echo 0 > "$_CLAUDE_USERNS_MAX"
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ $output == *'user.max_user_namespaces=0'* ]]
}

@test "_userns_sandbox_block_reason: max_user_namespaces missing (no CONFIG_USER_NS) - blocked" {
	rm -f "$_CLAUDE_USERNS_MAX"
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ $output == *'user namespaces disabled'* ]]
}

@test "_userns_sandbox_block_reason: unprivileged_userns_clone=0 - blocked" {
	echo 0 > "$_CLAUDE_USERNS_CLONE"
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ $output == *'kernel.unprivileged_userns_clone=0'* ]]
}

@test "_userns_sandbox_block_reason: AppArmor restriction on - blocked" {
	_restrict_userns
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ $output == *'restricted by AppArmor'* ]]
}

@test "_userns_sandbox_block_reason: sysctls pass - creates the zygote's namespaces" {
	run _userns_sandbox_block_reason
	[[ $status -eq 1 ]]
	[[ $(<"$TEST_TMP/unshare.args") == '--user --map-root-user --pid --net --fork true' ]]
}

@test "_userns_sandbox_block_reason: sysctls pass but unshare fails (seccomp) - blocked" {
	# Dockerの既定seccompプロファイルを模す
	# sysctlは問題ないように見えるが、ユーザー名前空間の作成は拒否される
	_stub_unshare 1
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ $output == 'user namespace creation failed (unshare: unshare failed: Operation not permitted)' ]]
}

@test "_userns_sandbox_block_reason: unshare missing - sysctl result stands" {
	export _CLAUDE_UNSHARE="$TEST_TMP/no-unshare"
	run _userns_sandbox_block_reason
	[[ $status -eq 1 ]]
	[[ -z $output ]]
}

@test "_userns_sandbox_block_reason: a sysctl block skips the unshare probe" {
	_restrict_userns
	run _userns_sandbox_block_reason
	[[ $status -eq 0 ]]
	[[ ! -e $TEST_TMP/unshare.args ]]
}

@test "_userns_sandbox_block_reason: hung probe is time-bounded" {
	command -v timeout &> /dev/null || skip 'timeout not installed'
	printf '#!/usr/bin/env bash\nsleep 30\n' > "$_CLAUDE_UNSHARE"
	chmod +x "$_CLAUDE_UNSHARE"
	export _CLAUDE_UNSHARE_TIMEOUT=1
	local start end
	start=$(date +%s)
	run _userns_sandbox_block_reason
	end=$(date +%s)
	[[ $status -eq 0 ]]
	[[ $output == *'user namespace creation failed'* ]]
	(( end - start < 15 ))
}

# =============================================================================
# build_electron_args : Electronの起動引数を組み立てる
# =============================================================================

@test "build_electron_args: X11 rpm - only CustomTitlebar disabled" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	has_electron_arg '--class=Claude'
	has_electron_arg '--password-store=basic'
	# shellcheck disable=SC2314 # テストの最後のコマンドなので!の戻り値がそのまま結果になる
	run has_electron_arg '--no-sandbox'
	[[ $status -ne 0 ]]
}

@test "build_electron_args: X11 appimage with working userns - keeps sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args appimage
	run has_electron_arg '--no-sandbox'
	[[ $status -ne 0 ]]
}

@test "build_electron_args: X11 appimage with blocked userns - adds --no-sandbox + logs reason" {
	is_wayland=false
	_restrict_userns
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
	grep -q 'Chromium sandbox disabled: user namespaces restricted by AppArmor' \
		"$log_file"
}

@test "build_electron_args: Wayland XWayland rpm - includes x11 platform and no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args rpm
	has_electron_arg '--ozone-platform=x11'
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native rpm - includes wayland platform flags" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--ozone-platform=wayland'
	has_electron_arg '--enable-wayland-ime'
	has_electron_arg '*WaylandWindowDecorations*'
}

@test "build_electron_args: Wayland appimage with working userns - keeps sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args appimage
	has_electron_arg '--ozone-platform=x11'
	run has_electron_arg '--no-sandbox'
	[[ $status -ne 0 ]]
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX=1 keeps rpm sandbox on Wayland" {
	is_wayland=true
	use_x11_on_wayland=true
	export CLAUDE_FORCE_SANDBOX=1
	setup_logging
	build_electron_args rpm
	run has_electron_arg '--no-sandbox'
	[[ $status -ne 0 ]]
	grep -q 'CLAUDE_FORCE_SANDBOX=1' "$log_file"
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX=1 keeps AppImage sandbox when probe says blocked" {
	is_wayland=true
	use_x11_on_wayland=false
	_restrict_userns
	export CLAUDE_FORCE_SANDBOX=1
	setup_logging
	build_electron_args appimage
	run has_electron_arg '--no-sandbox'
	[[ $status -ne 0 ]]
	grep -q 'CLAUDE_FORCE_SANDBOX=1 - keeping Chromium sandbox enabled despite' \
		"$log_file"
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX other values keep --no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	export CLAUDE_FORCE_SANDBOX=true
	setup_logging
	build_electron_args rpm
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native includes text-input-version=3" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--wayland-text-input-version=3'
}

# =============================================================================
# _detect_password_store : 利用できるパスワードストアを選ぶ
# =============================================================================

@test "_detect_password_store: CLAUDE_PASSWORD_STORE env var wins without calling dbus-send" {
	CLAUDE_PASSWORD_STORE='mystore'
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'mystore' ]]
}

@test "_detect_password_store: falls back to kwallet6 when kwallet6 dbus-send call succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send kwallet6
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'kwallet6' ]]
}

@test "_detect_password_store: falls back to gnome-libsecret when kwallet6 fails but secrets ping succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send secrets-ok
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'gnome-libsecret' ]]
}

@test "_detect_password_store: falls back to basic when both dbus-send calls fail" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'basic' ]]
}

# =============================================================================
# 補助関数 : ユーザー設定ファイルを書き出す
# =============================================================================

#
# @brief launcher設定ファイルへ指定の行を書き出す
# @param $@ 書き出す行 (KEY=VALUE形式)
#
_write_launcher_cfg() {
	mkdir -p "$XDG_CONFIG_HOME/claude-desktop-suse"
	printf '%s\n' "$@" \
		> "$XDG_CONFIG_HOME/claude-desktop-suse/environment"
}

# =============================================================================
# load_launcher_config : ユーザー設定ファイルを読み込む
# =============================================================================

@test "load_launcher_config: every SUSE allowlisted key round-trips" {
	_write_launcher_cfg \
		'CLAUDE_USE_WAYLAND=1' \
		'CLAUDE_PASSWORD_STORE=gnome-libsecret' \
		'CLAUDE_GTK_IM_MODULE=xim' \
		'CLAUDE_DISABLE_GPU=1' \
		'CLAUDE_TITLEBAR_STYLE=native' \
		'CLAUDE_MENU_BAR=visible' \
		'CLAUDE_KEEP_AWAKE=0' \
		'CLAUDE_FORCE_SANDBOX=1' \
		'CLAUDE_TRAY_USE_DARK_ICON=1' \
		'COWORK_VM_BACKEND=bwrap'
	load_launcher_config
	[[ $CLAUDE_TRAY_USE_DARK_ICON == '1' ]]
	[[ $CLAUDE_USE_WAYLAND == '1' ]]
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
	[[ $CLAUDE_GTK_IM_MODULE == 'xim' ]]
	[[ $CLAUDE_DISABLE_GPU == '1' ]]
	[[ $CLAUDE_TITLEBAR_STYLE == 'native' ]]
	[[ $CLAUDE_MENU_BAR == 'visible' ]]
	[[ $CLAUDE_KEEP_AWAKE == '0' ]]
	[[ $CLAUDE_FORCE_SANDBOX == '1' ]]
	[[ $COWORK_VM_BACKEND == 'bwrap' ]]
}

@test "load_launcher_config: logs applied and ignored keys" {
	setup_logging
	_write_launcher_cfg 'CLAUDE_DISABLE_GPU=1' 'CLAUDE_TYPO=1'
	load_launcher_config
	grep -q "Config: CLAUDE_DISABLE_GPU=1 (from " "$log_file"
	grep -q "Config: ignoring unrecognized key 'CLAUDE_TYPO'" "$log_file"
	[[ -z ${CLAUDE_TYPO:-} ]]
}

@test "load_launcher_config: ignores keys outside the allowlist" {
	unset LD_PRELOAD
	_write_launcher_cfg 'LD_PRELOAD=/tmp/evil.so'
	load_launcher_config
	[[ -z ${LD_PRELOAD:-} ]]
}

@test "load_launcher_config: existing environment wins over config" {
	export CLAUDE_TITLEBAR_STYLE='hidden'
	_write_launcher_cfg 'CLAUDE_TITLEBAR_STYLE=native'
	load_launcher_config
	[[ $CLAUDE_TITLEBAR_STYLE == 'hidden' ]]
}

@test "load_launcher_config: missing file is a silent no-op" {
	run load_launcher_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "load_launcher_config: skips comments and blank lines" {
	_write_launcher_cfg \
		'# a comment' \
		'' \
		'   ' \
		'  # an indented comment' \
		'CLAUDE_MENU_BAR=visible'
	load_launcher_config
	[[ $CLAUDE_MENU_BAR == 'visible' ]]
}

@test "load_launcher_config: trims whitespace and surrounding quotes" {
	_write_launcher_cfg ' CLAUDE_PASSWORD_STORE = "gnome-libsecret" '
	load_launcher_config
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
}

@test "setup_electron_env: sets ELECTRON_FORCE_IS_PACKAGED" {
	setup_electron_env
	[[ $ELECTRON_FORCE_IS_PACKAGED == 'true' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in hybrid mode (default)" {
	setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in native mode" {
	CLAUDE_TITLEBAR_STYLE=native setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR in hidden mode" {
	CLAUDE_TITLEBAR_STYLE=hidden setup_electron_env
	[[ -z ${ELECTRON_USE_SYSTEM_TITLE_BAR:-} ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR for invalid value (falls back to hybrid)" {
	CLAUDE_TITLEBAR_STYLE=garbage setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set propagates to GTK_IM_MODULE" {
	setup_logging
	# shellcheck disable=SC2030 # Batsの@testはサブシェルなので、ここでの変更は意図したもの
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	[[ $GTK_IM_MODULE == 'xim' ]]
	# 上書きしたことは利用者が効果を確認できるようログに残す
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: ibus -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set logs <unset> when GTK_IM_MODULE was unset" {
	setup_logging
	# GTK_IM_MODULEはsetup()でunsetしてある
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	# shellcheck disable=SC2031 # 値は同じBatsテストのサブシェル内で確認するため意図したもの
	[[ $GTK_IM_MODULE == 'xim' ]]
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: <unset> -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE unset leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	# CLAUDE_GTK_IM_MODULEもsetup()でunsetしてある
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	# 上書きのログ行が出ないことを確認する
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE empty leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE=''
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

# =============================================================================
# _resolve_titlebar_style : タイトルバーの表示方式を決める
# =============================================================================

@test "_resolve_titlebar_style: returns 'hybrid' when unset" {
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'hybrid' for hybrid" {
	CLAUDE_TITLEBAR_STYLE=hybrid
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'native' for native" {
	CLAUDE_TITLEBAR_STYLE=native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: returns 'hidden' for hidden" {
	CLAUDE_TITLEBAR_STYLE=hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: case-insensitive (HYBRID)" {
	CLAUDE_TITLEBAR_STYLE=HYBRID
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Native)" {
	CLAUDE_TITLEBAR_STYLE=Native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Hidden)" {
	CLAUDE_TITLEBAR_STYLE=Hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for invalid value" {
	CLAUDE_TITLEBAR_STYLE=garbage
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for empty value" {
	CLAUDE_TITLEBAR_STYLE=''
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

# =============================================================================
# build_electron_args : タイトルバー方式ごとのフラグ選択
# =============================================================================

@test "build_electron_args: hybrid mode (default) disables CustomTitlebar" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314 # テストの最後のコマンドなので!の戻り値がそのまま結果になる
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: native mode disables CustomTitlebar" {
	CLAUDE_TITLEBAR_STYLE=native
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314 # テストの最後のコマンドなので!の戻り値がそのまま結果になる
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: hidden mode enables WindowControlsOverlay" {
	CLAUDE_TITLEBAR_STYLE=hidden
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--enable-features=WindowControlsOverlay'
	# shellcheck disable=SC2314 # テストの最後のコマンドなので!の戻り値がそのまま結果になる
	! has_electron_arg '--disable-features=CustomTitlebar'
}

@test "build_electron_args: invalid titlebar value falls back to hybrid flags" {
	CLAUDE_TITLEBAR_STYLE=garbage
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
}

# =============================================================================
# cleanup_stale_lock : 終了済みプロセスが残したSingletonLockを片付ける
# =============================================================================

@test "cleanup_stale_lock: no lock file - returns 0" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_lock: removes stale lock (dead PID)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# ほぼ確実に存在しないPID 99999999を使う
	ln -s "myhost-99999999" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ ! -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock held by a running Claude Desktop" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# /proc/PID/exeはシンボリックリンクを解決するため、実在のバイナリを
	# claude-desktopという名前を含むパスへコピーする (RPMのElectronツリーと同じ形)
	local holder_dir="$TEST_TMP/usr/lib/claude-desktop/node_modules/electron/dist"
	mkdir -p "$holder_dir"
	cp "$(command -v sleep)" "$holder_dir/electron"
	"$holder_dir/electron" 30 3>&- &
	local holder=$!
	ln -s "myhost-$holder" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	kill "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true
	# ロックは残っているはず
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock whose live PID is not recognized" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# 起動中の保持者を特定できない場合 (リネームされたAppImage、別ビルド、
	# PIDの再利用) はChromiumの判断に任せる
	sleep 30 3>&- &
	local other=$!
	ln -s "myhost-$other" "$config_dir/SingletonLock"
	setup_logging
	# setup_loggingはログファイルを作らないため、ここでは何も記録されないはず
	: > "$log_file"
	cleanup_stale_lock
	kill "$other" 2>/dev/null || true
	wait "$other" 2>/dev/null || true
	[[ -L "$config_dir/SingletonLock" ]]
	[[ $(< "$log_file") != *'SingletonLock'* ]]
}

@test "cleanup_stale_lock: handles non-numeric PID in lock target" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	ln -s "myhost-notanumber" "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# ロックは残っているはず (PIDが数値でない場合は関数が途中で戻る)
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: handles regular file (not symlink)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	echo "not a symlink" > "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# 通常のファイルは変更しない
	[[ -f "$config_dir/SingletonLock" ]]
}

# =============================================================================
# cleanup_stale_cowork_socket : Coworkデーモンが残したソケットを片付ける
# =============================================================================

@test "cleanup_stale_cowork_socket: no socket - returns 0" {
	run cleanup_stale_cowork_socket
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_cowork_socket: removes stale socket file" {
	# -Sで判定できるよう、pythonで実際のunixソケットを作る
	# ソケット名に見える通常ファイルでは判定できない
	local sock="$XDG_RUNTIME_DIR/cowork-vm-service.sock"
	python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()
" "$sock" 2>/dev/null || skip "Cannot create test unix socket"

	# ホストのプロセス状態から切り離すためpgrepをスタブ化する
	# 開発機で本物のcowork-vm-serviceが動いていると、
	# 「デーモンが生きているのでソケットは残す」分岐に入ってしまう
	pgrep() { return 1; }

	setup_logging
	cleanup_stale_cowork_socket
	[[ ! -S "$sock" ]]
}

# =============================================================================
# Coworkデーモンと補助プロセスの後始末 : argvの形で対象を見分ける
# =============================================================================

#
# @brief 偽のCoworkデーモンを起動する
# @global fake_daemon (本関数で設定する) 起動したプロセスのPID
# @note asarからのforkと同じargvの形にするため、
#       /cowork-vm-service.jsで終わるパスをnodeで動かす
#       nodeが無い環境ではテストをスキップする
#
_start_fake_daemon() {
	command -v node >/dev/null 2>&1 || skip 'node not available'
	local dir="$TEST_TMP/res/app.asar.unpacked"
	mkdir -p "$dir"
	printf 'setInterval(() => {}, 1000);\n' > "$dir/cowork-vm-service.js"
	node "$dir/cowork-vm-service.js" > /dev/null 2>&1 3>&- &
	fake_daemon=$!
	# execが済むまで待ち、/proc/PID/cmdlineがnodeのものになったことを確かめる
	local i
	for ((i = 0; i < 50; i++)); do
		[[ $(tr '\0' ' ' < "/proc/$fake_daemon/cmdline" 2>/dev/null) \
			== node* ]] && return 0
		sleep 0.1
	done
	return 1
}

#
# @brief デーモンのファイル名をargvに含むだけの無関係なプロセスを起動する
# @global bystander (本関数で設定する) 起動したプロセスのPID
# @note 部分一致で殺していた頃は、エディタやtailやgrepまで巻き込んでいた
#
_start_bystander() {
	local file="$TEST_TMP/notes/cowork-vm-service.js"
	mkdir -p "${file%/*}"
	: > "$file"
	tail -f /dev/null "$file" > /dev/null 2>&1 3>&- &
	bystander=$!
	local i
	for ((i = 0; i < 50; i++)); do
		[[ $(tr '\0' ' ' < "/proc/$bystander/cmdline" 2>/dev/null) \
			== tail* ]] && return 0
		sleep 0.1
	done
	return 1
}

#
# @brief テストが起動したプロセスを強制終了し、回収する
# @param $@ 終了させるPID
# @return 常に0
#
_stop_pids() {
	local pid
	for pid in "$@"; do
		[[ -n $pid ]] || continue
		kill -KILL "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
}

@test "_is_cowork_fallback_daemon: accepts node running the daemon script" {
	_start_fake_daemon
	run _is_cowork_fallback_daemon "$fake_daemon"
	_stop_pids "$fake_daemon"
	[[ $status -eq 0 ]]
}

@test "_is_cowork_fallback_daemon: rejects a bystander naming the file" {
	_start_bystander
	run _is_cowork_fallback_daemon "$bystander"
	_stop_pids "$bystander"
	[[ $status -ne 0 ]]
}

@test "cleanup_orphaned_cowork_daemon: kills orphan, spares bystander" {
	_start_fake_daemon
	_start_bystander
	_claude_desktop_ui_is_alive() { return 1; }
	setup_logging
	cleanup_orphaned_cowork_daemon
	local daemon_alive=false bystander_alive=false
	# kill -0がゾンビを見続けないよう、終了した子プロセスを回収する
	wait "$fake_daemon" 2>/dev/null || true
	kill -0 "$fake_daemon" 2>/dev/null && daemon_alive=true
	kill -0 "$bystander" 2>/dev/null && bystander_alive=true
	_stop_pids "$fake_daemon" "$bystander"
	[[ $daemon_alive == false ]]
	[[ $bystander_alive == true ]]
	grep -q 'Killed orphaned cowork-vm-service daemon' "$log_file"
}

@test "cleanup_orphaned_cowork_daemon: leaves daemon alone while UI is alive" {
	_start_fake_daemon
	_claude_desktop_ui_is_alive() { return 0; }
	setup_logging
	cleanup_orphaned_cowork_daemon
	local daemon_alive=false
	kill -0 "$fake_daemon" 2>/dev/null && daemon_alive=true
	_stop_pids "$fake_daemon"
	[[ $daemon_alive == true ]]
}

@test "cleanup_stale_desktop_helpers: spares unrelated Electron-looking processes" {
	_start_bystander
	_claude_desktop_ui_is_alive() { return 1; }
	setup_logging
	cleanup_stale_desktop_helpers
	local bystander_alive=false
	kill -0 "$bystander" 2>/dev/null && bystander_alive=true
	_stop_pids "$bystander"
	[[ $bystander_alive == true ]]
}

@test "_desktop_helper_cmdline_matches: in-tree Chromium helper matches" {
	run _desktop_helper_cmdline_matches \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron --type=renderer '
	[[ $status -eq 0 ]]
}

@test "_desktop_helper_cmdline_matches: argument mentioning the tree does not match" {
	run _desktop_helper_cmdline_matches \
		'vim /usr/lib/claude-desktop/launcher-common.sh --type=x '
	[[ $status -ne 0 ]]
}

@test "_pid_is_claude_desktop: unrelated executable is not a lock holder" {
	sleep 30 3>&- &
	local other=$!
	run _pid_is_claude_desktop "$other"
	_stop_pids "$other"
	[[ $status -ne 0 ]]
}

#
# @brief UIの指紋--class=Claudeをargvに持つ偽のClaude Desktopを起動する
# @param $1 コピーしたbashを置くパス
# @global fake_ui (本関数で設定する) 起動したプロセスのPID
# @note 末尾の:があるとbashはsleepをexecしないため、
#       /proc/PID/exeはコピーしたbashのままになる
#
_start_fake_ui() {
	local exe="$1"
	mkdir -p "${exe%/*}"
	cp "$(command -v bash)" "$exe"
	"$exe" -c 'sleep 30; :' fake-ui --class=Claude > /dev/null 2>&1 3>&- &
	fake_ui=$!
	local i
	for ((i = 0; i < 50; i++)); do
		[[ $(tr '\0' ' ' < "/proc/$fake_ui/cmdline" 2>/dev/null) \
			== *'--class=Claude '* ]] && return 0
		sleep 0.1
	done
	return 1
}

@test "_pid_is_claude_desktop: --class fingerprint counts (renamed or extracted AppImage)" {
	_start_fake_ui "$TEST_TMP/squashfs-root/usr/lib/node_modules/electron/dist/electron"
	run _pid_is_claude_desktop "$fake_ui"
	_stop_pids "$fake_ui"
	[[ $status -eq 0 ]]
}

@test "cleanup_replaced_desktop_ui: kills a replaced Claude Desktop UI" {
	local exe="$TEST_TMP/usr/lib/claude-desktop/node_modules/electron/dist/electron"
	_start_fake_ui "$exe"
	rm -f "$exe"
	setup_logging
	cleanup_replaced_desktop_ui
	wait "$fake_ui" 2>/dev/null || true
	local alive=false
	kill -0 "$fake_ui" 2>/dev/null && alive=true
	_stop_pids "$fake_ui"
	[[ $alive == false ]]
	grep -q 'Killed replaced Claude Desktop UI' "$log_file"
}

@test "cleanup_replaced_desktop_ui: spares another app that only shares --class" {
	local exe="$TEST_TMP/opt/other-app/electron"
	_start_fake_ui "$exe"
	rm -f "$exe"
	setup_logging
	# setup_loggingはログファイルを作らないため、ここでは何も記録されないはず
	: > "$log_file"
	cleanup_replaced_desktop_ui
	local alive=false
	kill -0 "$fake_ui" 2>/dev/null && alive=true
	_stop_pids "$fake_ui"
	[[ $alive == true ]]
	[[ $(< "$log_file") != *'Killed replaced'* ]]
}

#
# @brief 拡張機能のMCPサーバーと同じargvの形でnodeを起動する
# @param $@ 前に付けるラッパーコマンド (setsidなど、省略可)
# @global ext_server (本関数で設定する) 起動したプロセスのPID
# @note スクリプトは拡張機能ディレクトリの下に置く
#       nodeが無い環境ではテストをスキップする
#
_start_ext_server() {
	command -v node >/dev/null 2>&1 || skip 'node not available'
	local dir="$XDG_CONFIG_HOME/Claude/Claude Extensions/ext.test"
	mkdir -p "$dir"
	printf 'setInterval(() => {}, 1000);\n' > "$dir/server.js"
	"$@" node "$dir/server.js" > /dev/null 2>&1 3>&- &
	ext_server=$!
	local i
	for ((i = 0; i < 50; i++)); do
		[[ $(tr '\0' ' ' < "/proc/$ext_server/cmdline" 2>/dev/null) \
			== node* ]] && return 0
		sleep 0.1
	done
	return 1
}

@test "cleanup_stale_desktop_helpers: reaps an extension server from a recorded launch" {
	_claude_desktop_ui_is_alive() { return 1; }
	_record_launch_pgid
	_start_ext_server
	setup_logging
	cleanup_stale_desktop_helpers
	wait "$ext_server" 2>/dev/null || true
	local alive=false
	kill -0 "$ext_server" 2>/dev/null && alive=true
	_stop_pids "$ext_server"
	[[ $alive == false ]]
	grep -q 'Killed stale Claude Desktop helpers' "$log_file"
}

@test "cleanup_stale_desktop_helpers: spares an extension server run from a terminal" {
	command -v setsid >/dev/null 2>&1 || skip 'setsid not available'
	_claude_desktop_ui_is_alive() { return 1; }
	_record_launch_pgid
	# setsidで、シェルジョブと同じように独自のプロセスグループを持たせる
	_start_ext_server setsid
	setup_logging
	cleanup_stale_desktop_helpers
	local alive=false
	kill -0 "$ext_server" 2>/dev/null && alive=true
	_stop_pids "$ext_server"
	[[ $alive == true ]]
}

@test "_record_launch_pgid: keeps the last ten groups without duplicates" {
	local file
	file=$(_launch_pgids_file)
	mkdir -p "${file%/*}"
	seq 1 12 > "$file"
	_record_launch_pgid
	_record_launch_pgid
	local pgid
	pgid=$(_proc_stat_field "$$" 2)
	[[ $(wc -l < "$file") -eq 10 ]]
	[[ $(grep -cxF "$pgid" "$file") -eq 1 ]]
	[[ $(tail -n 1 "$file") == "$pgid" ]]
}

@test "_pid_is_same_process: start time pins the PID" {
	sleep 30 3>&- &
	local pid=$! start
	start=$(_proc_stat_field "$pid" 19)
	run _pid_is_same_process "$pid" "$start"
	local same=$status
	run _pid_is_same_process "$pid" "$((start + 1))"
	local other=$status
	_stop_pids "$pid"
	[[ $same -eq 0 ]]
	[[ $other -ne 0 ]]
}

@test "_kill_pids_escalating: SIGKILLs a target that ignores SIGTERM" {
	bash -c 'trap "" TERM; sleep 30; :' > /dev/null 2>&1 3>&- &
	local pid=$!
	sleep 0.2
	setup_logging
	_kill_pids_escalating 'Killed test target' "$pid"
	wait "$pid" 2>/dev/null || true
	local alive=false
	kill -0 "$pid" 2>/dev/null && alive=true
	_stop_pids "$pid"
	[[ $alive == false ]]
	grep -qF "Killed test target (SIGKILL, PIDs: $pid)" "$log_file"
}

@test "_kill_pids_escalating: no SIGKILL once the PID is another process" {
	bash -c 'trap "" TERM; sleep 30; :' > /dev/null 2>&1 3>&- &
	local pid=$!
	sleep 0.2
	# 最初のシグナルの直後にPIDが再利用された状況を模す
	# 先に記録した開始時刻は、そのPIDの実際のプロセスともう一致しない
	_proc_stat_field() { printf '1'; }
	setup_logging
	_kill_pids_escalating 'Killed test target' "$pid"
	local alive=false
	kill -0 "$pid" 2>/dev/null && alive=true
	_stop_pids "$pid"
	[[ $alive == true ]]
	grep -qF "Killed test target (PIDs: $pid)" "$log_file"
}

@test "_kill_pids_escalating: PIDs already gone are dropped" {
	setup_logging
	# setup_loggingはログファイルを作らないため、ここでは何も記録されないはず
	: > "$log_file"
	_kill_pids_escalating 'Killed test target' 999999999
	[[ $(< "$log_file") != *'Killed test target'* ]]
}

# =============================================================================
# Electronの出力フィルタ : 繰り返し行を畳み込む
# =============================================================================

@test "_electron_output_filter: collapses repeated lines" {
	run bash -c "source '$TEST_TMP/launcher-common.sh'
		printf 'a\nb\nb\nb\nc\n' | _electron_output_filter"
	[[ $status -eq 0 ]]
	[[ $output == $'a\nb\n[launcher] last line repeated 2 more times\nc' ]]
}

@test "_electron_output_filter: flushes a trailing repeat run" {
	run bash -c "source '$TEST_TMP/launcher-common.sh'
		printf 'x\nx\n' | _electron_output_filter"
	[[ $output == $'x\n[launcher] last line repeated 1 more times' ]]
}

@test "_electron_output_filter: stops at the byte cap with one marker" {
	run bash -c "source '$TEST_TMP/launcher-common.sh'
		for i in 1 2 3 4 5 6 7 8; do printf 'line-%s\n' \"\$i\"; done \
			| ELECTRON_LOG_CAP_BYTES=14 _electron_output_filter"
	[[ $status -eq 0 ]]
	[[ $output == *'line-1'* && $output == *'line-2'* ]]
	[[ $output != *'line-3'* ]]
	[[ $(grep -c 'output cap (14 bytes) reached' <<< "$output") -eq 1 ]]
}

@test "_electron_output_filter: nothing follows the cap marker, not even a repeat summary" {
	run bash -c "source '$TEST_TMP/launcher-common.sh'
		printf 'line-1\nline-2\nline-3\nline-3\nline-3\nline-4\n' \
			| ELECTRON_LOG_CAP_BYTES=14 _electron_output_filter"
	[[ $status -eq 0 ]]
	[[ $output == $'line-1\nline-2\n[launcher] output cap (14 bytes) reached; further output dropped this session' ]]
}

@test "_electron_output_filter: a repeat summary past the cap is dropped" {
	run bash -c "source '$TEST_TMP/launcher-common.sh'
		printf 'line-1\nline-2\nline-2\nline-2\n' \
			| ELECTRON_LOG_CAP_BYTES=14 _electron_output_filter"
	[[ $output == $'line-1\nline-2\n[launcher] output cap (14 bytes) reached; further output dropped this session' ]]
}

# =============================================================================
# run_electron_and_cleanup : Electronを起動し、出力を流し切ってから後始末する
# =============================================================================

@test "run_electron_and_cleanup: logs filtered output, returns child status" {
	setup_logging
	cleanup_after_electron_exit() { log_message 'cleanup ran'; }
	local child="$TEST_TMP/fake-electron"
	printf '#!/usr/bin/env bash\necho hello\necho dup\necho dup\nexit 7\n' \
		> "$child"
	chmod +x "$child"
	export TMPDIR="$TEST_TMP/tmp"
	mkdir -p "$TMPDIR"
	run run_electron_and_cleanup "$child"
	[[ $status -eq 7 ]]
	grep -q '^hello$' "$log_file"
	grep -q 'last line repeated 1 more times' "$log_file"
	grep -q 'Electron exited with code: 7' "$log_file"
	grep -q 'cleanup ran' "$log_file"
	# 終了行を書く前に、出力をすべて読み切っておく必要がある
	[[ $(grep -n '^hello$' "$log_file" | cut -d: -f1) \
		-lt $(grep -n 'Electron exited with code' "$log_file" | cut -d: -f1) ]]
	# 処理の後にfifo用のディレクトリが削除される
	[[ -z $(find "$TMPDIR" -mindepth 1 -maxdepth 1 \
		-name 'claude-launcher.*') ]]
}

@test "run_electron_and_cleanup: a helper holding the pipe cannot write past Launcher End" {
	setup_logging
	cleanup_after_electron_exit() { log_message 'cleanup ran'; }
	local child="$TEST_TMP/fake-electron"
	# 背景の補助プロセスは標準出力 (fifo) を引き継ぎ、
	# メインプロセスの終了と出力の読み切りが済んだ後に書き込もうとする
	printf '%s\n' '#!/usr/bin/env bash' 'exec 3>&-' \
		'( sleep 3; echo late-helper-line ) &' 'echo main-line' 'exit 3' \
		> "$child"
	chmod +x "$child"
	export TMPDIR="$TEST_TMP/tmp"
	mkdir -p "$TMPDIR"
	run run_electron_and_cleanup "$child"
	[[ $status -eq 3 ]]
	sleep 2
	grep -q '^main-line$' "$log_file"
	[[ $(< "$log_file") != *'late-helper-line'* ]]
	[[ $(tail -n 1 "$log_file") == *'--- Claude Desktop Launcher End ---' ]]
}

# =============================================================================
# ensure_portal_app_id_entry : WaylandのアプリID用にデスクトップエントリを用意する
# =============================================================================

#
# @brief portal連携のテスト用に、XDGの状態と表示バックエンドを用意する
# @global portal_id (本関数で設定する) アプリID
# @global portal_entry (本関数で設定する) デスクトップエントリのパス
# @global is_wayland / use_x11_on_wayland (本関数で設定する) 表示バックエンドの状態
#
_portal_setup() {
	setup_logging
	export XDG_DATA_HOME="$TEST_TMP/data"
	export XDG_DATA_DIRS="$TEST_TMP/sys"
	portal_id='io.github.presire.claude-desktop-suse'
	portal_entry="$XDG_DATA_HOME/applications/$portal_id.desktop"
	is_wayland=true
	use_x11_on_wayland=false
}

@test "ensure_portal_app_id_entry: writes hidden alias on native Wayland" {
	_portal_setup
	ensure_portal_app_id_entry '/opt/My Apps/Claude 100%.AppImage' \
		"$portal_id" "$portal_id"
	[[ -f $portal_entry ]]
	grep -qxF 'Exec="/opt/My Apps/Claude 100%%.AppImage" %u' "$portal_entry"
	grep -qxF 'NoDisplay=true' "$portal_entry"
	grep -qxF 'MimeType=x-scheme-handler/claude;' "$portal_entry"
	grep -qxF "Icon=$portal_id" "$portal_entry"
	grep -qxF "$PORTAL_ENTRY_MARKER" "$portal_entry"
	grep -q 'Wrote portal app-id entry' "$log_file"
}

#
# @brief GLibと同じ手順でExec行を解釈し、argv[0]を出力する
# @param $1 デスクトップエントリのファイル
# @param $2 Execを読むグループ名 (既定 Desktop Entry)
# @stdout 実行コマンドの先頭要素
# @note GLibのKeyFileは文字列のアンエスケープ、フィールドコードの展開
#       (%uを落として%%を%にする)、シェル風の引数分割を行う
#       python3のgi (GLib) が必要
#
_glib_exec_argv0() {
	local group="${2:-Desktop Entry}"
	python3 - "$1" "$group" <<'PY'
import sys
from gi.repository import GLib
kf = GLib.KeyFile()
kf.load_from_file(sys.argv[1], GLib.KeyFileFlags.NONE)
cmd = kf.get_string(sys.argv[2], 'Exec')
cmd = cmd.replace(' %u', '').replace('%%', '%')
ok, argv = GLib.shell_parse_argv(cmd)
print(argv[0])
PY
}

#
# @brief GLibでデスクトップエントリの文字列値を読む
# @param $1 デスクトップエントリのファイル
# @param $2 グループ名 (既定 Desktop Entry)
# @param $3 キー名 (既定 TryExec)
# @stdout アンエスケープされた値
# @note TryExecはExecではないためshell_parse_argvを通さず文字列として読む
#
_glib_key_string() {
	local group="${2:-Desktop Entry}" key="${3:-TryExec}"
	python3 - "$1" "$group" "$key" <<'PY'
import sys
from gi.repository import GLib
kf = GLib.KeyFile()
kf.load_from_file(sys.argv[1], GLib.KeyFileFlags.NONE)
print(kf.get_string(sys.argv[2], sys.argv[3]))
PY
}

@test "_desktop_exec_quote: GLib reads back paths with \\ \" \` \$ and %" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_portal_setup
	local path
	for path in '/opt/a"b/Claude.AppImage' '/opt/$HOME/Claude.AppImage' \
		'/opt/back`tick`/Claude.AppImage' '/opt/back\slash/Claude.AppImage' \
		'/opt/My Apps/Claude 100%.AppImage'; do
		rm -f "$portal_entry"
		ensure_portal_app_id_entry "$path" "$portal_id" "$portal_id"
		[[ $(_glib_exec_argv0 "$portal_entry") == "$path" ]]
	done
}

@test "_desktop_exec_quote: refuses a path with a newline" {
	run _desktop_exec_quote $'/opt/a\nb'
	[[ $status -ne 0 ]]
	_portal_setup
	ensure_portal_app_id_entry $'/opt/a\nb' "$portal_id" "$portal_id"
	[[ ! -e $portal_entry ]]
}

@test "heal_autostart_entry: GLib reads back a launcher path with a quote" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	local entry="$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
	mkdir -p "${entry%/*}"
	printf '%s\n' '[Desktop Entry]' 'Type=Application' \
		'Exec=/old/bin/claude-desktop %u' > "$entry"
	heal_autostart_entry '/opt/x"y/claude-desktop'
	[[ $(_glib_exec_argv0 "$entry") == '/opt/x"y/claude-desktop' ]]
}

#
# @brief autostart用のデスクトップエントリを書き出し、そのパスを出力する
# @param $1 Exec行に書くコマンド
# @stdout 書き出したエントリのパス
#
_autostart_entry_with() {
	local entry="$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
	mkdir -p "${entry%/*}"
	printf '%s\n' '[Desktop Entry]' 'Type=Application' \
		"Exec=$1" > "$entry"
	printf '%s' "$entry"
}

@test "heal_autostart_entry: a dead command is pointed at the launcher" {
	local entry
	entry=$(_autostart_entry_with \
		"$TEST_TMP/.mount_claudeGone/usr/bin/claude-desktop %u")
	log_file="$TEST_TMP/launcher.log"
	heal_autostart_entry '/opt/Claude.AppImage'
	grep -qxF 'Exec="/opt/Claude.AppImage" %u' "$entry"
	grep -qF 'Healed autostart Exec' "$log_file"
}

@test "heal_autostart_entry: a live command of another install is left alone (#949)" {
	local live="$TEST_TMP/usr/bin/claude-desktop" entry
	mkdir -p "${live%/*}"
	printf '#!/bin/sh\n' > "$live"
	chmod +x "$live"
	entry=$(_autostart_entry_with "$live %u")
	log_file="$TEST_TMP/launcher.log"
	heal_autostart_entry '/opt/Claude.AppImage'
	grep -qxF "Exec=$live %u" "$entry"
	grep -qF 'still runs; leaving it' "$log_file"
}

@test "heal_autostart_entry: a non-executable leftover counts as dead" {
	local stale="$TEST_TMP/lib/claude-desktop" entry
	mkdir -p "${stale%/*}"
	: > "$stale"
	entry=$(_autostart_entry_with "$stale")
	heal_autostart_entry '/usr/bin/claude-desktop'
	grep -qxF 'Exec="/usr/bin/claude-desktop"' "$entry"
}

@test "heal_autostart_entry: a bare command name is not touched" {
	local entry
	entry=$(_autostart_entry_with 'claude-desktop')
	heal_autostart_entry '/opt/Claude.AppImage'
	grep -qxF 'Exec=claude-desktop' "$entry"
}

@test "ensure_portal_app_id_entry: does not create alias on X11/XWayland" {
	_portal_setup
	use_x11_on_wayland=true
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	[[ ! -e $portal_entry ]]
	is_wayland=false
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: keeps own alias current on any backend" {
	_portal_setup
	ensure_portal_app_id_entry '/opt/old/Claude.AppImage' "$portal_id"
	is_wayland=false
	use_x11_on_wayland=true
	ensure_portal_app_id_entry '/opt/new/Claude.AppImage' "$portal_id"
	grep -qxF 'Exec="/opt/new/Claude.AppImage" %u' "$portal_entry"
}

@test "ensure_portal_app_id_entry: unchanged alias is not rewritten" {
	_portal_setup
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	touch -d '2001-01-01' "$portal_entry"
	: > "$log_file"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	[[ $(stat -c %Y "$portal_entry") -eq $(date -d '2001-01-01' +%s) ]]
	[[ $(< "$log_file") != *'Wrote portal app-id entry'* ]]
	[[ -z $(find "$XDG_DATA_HOME/applications" -name '*.tmp.*') ]]
}

@test "ensure_portal_app_id_entry: system entry removes own alias" {
	_portal_setup
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	mkdir -p "$XDG_DATA_DIRS/applications"
	: > "$XDG_DATA_DIRS/applications/$portal_id.desktop"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	[[ ! -e $portal_entry ]]
	grep -q 'Removed portal app-id entry' "$log_file"
}

@test "ensure_portal_app_id_entry: system entry leaves foreign file alone" {
	_portal_setup
	mkdir -p "$XDG_DATA_HOME/applications" "$XDG_DATA_DIRS/applications"
	printf '[Desktop Entry]\nName=Mine\n' > "$portal_entry"
	: > "$XDG_DATA_DIRS/applications/$portal_id.desktop"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	grep -qxF 'Name=Mine' "$portal_entry"
}

@test "ensure_portal_app_id_entry: leaves a foreign entry in place" {
	_portal_setup
	mkdir -p "$XDG_DATA_HOME/applications"
	printf '[Desktop Entry]\nName=Mine\n' > "$portal_entry"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	grep -qxF 'Name=Mine' "$portal_entry"
	grep -q 'Left portal app-id entry' "$log_file"
}

@test "ensure_portal_app_id_entry: replaces stale app-generated entry" {
	_portal_setup
	mkdir -p "$XDG_DATA_HOME/applications"
	printf '%s\n' '[Desktop Entry]' 'X-Claude-Generated=true' \
		"TryExec=$TEST_TMP/gone/claude" > "$portal_entry"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id"
	grep -qxF "$PORTAL_ENTRY_MARKER" "$portal_entry"
	grep -q 'Replacing stale app-generated entry' "$log_file"
}

@test "ensure_portal_app_id_entry: empty launcher or app id is a no-op" {
	_portal_setup
	ensure_portal_app_id_entry '' "$portal_id"
	ensure_portal_app_id_entry '/opt/Claude.AppImage' ''
	[[ ! -d $XDG_DATA_HOME/applications ]]
}

# =============================================================================
# Doctorの補助関数 : 色付けとPASS/FAIL/WARN/INFOの出力
# =============================================================================

@test "_doctor_colors: sets color vars when stdout is a terminal" {
	# 端末でない場合の分岐を確認する
	_doctor_colors
	# 端末でないときは、どの変数も空になるはず
	[[ -z $_green ]]
	[[ -z $_red ]]
	[[ -z $_yellow ]]
	[[ -z $_bold ]]
	[[ -z $_reset ]]
}

@test "_pass: outputs PASS with message" {
	_doctor_colors
	run _pass "test passed"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"test passed"* ]]
}

@test "_fail: outputs FAIL with message and increments counter" {
	_doctor_colors
	_doctor_failures=0
	_fail "something broke"
	[[ $_doctor_failures -eq 1 ]]
}

@test "_warn: outputs WARN with message" {
	_doctor_colors
	run _warn "warning message"
	[[ $output == *"[WARN]"* ]]
	[[ $output == *"warning message"* ]]
}

@test "_info: outputs indented message" {
	_doctor_colors
	run _info "info message"
	[[ $output == *"info message"* ]]
}

# =============================================================================
# _cowork_distro_id : /etc/os-releaseからディストリビューションIDを読む
# =============================================================================

@test "_cowork_distro_id: reads ID from /etc/os-release" {
	# テスト環境の実際の/etc/os-releaseを使う
	[[ -f /etc/os-release ]] || skip "No /etc/os-release"
	local result
	result=$(_cowork_distro_id)
	# 空でない値が返るはず
	[[ -n $result ]]
	[[ $result != 'unknown' ]]
}

# =============================================================================
# _cowork_pkg_hint : ディストリビューションごとのパッケージ導入コマンドを返す
# =============================================================================

@test "_cowork_pkg_hint: opensuse uses zypper" {
	local result
	result=$(_cowork_pkg_hint opensuse bubblewrap)
	[[ $result == "sudo zypper install bubblewrap" ]]
}

@test "_cowork_pkg_hint: sles uses zypper" {
	local result
	result=$(_cowork_pkg_hint sles socat)
	[[ $result == "sudo zypper install socat" ]]
}

@test "_cowork_pkg_hint: qemu maps to suse-specific packages" {
	local result
	result=$(_cowork_pkg_hint opensuse qemu)
	[[ $result == "sudo zypper install qemu-x86 qemu-tools" ]]
}

@test "_cowork_pkg_hint: unknown distro gives generic message" {
	local result
	result=$(_cowork_pkg_hint gentoo bubblewrap)
	[[ $result == "Install bubblewrap using your package manager" ]]
}

# =============================================================================
# _electron_version : Electronのバージョンを取得する
# =============================================================================

@test "_electron_version: reads version from file beside binary" {
	mkdir -p "$TEST_TMP/electron"
	echo "33.4.0" > "$TEST_TMP/electron/version"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron")
	[[ $result == "33.4.0" ]]
}

@test "_electron_version: returns empty when version file missing" {
	mkdir -p "$TEST_TMP/electron"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron") || true
	[[ -z $result ]]
}

# =============================================================================
# setup_tray_icon_env : Cinnamonの暗いパネル向けにトレイアイコンを選ぶ
# (上流のclaude-desktop-debian #604から移植)
# =============================================================================

@test "setup_tray_icon_env: preset value is exported unchanged" {
	CLAUDE_TRAY_USE_DARK_ICON=0
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == 0 ]]
	[[ $(bash -c 'printf %s "${CLAUDE_TRAY_USE_DARK_ICON-unset}"') == 0 ]]
	grep -q 'CLAUDE_TRAY_USE_DARK_ICON=0 (preset)' "$log_file"
	run grep -q 'not 0/1' "$log_file"
	[[ $status -ne 0 ]]
}

@test "setup_tray_icon_env: non-0/1 preset logs that the app ignores it" {
	export CLAUDE_TRAY_USE_DARK_ICON=true
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == true ]]
	grep -q 'CLAUDE_TRAY_USE_DARK_ICON=true (preset)' "$log_file"
	grep -q 'not 0/1' "$log_file"
}

@test "setup_tray_icon_env: cinnamon dark theme sets CLAUDE_TRAY_USE_DARK_ICON=1" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=X-Cinnamon
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/gsettings" << 'STUB'
#!/usr/bin/env bash
if [[ $1 == get && $2 == org.cinnamon.theme && $3 == name ]]; then
	printf "'Mint-Y-Dark-Aqua'\n"
fi
STUB
	chmod +x "$TEST_TMP/bin/gsettings"
	PATH="$TEST_TMP/bin:$PATH"
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == 1 ]]
	[[ $(bash -c 'printf %s "${CLAUDE_TRAY_USE_DARK_ICON-unset}"') == 1 ]]
	grep -q "theme 'Mint-Y-Dark-Aqua'.*TrayIconLinux-Dark.png" "$log_file"
}

@test "setup_tray_icon_env: cinnamon light theme leaves env unset" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=X-Cinnamon
	mkdir -p "$TEST_TMP/bin"
	# スタブが動いたことを記録する
	# 途中で戻る壊れたスタブと、テーマ判定が成功した場合を区別できなくなる
	cat > "$TEST_TMP/bin/gsettings" << STUB
#!/usr/bin/env bash
touch "$TEST_TMP/gsettings-called"
if [[ \$1 == get && \$3 == name ]]; then
	printf "'Mint-Y'\n"
fi
STUB
	chmod +x "$TEST_TMP/bin/gsettings"
	PATH="$TEST_TMP/bin:$PATH"
	setup_tray_icon_env
	[[ -e $TEST_TMP/gsettings-called ]]
	[[ -z ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]
}

@test "setup_tray_icon_env: unset XDG_CURRENT_DESKTOP is safe under set -u" {
	unset CLAUDE_TRAY_USE_DARK_ICON XDG_CURRENT_DESKTOP
	set -u
	run setup_tray_icon_env
	set +u
	[[ $status -eq 0 ]]
}

@test "setup_tray_icon_env: non-cinnamon desktop is a no-op" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=KDE
	setup_tray_icon_env
	[[ -z ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]
}

@test "setup_tray_icon_env: wired into setup_electron_env" {
	export CLAUDE_TRAY_USE_DARK_ICON=1
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_electron_env
	grep -q 'CLAUDE_TRAY_USE_DARK_ICON=1 (preset)' "$log_file"
}

# =============================================================================
# log_message : OAuthのコードを伏せる (LOG-1、Debianのテスト群から移植)
# =============================================================================

@test "log_message: redacts OAuth code from claude://login argv (LOG-1)" {
	setup_logging
	log_message "Arguments: claude://login/google-auth?code=SECRET123&state=xyz"
	log_message "Executing: /usr/lib/claude-desktop/claude-desktop claude://login/google-auth?code=SECRET456"
	run cat "$log_file"
	[[ $output != *SECRET123* ]]
	[[ $output != *SECRET456* ]]
	[[ $output != *'code='* ]]
	[[ ${lines[0]} == 'Arguments: claude://login/google-auth?<redacted>' ]]
	[[ ${lines[1]} == *'claude://login/google-auth?<redacted>' ]]
}

# =============================================================================
# backup_user_config : 起動前に設定とCoworkストアの控えを世代管理する
# (Debianのテスト群から移植、SUSEは5世代を保持する)
# =============================================================================

#
# @brief バックアップの保存先パスを組み立てる
# @param $1 対象のファイル名
# @param $2 世代番号
# @stdout 保存先パス
# @note 保存先はキャッシュディレクトリの下に置く
#
_backup_slot() {
	echo "$XDG_CACHE_HOME/claude-desktop-suse/config-backups/$1.$2"
}

#
# @brief 指定した世代のバックアップの内容を出力する
# @param $1 対象のファイル名
# @param $2 世代番号
# @stdout バックアップの内容
#
_backup_body() {
	cat "$(_backup_slot "$1" "$2")"
}

#
# @brief 利用者のclaude_desktop_config.jsonを書き出す
# @param $1 書き出す内容
#
_write_user_config() {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	printf '%s' "$1" \
		> "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
}

@test "backup_user_config: no user config - returns 0 and stays quiet" {
	run backup_user_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
	[[ ! -e "$(_backup_slot claude_desktop_config.json 1)" ]]
}

@test "backup_user_config: first launch - slot .1 is a byte-identical copy" {
	local cfg="$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
	_write_user_config '{"mcpServers":{"fs":{"command":"npx"}}}'

	setup_logging
	backup_user_config

	cmp -s "$cfg" "$(_backup_slot claude_desktop_config.json 1)"
	grep -q 'Backed up claude_desktop_config.json (keep 5)' "$log_file"
}

@test "backup_user_config: changed config rotates the previous copy to .2" {
	_write_user_config '{"mcpServers":{"fs":{"command":"npx"}}}'
	setup_logging
	backup_user_config

	_write_user_config '{}'
	backup_user_config

	local name=claude_desktop_config.json
	[[ $(_backup_body "$name" 1) == '{}' ]]
	[[ $(_backup_body "$name" 2) == \
		'{"mcpServers":{"fs":{"command":"npx"}}}' ]]
}

@test "backup_user_config: unchanged config does not rotate or log" {
	_write_user_config '{"mcpServers":{}}'
	setup_logging
	backup_user_config
	: > "$log_file"

	backup_user_config

	[[ ! -e "$(_backup_slot claude_desktop_config.json 2)" ]]
	run grep -q 'Backed up' "$log_file"
	[[ $status -ne 0 ]]
}

@test "backup_user_config: keeps five slots and drops the oldest" {
	setup_logging
	local i
	for i in {1..7}; do
		_write_user_config "{\"n\":$i}"
		backup_user_config
	done

	local name=claude_desktop_config.json
	[[ $(_backup_body "$name" 1) == '{"n":7}' ]]
	[[ $(_backup_body "$name" 5) == '{"n":3}' ]]
	[[ ! -e "$(_backup_slot "$name" 6)" ]]
}

@test "backup_user_config: nested Cowork stores flatten into one name" {
	local store="$XDG_CONFIG_HOME/Claude/local-agent-mode-sessions"
	store="$store/acct-uuid/org-uuid"
	mkdir -p "$store"
	echo spaces > "$store/spaces.json"
	echo remote > "$store/remote-session-spaces.json"
	echo tasks > "$store/scheduled-tasks.json"
	echo other > "$store/history.json"

	setup_logging
	backup_user_config

	local base='local-agent-mode-sessions__acct-uuid__org-uuid'
	[[ $(_backup_body "${base}__spaces.json" 1) == spaces ]]
	[[ $(_backup_body "${base}__remote-session-spaces.json" 1) == remote ]]
	[[ $(_backup_body "${base}__scheduled-tasks.json" 1) == tasks ]]
	[[ ! -e "$(_backup_slot spaces.json 1)" ]]
	[[ ! -e "$(_backup_slot "${base}__history.json" 1)" ]]
}

@test "backup_user_config: falls back to HOME/.cache when XDG unset" {
	unset XDG_CACHE_HOME
	_write_user_config '{"mcpServers":{}}'

	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	backup_user_config

	local slot="$HOME/.cache/claude-desktop-suse/config-backups"
	slot="$slot/claude_desktop_config.json.1"
	[[ $(cat "$slot") == '{"mcpServers":{}}' ]]
}

@test "backup_user_config: unwritable backup dir - returns 0 silently" {
	local jail="$TEST_TMP/readonly"
	mkdir -p "$jail"
	chmod 500 "$jail"
	[[ -w $jail ]] && skip 'directory mode not enforced here'

	_write_user_config '{"mcpServers":{}}'
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	export XDG_CACHE_HOME="$jail/cache"

	run backup_user_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
	run grep -q 'Backed up' "$log_file"
	[[ $status -ne 0 ]]
}

# =============================================================================
# ensure_portal_app_id_entry : %uが付く前に書かれたエントリを修復する
# (上流のclaude-desktop-debian #916のテスト群から移植、書き込みと削除の例は既にある)
# =============================================================================

#
# @brief %uが付く前に書かれていた形式のデスクトップエントリを作る
# @global portal_entry (参照のみ) 書き出し先のパス
# @global PORTAL_ENTRY_MARKER (参照のみ) 修復対象を見分ける目印
#
_write_pre_916_portal_entry() {
	mkdir -p "${portal_entry%/*}"
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Claude'
		printf 'Exec="%s"\n' '/opt/Claude.AppImage'
		printf '%s\n' 'NoDisplay=true' "$PORTAL_ENTRY_MARKER"
	} > "$portal_entry"
}

@test "ensure_portal_app_id_entry: heals a pre-#916 entry on native Wayland" {
	_portal_setup
	_write_pre_916_portal_entry
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id" "$portal_id"
	grep -qxF 'Exec="/opt/Claude.AppImage" %u' "$portal_entry"
	grep -qxF 'MimeType=x-scheme-handler/claude;' "$portal_entry"
}

@test "ensure_portal_app_id_entry: heals a pre-#916 entry under XWayland" {
	_portal_setup
	use_x11_on_wayland=true
	_write_pre_916_portal_entry
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id" "$portal_id"
	grep -qxF 'Exec="/opt/Claude.AppImage" %u' "$portal_entry"
	grep -qxF 'MimeType=x-scheme-handler/claude;' "$portal_entry"
}

@test "ensure_portal_app_id_entry: heals a pre-#916 entry on X11" {
	_portal_setup
	is_wayland=false
	use_x11_on_wayland=true
	_write_pre_916_portal_entry
	ensure_portal_app_id_entry '/opt/Claude.AppImage' "$portal_id" "$portal_id"
	grep -qxF 'Exec="/opt/Claude.AppImage" %u' "$portal_entry"
	grep -qxF 'MimeType=x-scheme-handler/claude;' "$portal_entry"
}

# =============================================================================
# heal_file_manager_entries : アプリ生成のNautilus/KDE項目をランチャーへ直す
# (上流のclaude-desktop-debian FM-1テスト群から移植、SUSEのelectron配置に合わせる)
# =============================================================================

# AppImageが終了後に残す、一時マウント内のelectron
FM_MOUNT='/tmp/.mount_claudeXYZ/usr/lib/node_modules/electron/dist/electron'

#
# @brief アプリ生成のNautilusスクリプトのパスを出力する
#
_fm_script() {
	printf '%s' "$XDG_DATA_HOME/nautilus/scripts/Send to Claude"
}

#
# @brief アプリ生成のKDEサービスメニューのパスを出力する
# @param $1 置き場所 (既定 kio/servicemenus)
#
_fm_menu() {
	printf '%s' "$XDG_DATA_HOME/${1:-kio/servicemenus}/com.anthropic.Claude.OpenInCode.desktop"
}

#
# @brief アプリ生成のSend to Claudeメニューのパスを出力する
# @param $1 置き場所 (既定 kio/servicemenus)
#
_fm_send_menu() {
	printf '%s' "$XDG_DATA_HOME/${1:-kio/servicemenus}/com.anthropic.Claude.SendTo.desktop"
}

#
# @brief ユーザーアイコンテーマ内のアイコンのパスを出力する
# @param $1 アイコン名 (既定 electron)
#
_fm_icon() {
	printf '%s' "$XDG_DATA_HOME/icons/hicolor/256x256/apps/${1:-electron}.png"
}

#
# @brief FM-1のテスト用にXDGのデータ領域を隔離する
# @global XDG_DATA_HOME / XDG_DATA_DIRS (本関数で設定する) 一時領域へ向ける
#
_fm_setup() {
	export XDG_DATA_HOME="$TEST_TMP/data"
	export XDG_DATA_DIRS="$TEST_TMP/sys"
	mkdir -p "$XDG_DATA_HOME" "$XDG_DATA_DIRS"
	printf 'png-data' > "$TEST_TMP/icon.png"
}

#
# @brief アプリが書く形のNautilusスクリプトを作る
# @param $1 スクリプトが起動するexecPath
#
_write_fm_script() {
	local exec="$1" q path
	path=$(_fm_script)
	mkdir -p "${path%/*}"
	q=$(_sh_single_quote "$exec")
	{
		printf '%s\n' '#!/bin/sh' '# X-Claude-Generated=true'
		printf '[ -x %s ] || exit 0\n' "$q"
		printf 'exec %s "claude://cowork/new?source=services"\n' "$q"
	} > "$path"
	chmod 700 "$path"
}

#
# @brief アプリが書く形のKDEサービスメニューを作る
# @param $1 TryExec/Execが起動するexecPath
# @param $2 Icon=の名前 (既定 electron)
# @param $3 置き場所 (既定 kio/servicemenus)
#
_write_fm_menu() {
	local exec="$1" icon="${2:-electron}" location="${3:-kio/servicemenus}"
	local path quoted
	path=$(_fm_menu "$location")
	mkdir -p "${path%/*}"
	quoted=$(_file_manager_exec_quote "$exec")
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Service'
		printf 'TryExec=%s\n' "$exec"
		printf '%s\n' 'MimeType=inode/directory;' 'X-KDE-Protocols=file' \
			'Actions=openInClaudeCode' \
			'X-KDE-ServiceTypes=KonqPopupMenu/Plugin' \
			'X-Claude-Generated=true' ''
		printf '%s\n' '[Desktop Action openInClaudeCode]' \
			'Name=Open in Claude Code'
		printf 'Icon=%s\n' "$icon"
		printf 'Exec=%s --os-entry=folder_verb %%f\n' "$quoted"
	} > "$path"
}

#
# @brief アプリが書く形のSend to Claude Nautilusスクリプトを作る
# @param $1 スクリプトが起動するexecPath
#
_write_fm_send_script() {
	local exec="$1" q path
	path=$(_fm_script)
	mkdir -p "${path%/*}"
	q=$(_sh_single_quote "$exec")
	{
		printf '%s\n' '#!/bin/sh' '# X-Claude-Generated=true'
		printf '[ -x %s ] || exit 0\n' "$q"
		printf '%s\n' 'q=""' 'for f in "$@"; do' \
			'  case "$f" in /*) ;; *) continue ;; esac' \
			'  [ -e "$f" ] || continue' \
			'  q="$q&file=$f"' 'done' '[ -n "$q" ] || exit 0'
		printf 'exec %s "claude://cowork/new?source=services$q"\n' "$q"
	} > "$path"
	chmod 700 "$path"
}

#
# @brief アプリが書く形のSend to Claudeサービスメニューを作る
# @param $1 メニューが参照するNautilusスクリプト
# @param $2 Icon=の名前 (既定 electron)
#
_write_fm_send_menu() {
	local script="$1" icon="${2:-electron}" path quoted
	path=$(_fm_send_menu)
	mkdir -p "${path%/*}"
	quoted=$(_file_manager_exec_quote "$script")
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Service'
		printf 'TryExec=%s\n' "$script"
		printf '%s\n' 'MimeType=all/all;' 'X-KDE-Protocols=file' \
			'Actions=sendToClaude' \
			'X-KDE-ServiceTypes=KonqPopupMenu/Plugin' \
			'X-Claude-Generated=true' ''
		printf '%s\n' '[Desktop Action sendToClaude]' \
			'Name=Send to Claude'
		printf 'Icon=%s\n' "$icon"
		printf 'Exec=%s %%F\n' "$quoted"
	} > "$path"
}

@test "heal_file_manager_entries: rewrites a dead AppImage mount in Nautilus and Dolphin" {
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries '/opt/My Apps/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	run grep -qF "[ -x '/opt/My Apps/Claude.AppImage' ] || exit 0" \
		"$(_fm_script)"
	[[ $status -eq 0 ]]
	[[ $(grep -cF "$FM_MOUNT" "$(_fm_script)") -eq 0 ]]
	grep -qxF 'TryExec=/opt/My Apps/Claude.AppImage' "$(_fm_menu)"
	grep -qxF 'Exec="/opt/My Apps/Claude.AppImage" --os-entry=folder_verb %f' \
		"$(_fm_menu)"
	[[ -f $(_fm_icon) ]]
	cmp -s "$TEST_TMP/icon.png" "$(_fm_icon)"
}

@test "heal_file_manager_entries: quotes spaces and apostrophes in the AppImage path" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	local appimage="/opt/Bob's Apps/Claude 100%.AppImage" q
	q=$(_sh_single_quote "$appimage")

	heal_file_manager_entries "$appimage" ''

	grep -qF "[ -x $q ] || exit 0" "$(_fm_script)"
	grep -qF "exec $q " "$(_fm_script)"
	grep -qxF "TryExec=$appimage" "$(_fm_menu)"
	[[ $(_glib_exec_argv0 "$(_fm_menu)" 'Desktop Action openInClaudeCode') == "$appimage" ]]
	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: reads back a quoted execPath it wrote" {
	_fm_setup
	_write_fm_script "/tmp/.mount_it's/usr/lib/node_modules/electron/dist/electron"
	[[ $(_file_manager_entry_exec "$(_fm_script)") == \
		"/tmp/.mount_it's/usr/lib/node_modules/electron/dist/electron" ]]
}

@test "heal_file_manager_entries: matches the app's Exec escaping for dollars and backticks" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	local appimage='/opt/A$b`c/Claude.AppImage'

	heal_file_manager_entries "$appimage" ''

	grep -qxF "TryExec=$appimage" "$(_fm_menu)"
	[[ $(_glib_exec_argv0 "$(_fm_menu)" 'Desktop Action openInClaudeCode') == "$appimage" ]]
}

@test "heal_file_manager_entries: two-level escaping round-trips quote dollar and backslash" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_fm_setup
	local old='/tmp/.mount_a"b$c\d/usr/lib/node_modules/electron/dist/electron'
	local new='/opt/a"b/$c\d/Claude.AppImage'
	_write_fm_script "$old"
	_write_fm_menu "$old"
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries "$new" ''

	[[ $(_glib_exec_argv0 "$(_fm_menu)" 'Desktop Action openInClaudeCode') == "$new" ]]
	[[ $(_glib_key_string "$(_fm_menu)" 'Desktop Entry' 'TryExec') == "$new" ]]
	[[ $(grep -cF "$old" "$(_fm_menu)") -eq 0 ]]
	[[ $(grep -cF "TryExec=$new" "$(_fm_menu)") -eq 0 ]]
}

@test "heal_file_manager_entries: heals a menu the patched generator serialized" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_fm_setup
	local old="$TEST_TMP/node_modules/electron/di\"r\$x\`y/electron"
	local new="$TEST_TMP/App\"Dir\$x\`y/Claude.AppImage"
	mkdir -p "${old%/*}"
	: > "$old"
	chmod 700 "$old"
	local menu
	menu=$(_fm_menu)
	mkdir -p "${menu%/*}"
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Service'
		printf 'TryExec=%s\n' "$(_desktop_entry_string_escape "$old")"
		printf '%s\n' 'X-Claude-Generated=true'
		printf 'Exec=%s\n' "$(_desktop_exec_quote "$old")"
	} > "$menu"
	_autostart_target_exists() { [[ $1 == "$old" ]]; }

	heal_file_manager_entries "$new" ''

	[[ $(_glib_exec_argv0 "$menu") == "$new" ]]
	[[ $(_glib_key_string "$menu" 'Desktop Entry' 'TryExec') == "$new" ]]
	[[ $(grep -cF "$old" "$menu") -eq 0 ]]
}

@test "heal_file_manager_entries: keeps SendTo Nautilus reference and reparses special XDG paths" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	_fm_setup
	export XDG_DATA_HOME="$TEST_TMP/xdg a\"b\$c\\d"
	mkdir -p "$XDG_DATA_HOME"
	local old='/tmp/.mount_a"b$c\d/usr/lib/node_modules/electron/dist/electron'
	local new="$TEST_TMP/opt/a\"b/\$c\\d/Claude.AppImage"
	local selected="$TEST_TMP/selected file"
	local record="$TEST_TMP/sendto.args"
	local script menu
	script=$(_fm_script)
	menu=$(_fm_send_menu)
	_write_fm_send_script "$old"
	_write_fm_send_menu "$script"
	_autostart_target_exists() { return 1; }
	mkdir -p "${new%/*}"
	{
		printf '%s\n' '#!/bin/sh'
		printf 'printf "%%s\\n" "$0" > %q\n' "$record"
		printf 'printf "%%s\\n" "$@" >> %q\n' "$record"
	} > "$new"
	chmod +x "$new"
	printf 'selected' > "$selected"

	heal_file_manager_entries "$new" ''

	[[ $(_glib_key_string "$menu" 'Desktop Entry' 'TryExec') == "$script" ]]
	[[ $(_glib_exec_argv0 "$menu" 'Desktop Action sendToClaude') == "$script" ]]
	[[ $(grep -cF "TryExec=$script" "$menu") -eq 0 ]]
	run "$script" "$selected"
	[[ $status -eq 0 ]]
	[[ $(sed -n '1p' "$record") == "$new" ]]
	[[ $(sed -n '2p' "$record") == 'claude://cowork/new?source=services&file='* ]]

	local script_sum menu_sum
	script_sum=$(cksum < "$script")
	menu_sum=$(cksum < "$menu")
	run heal_file_manager_entries "$new" ''
	[[ $status -eq 0 ]]
	[[ $(cksum < "$script") == "$script_sum" ]]
	[[ $(cksum < "$menu") == "$menu_sum" ]]
}

@test "heal_file_manager_entries: is idempotent" {
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	heal_file_manager_entries '/opt/Claude.AppImage' "$TEST_TMP/icon.png"
	local script_sum menu_sum
	script_sum=$(cksum < "$(_fm_script)")
	menu_sum=$(cksum < "$(_fm_menu)")
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"

	run heal_file_manager_entries '/opt/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	[[ $status -eq 0 ]]
	[[ $(cksum < "$(_fm_script)") == "$script_sum" ]]
	[[ $(cksum < "$(_fm_menu)") == "$menu_sum" ]]
	[[ ! -s $log_file ]]
}

@test "heal_file_manager_entries: rewrites the package's own Electron while it exists" {
	_fm_setup
	local own="$TEST_TMP/node_modules/electron/dist/electron"
	mkdir -p "${own%/*}"
	: > "$own"
	chmod 700 "$own"
	_write_fm_script "$own"
	_write_fm_menu "$own"
	_autostart_target_exists() { return 0; }

	heal_file_manager_entries '/usr/bin/claude-desktop' ''

	grep -qF "exec '/usr/bin/claude-desktop'" "$(_fm_script)"
	grep -qxF 'TryExec=/usr/bin/claude-desktop' "$(_fm_menu)"
}

@test "heal_file_manager_entries: recognizes its own tree under a non-default prefix" {
	_fm_setup
	local prefix="$TEST_TMP/usr/lib64/claude-desktop"
	local own="$prefix/node_modules/electron/dist/electron"
	mkdir -p "${own%/*}"
	: > "$own"
	chmod 700 "$own"
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" \
		"$prefix/launcher-common.sh"
	sed -i 's/@@WM_CLASS@@/Claude/' "$prefix/launcher-common.sh"
	_write_fm_script "$own"
	_write_fm_menu "$own"

	run bash -c "source '$prefix/launcher-common.sh'
		_autostart_target_exists() { return 0; }
		heal_file_manager_entries '/usr/bin/claude-desktop' ''"
	[[ $status -eq 0 ]]
	grep -qF "exec '/usr/bin/claude-desktop'" "$(_fm_script)"
	grep -qxF 'TryExec=/usr/bin/claude-desktop' "$(_fm_menu)"
}

@test "heal_file_manager_entries: leaves another installation's live AppImage mount alone" {
	_fm_setup
	local own="$TEST_TMP/node_modules/electron/dist/electron"
	mkdir -p "${own%/*}"
	: > "$own"
	chmod 700 "$own"
	local other
	other='/tmp/.mount_claudeOther/usr/lib/node_modules/electron/dist/electron'
	_write_fm_script "$other"
	_write_fm_menu "$other"
	_autostart_target_exists() { [[ $1 == "$other" ]]; }
	local script_sum menu_sum
	script_sum=$(cksum < "$(_fm_script)")
	menu_sum=$(cksum < "$(_fm_menu)")

	heal_file_manager_entries '/usr/bin/claude-desktop' ''

	[[ $(cksum < "$(_fm_script)") == "$script_sum" ]]
	[[ $(cksum < "$(_fm_menu)") == "$menu_sum" ]]
}

@test "heal_file_manager_entries: leaves an entry for another live install alone" {
	_fm_setup
	local other='/opt/other/electron'
	_write_fm_script "$other"
	_write_fm_menu "$other"
	_autostart_target_exists() { [[ $1 == "$other" ]]; }

	heal_file_manager_entries '/usr/bin/claude-desktop' \
		"$TEST_TMP/icon.png"

	grep -qF "exec '$other'" "$(_fm_script)"
	grep -qxF "TryExec=$other" "$(_fm_menu)"
}

@test "heal_file_manager_entries: never touches files without the marker" {
	_fm_setup
	local script menu script_sum menu_sum
	script=$(_fm_script)
	mkdir -p "${script%/*}"
	printf '%s\n' '#!/bin/sh' 'exec /opt/user/tool' > "$script"
	menu=$(_fm_menu)
	mkdir -p "${menu%/*}"
	printf '%s\n' '[Desktop Entry]' 'Type=Service' \
		'TryExec=/opt/other/electron' 'Exec=/opt/other/electron %f' > "$menu"
	script_sum=$(cksum < "$script")
	menu_sum=$(cksum < "$menu")

	heal_file_manager_entries '/usr/bin/claude-desktop' \
		"$TEST_TMP/icon.png"

	[[ $(cksum < "$script") == "$script_sum" ]]
	[[ $(cksum < "$menu") == "$menu_sum" ]]
	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: no generated entries - does nothing" {
	_fm_setup

	run heal_file_manager_entries '/usr/bin/claude-desktop' \
		"$TEST_TMP/icon.png"

	[[ $status -eq 0 ]]
	[[ -z $output ]]
	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: installs the menu icon even with no launcher path" {
	_fm_setup
	_write_fm_menu "$FM_MOUNT"

	heal_file_manager_entries '' "$TEST_TMP/icon.png"

	grep -qxF "TryExec=$FM_MOUNT" "$(_fm_menu)"
	[[ -f $(_fm_icon) ]]
}

@test "heal_file_manager_entries: does not install an icon for scripts alone" {
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries '/opt/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: heals kservices5 ServiceMenus too" {
	_fm_setup
	local menu
	_write_fm_menu "$FM_MOUNT" electron 'kservices5/ServiceMenus'
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries '/opt/Claude.AppImage' ''

	menu=$(_fm_menu 'kservices5/ServiceMenus')
	grep -qxF 'TryExec=/opt/Claude.AppImage' "$menu"
}

@test "heal_file_manager_entries: removes its icon once a system icon exists" {
	_fm_setup
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	heal_file_manager_entries '/opt/Claude.AppImage' "$TEST_TMP/icon.png"
	[[ -f $(_fm_icon) ]]
	mkdir -p "$XDG_DATA_DIRS/icons/hicolor/256x256/apps"
	printf 'system-icon' \
		> "$XDG_DATA_DIRS/icons/hicolor/256x256/apps/electron.png"

	heal_file_manager_entries '/opt/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: keeps a user-provided icon with the same name" {
	_fm_setup
	local icon
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	icon=$(_fm_icon)
	mkdir -p "${icon%/*}"
	printf 'user-icon' > "$icon"
	mkdir -p "$XDG_DATA_DIRS/icons/hicolor/16x16/apps"
	printf 'system-icon' \
		> "$XDG_DATA_DIRS/icons/hicolor/16x16/apps/electron.png"

	heal_file_manager_entries '/opt/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	[[ $(< "$icon") == 'user-icon' ]]
}

@test "heal_file_manager_entries: refuses an Icon name that escapes the icon directory" {
	_fm_setup
	_write_fm_menu "$FM_MOUNT" '../../../../tmp/evil'
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries '/opt/Claude.AppImage' \
		"$TEST_TMP/icon.png"

	[[ ! -e "$XDG_DATA_HOME/tmp/evil.png" ]]
	[[ ! -e $(_fm_icon) ]]
}

@test "heal_file_manager_entries: logs the old and new path once (FM-1)" {
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	_autostart_target_exists() { return 1; }

	heal_file_manager_entries '/opt/Claude.AppImage' ''

	grep -q 'Healed file-manager entry .*Send to Claude' "$log_file"
	grep -qF "$FM_MOUNT -> /opt/Claude.AppImage (FM-1)" "$log_file"
}

@test "cleanup_after_electron_exit: re-heals entries with the startup launcher" {
	_fm_setup
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	_autostart_target_exists() { return 1; }
	heal_file_manager_entries '/opt/Claude.AppImage' "$TEST_TMP/icon.png"

	# アプリが起動中にマウント先へ書き戻した状況を再現する
	_write_fm_script "$FM_MOUNT"
	_write_fm_menu "$FM_MOUNT"
	cleanup_after_electron_exit

	grep -qF "exec '/opt/Claude.AppImage'" "$(_fm_script)"
	grep -qxF 'TryExec=/opt/Claude.AppImage' "$(_fm_menu)"
}
