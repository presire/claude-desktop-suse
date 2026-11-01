#!/usr/bin/env bats
# shellcheck disable=SC2329  # BATSの@testブロックはモック関数を間接的に呼び出すため
# shellcheck disable=SC2030,SC2031  # @testごとにサブシェルで動くため、環境変数の変更は意図したもの
#
# @file doctor.bats
# @brief scripts/doctor.shの診断用ヘルパーを確認する
#
# 対象は _cowork_pkg_hint、_doctor_check_im_modules、_doctor_check_recent_crashes、
# _doctor_check_tray_icon などの診断ヘルパーで、判定結果と利用者向けの文言が
# 期待どおりになるかを固定する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

#
# @brief テストごとに分離した環境を用意し、doctor.shを読み込んで共通のスタブを置く
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

	# ホスト側の状態がテストに漏れないよう入力と表示の環境変数を消す
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset XDG_SESSION_TYPE
	unset CLAUDE_USE_WAYLAND
	unset GTK_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_PASSWORD_STORE
	unset CLAUDE_TRAY_USE_DARK_ICON

	# ホスト側のusernsのsysctlと検査結果がAppImageのサンドボックス判定に
	# 入らないよう (#884)、サンドボックスを起動できるホストを既定とする
	export _CLAUDE_USERNS_MAX="$TEST_TMP/userns-max"
	export _CLAUDE_USERNS_CLONE="$TEST_TMP/userns-clone"
	export _CLAUDE_USERNS_AA="$TEST_TMP/userns-aa"
	echo 63432 > "$_CLAUDE_USERNS_MAX"
	echo 1 > "$_CLAUDE_USERNS_CLONE"
	echo 0 > "$_CLAUDE_USERNS_AA"
	mkdir -p "$TEST_TMP/bin"
	export _CLAUDE_UNSHARE="$TEST_TMP/bin/unshare"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$_CLAUDE_UNSHARE"
	chmod +x "$_CLAUDE_UNSHARE"

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"

	_doctor_colors
	_doctor_failures=0

	# _pkg_installedは既定で「不明」(rc=2) を返す
	# パッケージ確認の分岐を試すテスト以外ではスタブを用意しなくて済むようにするため
	# インストール済み(rc=0) や未インストール(rc=1) にする場合はテスト内で上書きする
	# shellcheck disable=SC2317 # テスト用のスタブは読み込んだdoctor.shのヘルパーから間接的に呼び出されるため
	_pkg_installed() { return 2; }
	# shellcheck disable=SC2317 # テスト用のスタブは読み込んだdoctor.shのヘルパーから間接的に呼び出されるため
	_detect_password_store() { echo 'basic'; }
}

#
# @brief テスト用の一時ディレクトリを片付ける
#
teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief getconfの代替をPATHに置く
# @param $1 getconfが返す値 (空ならgetconfが失敗する状況を作る)
#
_install_getconf_shim() {
	mkdir -p "$TEST_TMP/bin"
	local value="$1"
	if [[ -z $value ]]; then
		cat > "$TEST_TMP/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/getconf" <<SHIM
#!/usr/bin/env bash
echo ${value}
SHIM
	fi
	chmod +x "$TEST_TMP/bin/getconf"
	export PATH="$TEST_TMP/bin:$PATH"
}

#
# @brief dfの代替をPATHに置く
# @param $1 dfのType列として返すファイルシステム種別 (空ならdfが失敗する状況を作る)
#
_install_df_shim() {
	mkdir -p "$TEST_TMP/bin"
	local fstype="$1"
	if [[ -z $fstype ]]; then
		cat > "$TEST_TMP/bin/df" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/df" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
Type
${fstype}
OUT
SHIM
	fi
	chmod +x "$TEST_TMP/bin/df"
	export PATH="$TEST_TMP/bin:$PATH"
}

#
# @brief gtk-query-immodules-3.0が無い状態を作り、immodulesキャッシュの確認を飛ばす
#
# キャッシュの分岐自体を試さないテストでも、手前の判定を抜けてこの確認まで
# 到達してしまうため、ここで確実に飛ばす
# command -vはbash関数も見つけてしまうため、スタブ関数を消すだけでは足りず
# command自体を上書きしている
#
_skip_gtk_query() {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
}

# =============================================================================
# _cowork_pkg_hint : ibus-gtk3への対応付け (#550)
# =============================================================================

@test "_cowork_pkg_hint: opensuse maps ibus-gtk3 to ibus-gtk3 via zypper" {
	local result
	result=$(_cowork_pkg_hint opensuse ibus-gtk3)
	[[ $result == "sudo zypper install ibus-gtk3" ]]
}

@test "_cowork_pkg_hint: sles maps ibus-gtk3 to ibus-gtk3 via zypper" {
	local result
	result=$(_cowork_pkg_hint sles ibus-gtk3)
	[[ $result == "sudo zypper install ibus-gtk3" ]]
}

# =============================================================================
# _doctor_check_im_modules : CLAUDE_GTK_IM_MODULEによる上書きの表示
# =============================================================================

@test "_doctor_check_im_modules: emits override line when CLAUDE_GTK_IM_MODULE set" {
	# CLAUDE_GTK_IM_MODULEが設定されているとactive_imが空にならず、
	# キャッシュの確認まで進んでしまうため、このテストでは確認を飛ばす
	_skip_gtk_query

	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output == *'CLAUDE_GTK_IM_MODULE=xim'* ]]
	[[ $output == *'overrides GTK_IM_MODULE for Electron'* ]]
}

@test "_doctor_check_im_modules: no override line when CLAUDE_GTK_IM_MODULE unset" {
	run _doctor_check_im_modules opensuse
	[[ $output != *'CLAUDE_GTK_IM_MODULE'* ]]
}

# =============================================================================
# _doctor_check_im_modules : WaylandとIBusが揃ったときの案内
# =============================================================================

@test "_doctor_check_im_modules: emits XWayland note when wayland session and CLAUDE_USE_WAYLAND unset" {
	XDG_SESSION_TYPE='wayland'
	# CLAUDE_USE_WAYLANDは意図的に設定しない
	run _doctor_check_im_modules opensuse
	[[ $output == *'XWayland'* ]]
	[[ $output == *'CLAUDE_USE_WAYLAND=1'* ]]
}

@test "_doctor_check_im_modules: no XWayland note when CLAUDE_USE_WAYLAND=1" {
	XDG_SESSION_TYPE='wayland'
	CLAUDE_USE_WAYLAND='1'
	run _doctor_check_im_modules opensuse
	[[ $output != *'XWayland'* ]]
}

@test "_doctor_check_im_modules: no XWayland note on X11 session" {
	XDG_SESSION_TYPE='x11'
	run _doctor_check_im_modules opensuse
	[[ $output != *'XWayland'* ]]
}

# =============================================================================
# _doctor_check_im_modules : ibus-gtk3パッケージの確認
# =============================================================================

@test "_doctor_check_im_modules: warns when ibus selected but ibus-gtk3 missing" {
	# パッケージが無いと確定する応答 (rc=1)
	# shellcheck disable=SC2317 # テスト用のスタブは_doctor_check_im_modulesから間接的に呼び出されるため
	_pkg_installed() { return 1; }

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules opensuse
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'ibus-gtk3 is not installed'* ]]
	[[ $output == *'sudo zypper install ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no warning when ibus selected and ibus-gtk3 present" {
	# パッケージがあり (rc=0)、キャッシュにもibusが載っている状態
	# shellcheck disable=SC2317 # テスト用のスタブは_doctor_check_im_modulesから間接的に呼び出されるため
	_pkg_installed() { return 0; }
	# shellcheck disable=SC2317 # commandの代替はcommand -vと検証対象のヘルパーから間接的に呼び出されるため
	gtk-query-immodules-3.0() {
		echo '"ibus" "IBus" "ibus" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no package warning when active module isn't ibus" {
	# ibus-gtk3が無い (rc=1) と答えても、GTK_IM_MODULEがibusでなければ
	# パッケージの確認自体を行わない
	# shellcheck disable=SC2317 # テスト用のスタブは_doctor_check_im_modulesから間接的に呼び出されるため
	_pkg_installed() { return 1; }
	_skip_gtk_query

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no package warning on unsupported distro (rc=2)" {
	# _pkg_installedは既定のまま (rc=2)
	# ibusが選ばれていても警告は出さない
	_skip_gtk_query

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules unknown
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _doctor_check_im_modules : immodulesキャッシュの確認
# =============================================================================

@test "_doctor_check_im_modules: warns when GTK_IM_MODULE not in immodules cache" {
	# gtk-query-immodules-3.0はximだけを返し、fcitxは載っていない状態
	# shellcheck disable=SC2317 # commandの代替は検証対象のヘルパーから間接的に呼び出されるため
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules opensuse
	[[ $output == *'[WARN]'* ]]
	[[ $output == *"'fcitx' not listed"* ]]
	[[ $output == *'gtk-query-immodules-3.0 --update-cache'* ]]
}

@test "_doctor_check_im_modules: no warning when active module is in cache" {
	# shellcheck disable=SC2317 # commandの代替は検証対象のヘルパーから間接的に呼び出されるため
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: skips cache check when gtk-query-immodules-3.0 missing" {
	_skip_gtk_query

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'cache may be stale'* ]]
}

@test "_doctor_check_im_modules: CLAUDE_GTK_IM_MODULE takes precedence as active module" {
	# キャッシュに載っているのはximだけで、ibusは載っていない
	# CLAUDE_GTK_IM_MODULE=ximがGTK_IM_MODULE=ibusより優先されるため、
	# キャッシュの警告は出ない
	# shellcheck disable=SC2317 # commandの代替は検証対象のヘルパーから間接的に呼び出されるため
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no checks fire when no IM module selected" {
	# GTK_IM_MODULEもCLAUDE_GTK_IM_MODULEも未設定の場合は、
	# パッケージの確認よりも前に何もせず戻る
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_password_store: output contains 'Password store:' with a valid backend" {
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Password store:'* ]]
	[[ $output == *'basic'* ]]
}

@test "_doctor_check_filename_limit: silent when NAME_MAX >= 200" {
	_install_getconf_shim '255'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: warns when NAME_MAX < 200" {
	_install_getconf_shim '143'
	_install_df_shim 'ext4'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'#590'* ]]
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: eCryptfs adds LUKS workaround hint" {
	_install_getconf_shim '143'
	_install_df_shim 'ecryptfs'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'eCryptfs'* ]]
	[[ $output == *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: silent on non-numeric getconf output" {
	_install_getconf_shim 'undefined'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: silent when getconf fails" {
	_install_getconf_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: df failure suppresses eCryptfs hint, keeps warn" {
	_install_getconf_shim '143'
	_install_df_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

# =============================================================================
# _doctor_check_recent_crashes : GPUのFATALで終わった回数の集計 (#583)
# =============================================================================

#
# @brief coredumpctlの代替をPATHに置き、渡した一覧出力をそのまま返させる
# @param $1 coredumpctlのlist風の複数行出力 (見出し行と各エントリ行)
# @note shimは引数を無視する
# テストでは絞り込みの書式を確認しないため
#
_install_coredumpctl_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/coredumpctl" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
$1
OUT
SHIM
	chmod +x "$TEST_TMP/bin/coredumpctl"
	export PATH="$TEST_TMP/bin:$PATH"
}

@test "_doctor_check_recent_crashes: no coredumpctl on PATH — silent" {
	# coredumpctlをPATHから外して、ヘルパーが早期に戻る状況を作る
	# 戻す前にPATHを復元しておかないと、teardownのrmが動かなくなる
	local saved_path="$PATH"
	export PATH="/no-such-dir-for-test"
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	export PATH="$saved_path"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: zero crashes — silent" {
	# 出力は見出し行だけで、エントリ行が無い状態
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: 1 crash — info line, no warn" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_recent_crashes: 3+ crashes — warn + #583 pointer" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M
Mon 2026-05-04 07:44:48 EDT 930532 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 22.8M
Sun 2026-05-03 14:34:10 EDT 567221 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 12.4M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'Recent Electron crashes: 3'* ]]
	[[ $output == *'CLAUDE_DISABLE_GPU=1'* ]]
	[[ $output == *'/issues/583'* ]]
}

@test "_doctor_check_recent_crashes: path mismatch falls back with footnote" {
	# 落ちたのは別のElectronアプリ (例 : Slack) のバイナリが3件
	# 呼び出し側が渡すのはclaude-desktop側のパスなので一致しないため、
	# ヘルパーは全体の件数に切り替え、その件数が他のアプリの分を
	# 含む可能性がある旨を注記として添える
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 09:00:00 EDT 200001 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-05 09:00:00 EDT 200002 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-04 09:00:00 EDT 200003 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

@test "_doctor_check_recent_crashes: empty electron_path falls back" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
	# 呼び出し側がelectron_pathを渡さない場合も、絞り込まずに
	# 全体の件数で情報行を出す
	run _doctor_check_recent_crashes ''
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

#
# @brief ランチャーの判定関数を使うテスト向けにlauncher-common.shを読み込む
#
# launcher-common.shは自身のディレクトリからdoctor.shを読み込むため、
# 一時ディレクトリへ両方を複製してから読み込む
#
_source_launcher_common() {
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/"
	sed -i 's/@@WM_CLASS@@/Claude/' "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
	_doctor_colors
}

@test "_doctor_check_pkg_version: appimage reads X-AppImage-Version" {
	local appdir="$TEST_TMP/appdir"
	mkdir -p "$appdir/usr/lib/node_modules/electron/dist"
	printf '[Desktop Entry]\nName=Claude\nX-AppImage-Version=1.2.3\n' \
		> "$appdir/io.github.presire.claude-desktop-suse.desktop"
	run _doctor_check_pkg_version \
		"$appdir/usr/lib/node_modules/electron/dist/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Installed version: 1.2.3 (AppImage)'* ]]
	[[ $output != *'rpm'* ]]
}

@test "_doctor_check_pkg_version: appimage without version stamp is info only" {
	local appdir="$TEST_TMP/appdir"
	mkdir -p "$appdir/usr/lib/node_modules/electron/dist"
	run _doctor_check_pkg_version \
		"$appdir/usr/lib/node_modules/electron/dist/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Installed version: unknown'* ]]
	[[ $output != *'[WARN]'* && $output != *'[FAIL]'* ]]
}

@test "_doctor_check_chrome_sandbox: appimage is informational, never FAIL" {
	run _doctor_check_chrome_sandbox "$TEST_TMP/missing/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Chrome sandbox: not used'* ]]
	[[ $output != *'sudo'* ]]
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_chrome_sandbox: rpm reports a missing helper" {
	run _doctor_check_chrome_sandbox "$TEST_TMP/dist/electron" 'rpm'
	[[ $status -eq 0 ]]
	[[ $output == *"Chrome sandbox not found at $TEST_TMP/dist/chrome-sandbox"* ]]
}

@test "_doctor_check_singleton_lock: regular file is reported, not 'no lock'" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	: > "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'present but not a symlink'* ]]
	[[ $output != *'no lock file'* ]]
}

@test "_doctor_check_singleton_lock: dead PID is stale" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	ln -s 'myhost-999999999' "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'stale lock found'* ]]
	[[ $output == *'is not running'* ]]
}

@test "_doctor_check_singleton_lock: unrecognized live holder is not called stale" {
	_source_launcher_common
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	ln -s "myhost-$$" "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'not recognized as Claude Desktop'* ]]
	[[ $output != *'stale lock found'* ]]
	[[ $output != *'Fix: rm'* ]]
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_device_registry: silent without a registry file" {
	run _doctor_check_device_registry "$XDG_CONFIG_HOME/Claude"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_device_registry: none row is INFO, never warn/fail, never echoes ids" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	local registry="$XDG_CONFIG_HOME/Claude/ant-device-registry.json"
	printf '{"acct-secret-id":"none:1761200000000"}' > "$registry"
	local before
	before=$(sha256sum "$registry")
	_doctor_check_device_registry "$XDG_CONFIG_HOME/Claude" > "$TEST_TMP/out"
	[[ $(< "$TEST_TMP/out") == *'Device registry: not registered'* ]]
	[[ $(< "$TEST_TMP/out") != *'acct-secret-id'* ]]
	[[ $(< "$TEST_TMP/out") != *'[WARN]'* && $(< "$TEST_TMP/out") != *'[FAIL]'* ]]
	[[ $_doctor_failures -eq 0 ]]
	[[ $(sha256sum "$registry") == "$before" ]]
}

@test "_doctor_check_device_registry: pk1 row reports registered" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	printf '{"a":"pk1:%064d:row"}' 0 \
		> "$XDG_CONFIG_HOME/Claude/ant-device-registry.json"
	run _doctor_check_device_registry "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'Device registry: registered'* ]]
	[[ $output != *'not registered'* ]]
}

@test "_doctor_check_device_registry: pku1 row reports unconfirmed" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	printf '{"a":"pku1:1761200000000:%064d:row"}' 0 \
		> "$XDG_CONFIG_HOME/Claude/ant-device-registry.json"
	run _doctor_check_device_registry "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'not yet confirmed'* ]]
}

@test "_doctor_check_display_server: XWayland tip names the portal" {
	export WAYLAND_DISPLAY='wayland-0'
	run _doctor_check_display_server
	[[ $output == *'X11 via XWayland (default)'* ]]
	[[ $output == *'GlobalShortcuts portal'* ]]
	[[ $output != *'disables global hotkeys'* ]]
}

@test "_doctor_check_display_server: no display fails" {
	run _doctor_check_display_server
	[[ $output == *'No display server detected'* ]]
}

@test "_doctor_check_effective_sandbox: silent without launcher library" {
	run _doctor_check_effective_sandbox 'rpm'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_effective_sandbox: rpm on native Wayland warns" {
	_source_launcher_common
	export WAYLAND_DISPLAY='wayland-0' CLAUDE_USE_WAYLAND=1
	unset CLAUDE_FORCE_SANDBOX
	detect_display_backend
	run _doctor_check_effective_sandbox 'rpm'
	[[ $output == *'disabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: CLAUDE_FORCE_SANDBOX=1 keeps it enabled" {
	_source_launcher_common
	export WAYLAND_DISPLAY='wayland-0' CLAUDE_USE_WAYLAND=1
	export CLAUDE_FORCE_SANDBOX=1
	detect_display_backend
	run _doctor_check_effective_sandbox 'rpm'
	[[ $output == *'enabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: appimage with working userns passes" {
	_source_launcher_common
	is_wayland=false
	run _doctor_check_effective_sandbox 'appimage'
	[[ $output == *'enabled at runtime (AppImage user-namespace sandbox)'* ]]
	[[ $output != *'--no-sandbox'* ]]
}

@test "_doctor_check_effective_sandbox: appimage with blocked userns warns with reason" {
	_source_launcher_common
	echo 1 > "$_CLAUDE_USERNS_AA"
	is_wayland=false
	run _doctor_check_effective_sandbox 'appimage'
	[[ $output == *'disabled at runtime'* ]]
	[[ $output == *'user namespaces restricted by AppArmor'* ]]
}

@test "_doctor_check_effective_sandbox: appimage FORCE_SANDBOX with blocked userns warns" {
	_source_launcher_common
	echo 1 > "$_CLAUDE_USERNS_AA"
	export CLAUDE_FORCE_SANDBOX=1
	is_wayland=false
	run _doctor_check_effective_sandbox 'appimage'
	[[ $output == *'CLAUDE_FORCE_SANDBOX=1 despite'* ]]
	[[ $output == *'user namespaces restricted by AppArmor'* ]]
}

@test "_doctor_check_cowork_daemon: silent when no daemon runs" {
	_source_launcher_common
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	_cowork_fallback_daemon_pids() { :; }
	run _doctor_check_cowork_daemon
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_cowork_daemon: orphan with no UI says restart" {
	_source_launcher_common
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 1; }
	# shellcheck disable=SC2317
	_claude_desktop_any_main_is_alive() { return 1; }
	run _doctor_check_cowork_daemon
	[[ $output == *'Cowork daemon: orphaned'* ]]
	[[ $output == *'4242'* ]]
	[[ $output == *'Restart Claude Desktop'* ]]
}

@test "_doctor_check_cowork_daemon: other build holding profile says quit it" {
	_source_launcher_common
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 1; }
	# shellcheck disable=SC2317
	_claude_desktop_any_main_is_alive() { return 0; }
	run _doctor_check_cowork_daemon
	[[ $output == *'Quit the other running Claude Desktop'* ]]
}

@test "_doctor_check_cowork_daemon: daemon with live UI passes" {
	_source_launcher_common
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 0; }
	run _doctor_check_cowork_daemon
	[[ $output == *'running (parent alive)'* ]]
}

# =============================================================================
# _doctor_check_tray_icon (上流のclaude-desktop-debian #604から移植)
#
# ここでは表示だけを確認する
# 自動判定の結果はランチャー側のsetup_tray_icon_envが決めていて、
# その挙動はlauncher-common.batsで固定している
# そのためこのファイルでは、指定値が優先されること、
# ヘルパーが設定した値が表示されること、
# doctor.shを単体で読み込んだ場合は何も出さないことを固定する
# =============================================================================

@test "_doctor_check_tray_icon: preset reports the forced value (no PASS/FAIL)" {
	CLAUDE_TRAY_USE_DARK_ICON=0
	run _doctor_check_tray_icon
	[[ $status -eq 0 ]]
	[[ $output == *'CLAUDE_TRAY_USE_DARK_ICON=0 (preset'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_tray_icon: non-0/1 preset draws a WARN" {
	CLAUDE_TRAY_USE_DARK_ICON=true
	run _doctor_check_tray_icon
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'not 0/1'* ]]
}

@test "_doctor_check_tray_icon: silent when launcher-common is not in scope" {
	run _doctor_check_tray_icon
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_tray_icon: reports Cinnamon auto-detect verdict" {
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	setup_tray_icon_env() { export CLAUDE_TRAY_USE_DARK_ICON=1; }
	run _doctor_check_tray_icon
	[[ $status -eq 0 ]]
	[[ $output == *'Cinnamon dark panel auto-detected'* ]]
	[[ $output == *'TrayIconLinux-Dark.png'* ]]
}

@test "_doctor_check_tray_icon: reports upstream selection when auto-detect is a no-op" {
	# shellcheck disable=SC2317 # スタブは検証対象のチェックから呼び出されるため
	setup_tray_icon_env() { :; }
	run _doctor_check_tray_icon
	[[ $status -eq 0 ]]
	[[ $output == *'upstream selection (no override)'* ]]
}

@test "run_doctor: wires the tray icon check" {
	grep -q '^	_doctor_check_tray_icon$' "$SCRIPT_DIR/../scripts/doctor.sh"
}
