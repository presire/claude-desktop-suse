#!/usr/bin/env bash
#
# @file launcher-common.sh
# @brief RPM版とAppImage版のランチャーが共有する処理をまとめる
#
# 表示バックエンドの判定、Electronに渡す起動引数の組み立て、
# 前回の起動が残したプロセスの後始末、ランチャー設定の読み込みを提供する
# 実行用のスクリプトではなく、各パッケージのランチャーがsourceして使う
#
# 読み込み元 : /usr/bin/claude-desktop (RPM版)、AppRun (AppImage版)
# 参照するグローバル変数 : CLAUDE_USE_WAYLAND、CLAUDE_DISABLE_GPUなどの起動設定
# 変更するグローバル変数 : WM_CLASS、log_dir、log_file、is_wayland、use_x11_on_wayland
#

# WM_CLASSは--classで渡すプロセスの目印としてのみ使う
# pgrepと/proc/PID/cmdlineの照合にだけ使い、Chromiumはこれを
# ウィンドウのクラスには使わない、実際のX11 WM_CLASSとWaylandのapp_idは
# asarのpackage.jsonにあるdesktopNameから決まるため
# .desktopのStartupWMClassもその値から作っている (#779)
# @@WM_CLASS@@はパッケージ作成時にscripts/packaging/{rpm,appimage}.shが置き換える
readonly WM_CLASS='@@WM_CLASS@@'

#
# @brief ログが上限を超えたら古い世代に退避して肥大化を防ぐ
# @global log_file 退避の対象になるログファイル (参照のみ)
# @note 退避は起動の途中で走るため、どの経路でも0を返して起動を止めない
#
rotate_log_file() {
	[[ -n ${log_file:-} && -f $log_file ]] || return 0

	local max_bytes=$((5 * 1024 * 1024))
	local keep=2 size i

	size=$(stat -c '%s' "$log_file" 2>/dev/null) || return 0
	[[ $size =~ ^[0-9]+$ ]] || return 0
	((size > max_bytes)) || return 0

	for ((i = keep - 1; i >= 1; i--)); do
		[[ -f "$log_file.$i" ]] && \
			mv -f "$log_file.$i" "$log_file.$((i + 1))" 2>/dev/null
	done
	mv -f "$log_file" "$log_file.1" 2>/dev/null || return 0
}

#
# @brief ログの置き場所を決めて退避を済ませる
# @global log_dir ログを置くディレクトリ (本関数で設定する)
# @global log_file 追記するログファイル (本関数で設定する)
# @return 0 = 準備できた、1 = ディレクトリを作れなかった
#
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
	rotate_log_file
	return 0
}

#
# @brief ランチャーのログに1行追記する
# @param $1... 追記するメッセージ
# @global log_file 追記先のログファイル (参照のみ)
# @note OAuthのトークンがURLに載るため、claude://loginのクエリは伏せる
# @note setup_loggingが未実行でlog_fileが空の場合は何もしない
#
log_message() {
	[[ -n ${log_file:-} ]] || return 0
	local msg="$*"
	if [[ "$msg" == *claude://login* ]]; then
		msg=$(printf '%s' "$msg" \
			| sed -E 's#(claude://login[^ ?]*)\?[^ ]*#\1?<redacted>#g')
	fi
	echo "$msg" >> "$log_file"
}

#
# @brief 表示と入力の判定に使う環境変数をひとかたまりでログに残す
# @global log_file 追記先のログファイル (参照のみ)
# @note 不具合報告のたびに環境を聞き直さずに済むようにするため (#548)
# @note 未設定の変数もKEY=の形で残し、記録漏れと区別できるようにする
# @note 呼び出し側が先にsetup_loggingを実行しておく必要がある
#
log_session_env() {
	local key
	log_message 'env={'
	for key in \
		XDG_SESSION_TYPE \
		WAYLAND_DISPLAY \
		DISPLAY \
		XDG_CURRENT_DESKTOP \
		GTK_IM_MODULE \
		XMODIFIERS \
		QT_IM_MODULE \
		CLAUDE_USE_WAYLAND \
		CLAUDE_TITLEBAR_STYLE \
		CLAUDE_PASSWORD_STORE \
		CLAUDE_GTK_IM_MODULE \
		CLAUDE_DISABLE_GPU \
		CLAUDE_TRAY_USE_DARK_ICON
	do
		log_message "  $key=${!key:-}"
	done
	log_message '}'
}

#
# @brief Waylandで動いているかを見て、X11とWaylandのどちらで起動するかを決める
# @global is_wayland Waylandセッションならtrue (本関数で設定する)
# @global use_x11_on_wayland trueならWayland上でもXWaylandを使う (本関数で設定する)
# @note 既定はXWaylandで、上流のglobalShortcut ([Ctrl]+[Alt]+[Space]) が
#       X11のキーグラブでそのまま動くようにするため
# @note [CLAUDE_USE_WAYLAND]は3状態、1=ネイティブWaylandを強制、
#       0=XWaylandを強制して自動判定を行わない、未設定=コンポジタごとに自動判定
#
detect_display_backend() {
	is_wayland=false
	[[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=true

	# 既定ではWayland上でもX11 (XWayland) を使う
	# クイックウィンドウのホットキーがglobalShortcutのX11のキーグラブで
	# 受け取られるため
	#
	# [CLAUDE_USE_WAYLAND]は3状態で扱う
	#   1     - ネイティブWaylandを強制する (ホットキーはXDGポータル経由)
	#   0     - XWaylandを強制し、下の自動判定を行わない
	#   未設定 - コンポジタごとに自動判定する
	use_x11_on_wayland=true
	local wayland_override="${CLAUDE_USE_WAYLAND:-}"
	[[ $wayland_override == '1' ]] && use_x11_on_wayland=false

	# #226の修正で、自動でネイティブWaylandにするのはNiriだけにしている
	# NiriはXWaylandを持たず、X11バックエンドでは起動できないため
	#
	# GNOMEのWaylandは自動では切り替えない
	# mutterがXWaylandのグローバルキーグラブを扱わなくなったため (#404)
	# ネイティブWaylandにするとglobalShortcutがXDGの
	# GlobalShortcutsポータル経由になるが、実績のあるXWaylandから
	# 既定を動かすのは描画、IME、HiDPIの面で危険が大きい
	# GNOME 50ではポータル経由自体が何もしない (electron/electron#51875)
	# ポータル経由を望む利用者は[CLAUDE_USE_WAYLAND]=1で選べる
	# (GNOME 49以前なら初回のポータル許可ダイアログの後に動く)
	#
	# SwayとHyprlandはXWaylandのグラブが動き続けるうえ
	# wlrootsのポータルにGlobalShortcutsの実装がないため
	# こちらも既定のXWaylandのままにし、必要なら
	# [CLAUDE_USE_WAYLAND]=1で選ぶ
	# [CLAUDE_USE_WAYLAND]=0を明示すると自動判定を行わない
	#
	# [XDG_CURRENT_DESKTOP]はコロン区切り("niri:GNOME")のことがあるため
	# 部分一致で見分ける
	if [[ $is_wayland == true && $use_x11_on_wayland == true \
		&& $wayland_override != '0' ]]; then
		local desktop="${XDG_CURRENT_DESKTOP:-}"
		desktop="${desktop,,}"

		if [[ -n "${NIRI_SOCKET:-}" || "$desktop" == *niri* ]]; then
			log_message "Niri detected - forcing native Wayland"
			use_x11_on_wayland=false
		fi
	fi
}

#
# @brief GUIを開ける表示先があるかを確認する
# @return 0 = 表示先がある、1 = TTYから実行されていて表示先がない
#
check_display() {
	[[ -n $DISPLAY || -n $WAYLAND_DISPLAY ]]
}

#
# @brief [CLAUDE_TITLEBAR_STYLE]をhybrid、native、hiddenのどれかに決める
# @stdout 決めたスタイル名 (環境変数には書き戻さない)
# @note 未設定や不正な値はhybridにする、Linuxで推奨する組み合わせのため
# @note hybridはOSのウィンドウ枠にwco-shim経由のアプリ内バーを重ねる
# @note hiddenは上流の枠なしWCO構成で、LinuxのX11ではクリックが
#       効かなくなるがWaylandとの比較用に残している
#
_resolve_titlebar_style() {
	local raw="${CLAUDE_TITLEBAR_STYLE:-hybrid}"
	raw="${raw,,}"
	case "$raw" in
		hybrid|hidden|native) echo "$raw" ;;
		*) echo 'hybrid' ;;
	esac
}

#
# @brief 使えるパスワードストアを調べ、--password-storeに渡す値を決める
# @stdout kwallet6、gnome-libsecret、basicのいずれか
# @note safeStorageとCookieの暗号化は--password-storeで選ぶOSの
#       資格情報ストアに依存する、使えるものがないと
#       safeStorage.isEncryptionAvailable()がfalseになり
#       OAuthのトークンは終了時に黙って捨てられて
#       起動のたびに再認証になる (Cookiesファイルは0バイトのまま) (#593)
# @note 選ぶ順番は次のとおりで、先に一致したものを採用する
#       [CLAUDE_PASSWORD_STORE] - 利用者が明示した指定
#       kwallet6 - KDE Plasma 6のキーリング
#       gnome-libsecret - GNOME Keyringやlibsecretの互換ブリッジ
#       basic - 固定の内部鍵 (必ず使える)
# @note basicでは保存データを固定鍵で暗号化するため
#       保護は~/.config/Claude/のパーミッションだけになる
# @note D-Busのセッションバスがある前提で、グラフィカルログインなら満たされる
#
_detect_password_store() {
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		echo "$CLAUDE_PASSWORD_STORE"
		return
	fi

	# KDE Plasma 6のキーリング
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.kde.kwalletd6 \
		/modules/kwalletd6 \
		org.kde.KWallet.isEnabled 2>/dev/null \
		| grep -q 'boolean true'
	then
		echo 'kwallet6'
		return
	fi

	# GNOME KeyringやKWallet 5の互換ブリッジなど
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.freedesktop.secrets \
		/org/freedesktop/secrets \
		org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
	then
		echo 'gnome-libsecret'
		return
	fi

	# どのキーリングにも届かないため、固定鍵の方式に落とす
	echo 'basic'
}

#
# @brief 前回の起動がGPUプロセスの異常終了で終わったかを判定する
# @global log_file 読むログファイル (参照のみ)
# @return 0 = 前回はGPUの異常終了、1 = それ以外
# @note setup_loggingを先に実行しておく必要がある
# @note ランチャーは現セッションの見出しを先に書くため
#       前回の起動はログの最後から2番目のセクションにある
# @note --disable-gpuで復旧した起動はGPUの出力を残さないため
#       異常終了の痕跡だけを見ていると次の起動でGPUを戻してしまい
#       壊れたハードウェアで異常終了と復旧を繰り返す
#       そこでランチャー自身の「GPUを無効にした」記録も手掛かりにして
#       一度復旧したら復旧したままにする
#       ハードウェアアクセラレーションを試し直すときは[CLAUDE_DISABLE_GPU]=0を使う
# @note セクションの見出しはRPM版がLauncher Start
#       AppImage版がAppImage Start
# @note 退避が走った起動では本体のログに現セッションの見出ししかなく
#       前回の起動は.1の最後のセクションになる
#       本体のセクションが2つ未満で.1があるときは走査を3で終え
#       .1と本体を繋いでやり直す、これで.1の最後のセクションが
#       最後から2番目になる
#       claude-desktop-debianの#946から移植した
#
_previous_launch_hit_gpu_fatal() {
	[[ -f ${log_file:-} ]] || return 1

	local rotated="$log_file.1" defer=0 status
	[[ -f $rotated ]] && defer=1

	_scan_gpu_fatal_sections "$defer" "$log_file"
	status=$?
	((status == 3)) || return "$status"
	_scan_gpu_fatal_sections 0 "$rotated" "$log_file"
}

#
# @brief _previous_launch_hit_gpu_fatalの本体で、ログを1回だけ走査する
# @param $1 1ならセクションが2つ未満のときに終了コード3を返す (退避の有無)
# @param $2... 走査するログファイル (先に読むものから順に指定する)
# @return 0 = 該当あり、1 = 該当なし、3 = セクション不足で呼び出し側に委ねる
# @note GPUプロセスの起動失敗、GPUプロセスが使えない、
#       GPUを無効にした記録という3種類の痕跡を
#       セクション単位で集計する
#
_scan_gpu_fatal_sections() {
	local defer=$1
	shift

	awk -v defer="$defer" '
		/^--- Claude Desktop (Launcher|AppImage) Start( \(NixOS\))? ---$/ {
			section++
			prev_failed = cur_failed
			prev_notusable = cur_notusable
			prev_prevfatal = cur_prevfatal
			cur_failed = 0
			cur_notusable = 0
			cur_prevfatal = 0
			next
		}
		{
			if (index($0,
				"GPU process launch failed: error_code=")) {
				cur_failed = 1
			}
			if (index($0,
				"GPU process isn'\''t usable. Goodbye.")) {
				cur_notusable = 1
			}
			if (index($0,
				"Previous launch hit GPU process FATAL")) {
				cur_prevfatal = 1
			}
		}
		END {
			if (section < 2 && defer) {
				exit 3
			}
			if (section >= 2) {
				t_failed = prev_failed
				t_notusable = prev_notusable
				t_prevfatal = prev_prevfatal
			} else if (section == 1) {
				t_failed = cur_failed
				t_notusable = cur_notusable
				t_prevfatal = cur_prevfatal
			} else {
				exit 1
			}
			if ((t_failed && t_notusable) || t_prevfatal) {
				exit 0
			}
			exit 1
		}
	' "$@"
}

#
# @brief Chromiumの名前空間サンドボックスが使えない理由を調べる
# @stdout 使えない理由の説明 (使える場合は何も出さない)
# @return 0 = サンドボックスは使えない、1 = 使える
# @note AppImageはnosuidのFUSEマウントから動くためsetuidの
#       chrome-sandboxは使えず、名前空間サンドボックスだけが選択肢になる
# @note 次のsysctlを順に見て、遮断されていればその理由を返す
#       [user.max_user_namespaces]が0または不在 - 無効かCONFIG_USER_NSなし
#       [kernel.unprivileged_userns_clone]=0 - Debian系やlinux-hardenedの設定
#       [kernel.apparmor_restrict_unprivileged_userns]=1 - Ubuntu 24.04以降などで
#       AppImageの/tmp/.mount_*のパスにプロファイルを当てられず遮断されたままになる
# @note sysctlでは分からない遮断 (Dockerの既定seccomp、distrobox、toolbox) が
#       あるため、どれにも当たらなければChromiumのzygoteが要る名前空間
#       (user、pid、net) を実際に作ってみる、数ミリ秒で済む
# @note 試行は_CLAUDE_UNSHARE_TIMEOUT秒 (既定5) で打ち切り
#       固まったunshareでランチャーを止めないため
# @note util-linuxのunshareがない環境ではsysctlの判定結果をそのまま使う
# @note テスト用に_CLAUDE_USERNS_MAX、_CLAUDE_USERNS_CLONE、_CLAUDE_USERNS_AA、
#       _CLAUDE_UNSHARE、_CLAUDE_UNSHARE_TIMEOUTで差し替えられる
#
_userns_sandbox_block_reason() {
	local max_path="${_CLAUDE_USERNS_MAX:-/proc/sys/user/max_user_namespaces}"
	local clone_path="${_CLAUDE_USERNS_CLONE:-/proc/sys/kernel/unprivileged_userns_clone}"
	local aa_path="${_CLAUDE_USERNS_AA:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
	local val=''

	[[ -r $max_path ]] && val=$(<"$max_path")
	if [[ ! $val =~ ^[0-9]+$ || $val -eq 0 ]]; then
		echo 'user namespaces disabled (user.max_user_namespaces=0)'
		return 0
	fi
	val=''
	[[ -r $clone_path ]] && val=$(<"$clone_path")
	if [[ $val == '0' ]]; then
		echo 'unprivileged user namespaces disabled' \
			'(kernel.unprivileged_userns_clone=0)'
		return 0
	fi
	val=''
	[[ -r $aa_path ]] && val=$(<"$aa_path")
	if [[ $val == '1' ]]; then
		echo 'user namespaces restricted by AppArmor' \
			'(kernel.apparmor_restrict_unprivileged_userns=1)'
		return 0
	fi

	local unshare_bin="${_CLAUDE_UNSHARE:-unshare}" err
	local probe_timeout="${_CLAUDE_UNSHARE_TIMEOUT:-5}"
	command -v "$unshare_bin" &> /dev/null || return 1

	local -a probe=("$unshare_bin" --user --map-root-user --pid --net \
		--fork true)
	if [[ $probe_timeout =~ ^[0-9]+$ ]] && command -v timeout &> /dev/null; then
		probe=(timeout "$probe_timeout" "${probe[@]}")
	fi
	if ! err=$("${probe[@]}" 2>&1 > /dev/null); then
		err=${err%%$'\n'*}
		echo "user namespace creation failed${err:+ ($err)}"
		return 0
	fi
	return 1
}

#
# @brief 表示環境と設定からElectronに渡す引数を組み立てる
# @param $1 パッケージ形式、appimageかrpm (--no-sandboxの判断に使う)
# @global is_wayland、use_x11_on_wayland 判定した表示環境 (参照のみ)
# @global electron_args 組み立てた引数を入れる配列 (本関数で設定する)
# @note detect_display_backendを先に実行しておく必要がある
#
build_electron_args() {
	local package_type="${1:-rpm}"

	electron_args=()

	# Chromiumはコマンドラインの--enable-featuresのうち最後の1つしか
	# 見ないため、必要な機能はすべて1つのカンマ区切りの値にまとめる
	# ここで溜めておき、関数の最後に1回だけ出力する
	local enable_features=()

	# AppImageのFUSEマウントはnosuidのためsetuidのchrome-sandboxは
	# 使えないが、Chromiumの名前空間サンドボックスは使える
	# --no-sandboxを渡すのはユーザー名前空間が本当に使えないときだけ
	# それ以外で渡すとChromiumが起動時に異常終了する
	# 判定はsysctlを読むだけでなく実際に名前空間を作るため
	# コンテナのseccompポリシーも見つけられる
	# [CLAUDE_FORCE_SANDBOX]=1なら失敗する場合でもサンドボックスを残す
	# 参照 : #884、#804
	local userns_block
	if [[ $package_type == 'appimage' ]] \
		&& userns_block=$(_userns_sandbox_block_reason); then
		if [[ ${CLAUDE_FORCE_SANDBOX:-} == '1' ]]; then
			log_message 'CLAUDE_FORCE_SANDBOX=1 - keeping Chromium' \
				"sandbox enabled despite: $userns_block"
		else
			electron_args+=('--no-sandbox')
			log_message "Chromium sandbox disabled: $userns_block"
		fi
	fi

	# [CLAUDE_TITLEBAR_STYLE]で次のどれかを選ぶ
	#   hybrid (既定) とnative : --disable-features=CustomTitlebarを付け
	#           Chromiumが描くCSDのタイトルバーがデスクトップ環境の
	#           ウィンドウ枠と競合しないようにする、どちらもframe:true
	#   hidden : WindowControlsOverlayを有効にする
	#           WCOはWindowsとmacOSでは既定で有効だがLinuxのChromiumでは
	#           無効のため、有効にしないとtitleBarOverlayが
	#           ページ側で黙って無視される
	local _tb
	_tb=$(_resolve_titlebar_style)
	if [[ $_tb == 'hidden' ]]; then
		enable_features+=('WindowControlsOverlay')
	else
		electron_args+=('--disable-features=CustomTitlebar')
	fi

	# プロセスの目印としてのみ渡す、Chromiumは--classをウィンドウの
	# クラスには使わず、.desktopのStartupWMClassはasarのdesktopNameから
	# 決めている (#779)、参照 : #647、#652
	electron_args+=("--class=$WM_CLASS")

	# safeStorageとCookieの暗号化は、--password-storeで選ぶシステムの
	# キーリングを必要とする
	# 値を渡さないとキーリングのデーモンが動いていても
	# 暗号化不可と報告されることがあり、OAuthのトークンが終了時に
	# 捨てられて起動のたびに再認証になる
	# そのため起動時に使えるストアを調べて渡す (#593)
	local pw_store
	pw_store=$(_detect_password_store)
	electron_args+=("--password-store=${pw_store}")
	log_message "Password store: ${pw_store}"

	# XRDPのリモートセッションはGPU支援がなく、GPU合成を有効にすると
	# 真っ白なウィンドウになる
	# XRDP_SESSION (xrdpのセッション初期化が設定する) と
	# loginctlで見るセッション種別で判別する
	# xrdp-sesmanをpgrepで探さないのは、ローカルセッションのホストでも
	# 同じデーモンが動いているため (#319)
	local rdp_session_type=''
	[[ -n ${XDG_SESSION_ID:-} ]] && rdp_session_type=$(
		loginctl show-session "$XDG_SESSION_ID" \
			-p Type --value 2>/dev/null
	)
	# --disable-gpuを二重に積まないよう、判断を1つの変数にまとめる
	# XRDPとCLAUDE_DISABLE_GPUのどちらか一方で十分
	local _disable_gpu=false
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		_disable_gpu=true
		log_message 'XRDP session detected - GPU compositing disabled'
	fi
	# [CLAUDE_DISABLE_GPU]=1は、ChromiumのGPUプロセスがFATALで
	# 落ち続ける場合の任意の回避策 (#583)
	# 上流では設定画面のハードウェアアクセラレーションを切るのと同じだが
	# 落ち続ける状況では設定画面を開けないため、環境変数で残せるようにする
	if [[ -v CLAUDE_DISABLE_GPU ]]; then
		if [[ ${CLAUDE_DISABLE_GPU} == '1' ]]; then
			_disable_gpu=true
			log_message \
				'CLAUDE_DISABLE_GPU=1 - hardware acceleration disabled'
		fi
	elif _previous_launch_hit_gpu_fatal; then
		_disable_gpu=true
		log_message \
			'Previous launch hit GPU process FATAL - disabling GPU'
	fi
	# Chromiumのソフトウェアラスタライザは残しておく
	# ハードウェアGPUとソフトウェアのフォールバックを両方切ると
	# Electronが復帰せず「GPU process isn't usable」で止まることがある
	[[ $_disable_gpu == true ]] && electron_args+=('--disable-gpu')

	# X11セッションでは表示バックエンドの引数は要らない
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
	else
		# Waylandではrpm版がどちらのモードでも--no-sandboxを要する
		# (AppImage版は上のユーザー名前空間の判定で決めている)
		# [CLAUDE_FORCE_SANDBOX]=1は[CLAUDE_DISABLE_GPU]と対になる
		# 明示的な逃げ道で、setuidのchrome-sandboxが問題なく動くと
		# 分かっている利用者がサンドボックスを残すために使う
		# AppImage版では判定が遮断を示していても名前空間サンドボックスを残す
		if [[ ${CLAUDE_FORCE_SANDBOX:-} == '1' && $package_type == 'rpm' ]]; then
			log_message \
				'CLAUDE_FORCE_SANDBOX=1 - keeping Chromium sandbox enabled on Wayland'
		elif [[ $package_type == 'rpm' ]]; then
			electron_args+=('--no-sandbox')
		fi

		if [[ $use_x11_on_wayland == true ]]; then
			# XWaylandでX11を使う、globalShortcutはX11のキーグラブで動く
			log_message 'Using X11 backend via XWayland (for global hotkey support)'
			electron_args+=('--ozone-platform=x11')
		else
			# ネイティブWaylandではglobalShortcutをX11のキーグラブではなく
			# XDGのGlobalShortcutsPortal経由にする
			# Waylandのozoneプラットフォームが必要で、この機能は
			# XWayland上では意味を持たない、Electron 35以降が前提
			# mutterがXWaylandのグラブを扱わなくなったGNOMEの#404を直す
			# ポータルにGlobalShortcutsの実装がないコンポジタ (wlrootsなど)
			# では何も起きないだけで害はない
			log_message 'Using native Wayland backend (global shortcuts via XDG portal)'
			enable_features+=(
				'UseOzonePlatform'
				'WaylandWindowDecorations'
				'GlobalShortcutsPortal'
			)
			electron_args+=('--ozone-platform=wayland')
			electron_args+=('--enable-wayland-ime')
			electron_args+=('--wayland-text-input-version=3')
			# システム全体のGDK_BACKEND=x11が残っているとGTKが
			# Waylandコンポジタに繋げず、HiDPIでぼやけた描画や
			# 起動失敗の原因になるため上書きする
			export GDK_BACKEND=wayland
		fi
	fi

	# 溜めた機能を1つのスイッチとしてまとめて出力する
	# まとめる必要がある理由はenable_featuresの宣言箇所に書いた
	if [[ ${#enable_features[@]} -gt 0 ]]; then
		local IFS=','
		electron_args+=("--enable-features=${enable_features[*]}")
	fi
}

# /proc/PID/cmdline (空白で連結したもの) がClaude Desktop本体の
# メインプロセスかを判定する
#
# @brief コマンドラインからUI本体のメインプロセスを見分ける
# @param $1 空白で連結したコマンドライン
# @return 0 = UI本体のメインプロセス、1 = それ以外
# @note app.asarでは見分けられない、#700以降ランチャーが引数で
#       渡さなくなり、Electronがresources/から自動で読み込むため
#       cmdlineには現れない
# @note rpm版とAppImage版で共通の目印は、どのランチャーも
#       build_electron_argsで渡す--class=[WM_CLASS]になる
#       Chromiumはexecしたargvを/proc/PID/cmdlineに残し
#       --type=付きの子プロセスには--classを引き継がない (実測)
# @note 呼び出し側がtr '\0' ' 'で連結するため各引数の末尾は空白になる
#       その末尾の空白まで含めて照合し、ClaudeDevのような
#       紛らわしいクラス名を弾く
_claude_desktop_ui_cmdline_matches() {
	local cmdline="$1"

	# coworkデーモン (--classを持たないため念のため) とChromiumの
	# ヘルパー (zygote、renderer、gpu、utilityなど) は対象にしない
	[[ $cmdline == *cowork-vm-service* ]] && return 1
	[[ $cmdline == *cowork-linux-helper* ]] && return 1
	[[ $cmdline == *--type=* ]] && return 1

	[[ $cmdline == *"--class=$WM_CLASS "* ]]
}

# このユーザー向けにClaude DesktopのUIが動いているか
#
# @brief --classの指紋が付いたUIのプロセスIDを列挙する
# @global WM_CLASS ... (参照のみ)
# @return 0 = 常に成功、該当がなければ何も出力しない
# @note pgrep -f 'claude-desktop'だけでは判定できない
#       ランチャー自身のbash (このスクリプトのcmdlineには
#       /usr/bin/claude-desktopが入る)、前回のクラッシュ後に
#       停止やゾンビのまま残ったランチャーのbash、
#       coworkデーモンそのものにも当たるため
#       それらをUIが生きていると数えると、後段の後始末が誤動作する
# @note 正しい定義は、cmdlineに--classの指紋を持つ
#       (_claude_desktop_ui_cmdline_matchesを参照)
#       かつ実行可能な状態 (停止でもゾンビでもない) プロセスで
#       ランチャー自身のbashとその親は除く
# @note _claude_desktop_ui_pidsは指紋に一致するPIDを1行ずつ出力し
#       _claude_desktop_own_ui_is_aliveが実行可能かの判定を重ねる
_claude_desktop_ui_pids() {
	local pid cmdline
	for pid in \
		$(pgrep -u "$(id -u)" -f -- "--class=$WM_CLASS" 2>/dev/null); do
		# ランチャー自身のbashとその親は除く
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_claude_desktop_ui_cmdline_matches "$cmdline" || continue
		printf '%s\n' "$pid"
	done
}

# /proc/PID/statusにあるプロセス状態の文字 (R、S、T、t、Zなど)
#
# @brief プロセス状態の1文字を取り出す
# @param $1 対象のPID
# @return 0 = 取得できた、1 = 取得できなかった
_proc_state() {
	local key value rest
	while read -r key value rest; do
		if [[ $key == 'State:' ]]; then
			printf '%s' "$value"
			return 0
		fi
	done 2>/dev/null < "/proc/$1/status"
	return 1
}

# このユーザー向けに実行可能なClaude DesktopのUIがあるか
#
# @brief 自前のUIか他のビルドのメインプロセスがいれば成功する
# @return 0 = どちらかが動いている、1 = どちらもいない
# @note 判定を2つ持つのは、この答えが後片付けを止める側に働くため
#       「いない」と答えたときだけヘルパーを終了させる
# @note 自前のUIは--class=[WM_CLASS]を持つ
#       (_claude_desktop_own_ui_is_alive)
#       並んで導入された別のビルド (Anthropicの公式パッケージや
#       上流claude-desktop-debianのRPM) はclaude-desktopという
#       ELFを実行し、--classを持たないことがある
#       そのメインプロセスも動いているとみなす
# @note この広い判定は後片付けを余計に止めるだけで、害はない
_claude_desktop_ui_is_alive() {
	_claude_desktop_own_ui_is_alive || _claude_desktop_any_main_is_alive
}

# 自前のランチャーのUI (--class=[WM_CLASS]) が動いているか
#
# @brief 指紋に一致するUIが停止もゾンビもしていないか調べる
# @global WM_CLASS ... (参照のみ)
# @return 0 = 動いている、1 = いない
# @note 自前のcoworkデーモンの親になれるのはこれだけなので
#       doctorは後片付けより狭いこの判定を使う
_claude_desktop_own_ui_is_alive() {
	local pid state
	for pid in $(_claude_desktop_ui_pids); do
		# 停止 (T/t) とゾンビ (Z) は動いているUIとみなさない
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# 生きているElectronのUIが見つかった
		return 0
	done
	return 1
}

# 誰が起動したかにかかわらず、このユーザー向けに実行可能な
# claude-desktopのElectronメインプロセスがあるか
#
# @brief exe名と--type=の有無からメインプロセスを探す
# @return 0 = ある、1 = ない
# @note 自前のビルドはnpmのElectronバイナリを実行する
#       (exe名がelectron) ため上の--classの判定で足りる
#       こちらはElectronのELFをclaude-desktopという名前で
#       同梱するビルドを拾う
# @note Chromiumのヘルパーは同じバイナリに--type=が付くだけなので
#       exe名がclaude-desktop、(" (deleted)"を除く、更新で
#       実体が入れ替わった場合向け)、--type=なし、
#       Nodeとしての実行でない ([ELECTRON_RUN_AS_NODE]=1でない)
#       ことを条件にする
#       ランチャーのスクリプトはexeがbashなので外れる
_claude_desktop_any_main_is_alive() {
	local pid exe cmdline state
	for pid in $(pgrep -u "$(id -u)" -x claude-desktop 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
		exe=${exe% (deleted)}
		[[ ${exe##*/} == claude-desktop ]] || continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		[[ $cmdline == *--type=* ]] && continue
		# Nodeとして動くElectron (フォークやMCPサーバー) は
		# exeが同じで--type=もないがメインプロセスではない
		# これを数えると孤児が判定を開いたまま自分を守れてしまう
		# environが読めない場合は動いている側に倒す (安全側)
		tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
			| grep -qx 'ELECTRON_RUN_AS_NODE=1' && continue
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		return 0
	done
	return 1
}

# /proc/[PID]/statの指定したフィールドを出力する
# 数え方は"(comm)"の後ろから
#
# @brief commに空白や括弧が入りうるため、最後の") "から分割する
# @param $1 対象のPID
# @param $2 0始まりの添字
# @return 0 = 取得できた、1 = 取得できなかった
# @note 添字0は状態 (proc(5)の第3フィールド)、2はプロセスグループ
#       19は起動からのクロック刻みで数えた起動時刻になる
_proc_stat_field() {
	local stat
	local -a fields
	{ read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
	read -r -a fields <<< "${stat##*) }"
	[[ -n ${fields[$2]:-} ]] || return 1
	printf '%s' "${fields[$2]}"
}

# PID $1が起動時刻$2のままの同じプロセスで、ゾンビでないか
#
# @brief 同じPIDが使い回された別のプロセスと区別する
# @param $1 対象のPID
# @param $2 期待する起動時刻 (statの第20フィールド)
# @return 0 = 同じプロセス、1 = 違うか取得できない
_pid_is_same_process() {
	local stat
	local -a fields
	{ read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
	read -r -a fields <<< "${stat##*) }"
	[[ ${fields[0]:-} != Z && ${fields[19]:-} == "$2" ]]
}

# 全PIDにSIGTERMを送り、最大約2秒で消えるのを待ってから
# 残ったものにSIGKILLへ上げる
#
# @brief 対象を起動時刻で固定したまま段階的に終了させる
# @param $1 ログに残すラベル
# @param $2... 対象のPID
# @return 0 = 常に成功 (対象がいなくても成功)
# @note 最初のシグナルの前に各PIDを起動時刻へ結び付け
#       2回目以降のシグナル前にも同じプロセスか再確認する
#       待ち時間の間に終了したプロセスはPIDを解放するため
#       そのPIDを引き継いだ無関係なプロセスにSIGKILLが飛んではならない
#       すでに消えたPIDは一覧から外す
_kill_pids_escalating() {
	local label="$1"
	shift
	local pid start i alive=false waited=0
	local -a pids=() starts=()

	for pid in "$@"; do
		start=$(_proc_stat_field "$pid" 19) || continue
		pids+=("$pid")
		starts+=("$start")
	done
	[[ ${#pids[@]} -gt 0 ]] || return 0

	for i in "${!pids[@]}"; do
		kill "${pids[i]}" 2>/dev/null || true
	done

	while ((waited < 20)); do
		alive=false
		for i in "${!pids[@]}"; do
			if _pid_is_same_process "${pids[i]}" "${starts[i]}"; then
				alive=true
				break
			fi
		done
		[[ $alive == false ]] && break
		sleep 0.1
		waited=$((waited + 1))
	done

	if [[ $alive == true ]]; then
		for i in "${!pids[@]}"; do
			_pid_is_same_process "${pids[i]}" "${starts[i]}" \
				&& kill -KILL "${pids[i]}" 2>/dev/null
		done
		log_message "$label (SIGKILL, PIDs: ${pids[*]})"
	else
		log_message "$label (PIDs: ${pids[*]})"
	fi
	return 0
}

# このプロセスの実行ファイル (Claude DesktopのElectron) が
# 実行中に置き換えられ (unlinkされ) たか
#
# @brief /proc/PID/exeの" (deleted)"印で置き換えを検出する
# @param $1 対象のPID
# @return 0 = 置き換えられた、1 = そのままか判定できない
# @note 動いているプロセスの背後でバイナリが消えると、カーネルが
#       /proc/PID/exeに" (deleted)"を付ける
#       UIを起動したままzypper upでパッケージを更新するとこれになる
# @note readlink -fではなく素のreadlinkを使う
#       -fはパスを正規化するため、インストール先のディレクトリごと
#       消えた場合 (ファイルの置き換えではなくパッケージの移行や
#       レイアウト変更) に失敗し、置き換えられたUIを見逃す
#       生のリンク内容ならどちらでも印が残る
# @note --classの指紋だけでは所有の証拠にならない
#       --class=Claudeを付けて起動した別のElectronアプリも一致し
#       そのバイナリが更新されていれば終了させてしまう
#       そのため実行ファイルがclaude-desktopのツリー
#       (RPMでは/usr/lib/claude-desktop/) にあるか
#       claude-desktopという名前であることも条件にする
_claude_desktop_ui_is_replaced() {
	local exe_path

	exe_path=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
	[[ $exe_path == *' (deleted)' ]] || return 1
	exe_path=${exe_path% (deleted)}
	[[ $exe_path == */claude-desktop/* \
		|| ${exe_path##*/} == claude-desktop ]]
}

# PIDがClaude Desktopのブラウザプロセスで、~/.config/Claudeの
# SingletonLockを持ちうるか
#
# @brief 実行ファイルのパスとUI指紋からロックの持ち主かを判定する
# @param $1 対象のPID
# @return 0 = 持ち主になりうる (読めない場合もこちら)、1 = 違う
# @note --classのUI指紋ではなく実行ファイルのパスで見る
#       ロックは機械上の全Claude Desktopビルドで共有されるため
#       RPM版は/usr/lib/claude-desktop/node_modules/electron/dist/electron
#       AppImage版はそのFUSEマウント内の同じツリー
#       (/tmp/.mount_claude*/usr/lib/node_modules/electron/dist/electron、
#       マウント先の名前にAppImageファイル名の先頭が入る) を実行する
#       他のビルドは.../claude-desktop/claude-desktopを同梱する
#       electronという名前だけでは無関係なElectronアプリまで
#       ロックの持ち主と数えてしまうため、パスにClaudeを含める
# @note /proc/PID/exeが読めない場合 (ゾンビ、setuidバイナリを
#       execしてdump不可になったプロセス) は「生きている」側に倒す
#       古いロックを残す害はなくElectronが次の起動で自分で消すが
#       誤って「古い」と判断するとdoctorが生きているロックに
#       Fix: rmを案内してしまう
# @note 名前を変えたAppImageは/tmp/.mount_<新しい名前>にマウントされ
#       展開したものはsquashfs-root/から動くため
#       どちらのパスにもClaudeが現れない
#       そこでランチャーが渡す--class=[WM_CLASS]のUI指紋も条件に加える
_pid_is_claude_desktop() {
	local exe cmdline
	exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 0
	case "$exe" in
		# ClaudeのツリーかAppImageのマウント先
		*claude-desktop* | */.mount_[Cc]laude*)
			return 0
			;;
	esac
	cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline") || return 0
	_claude_desktop_ui_cmdline_matches "$cmdline"
}

# 実行ファイルがrpmで置き換えられたまま動き続ける
# Claude DesktopのUIを終了させる
#
# @brief 置き換えられたUIを探して段階的に終了させる
# @return 0 = 常に成功
# @note そのままにすると、次のランチャーがElectronの
#       単一インスタンスのロックを古いプロセスに奪われ
#       新しく入れたビルドが起動せず、何も起きないように見える
# @note AppImage版では構造上何もしない
#       バイナリはFUSEマウントの中にあり、.AppImageファイル自体を
#       置き換えてもマウントは有効なままなので
#       /proc/PID/exeに印が付かない
cleanup_replaced_desktop_ui() {
	local pids=() pid
	for pid in $(_claude_desktop_ui_pids); do
		_claude_desktop_ui_is_replaced "$pid" || continue
		pids+=("$pid")
	done

	[[ ${#pids[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed replaced Claude Desktop UI' \
		"${pids[@]}"
}

# PIDが自前のcowork-vm-serviceデーモンか
#
# @brief 引数の並びからデーモンを見分ける
# @param $1 対象のPID
# @return 0 = デーモン、1 = 違う
# @note cowork-vm-service.jsという部分文字列ではなく引数の並びで見る
#       部分文字列はエディタやtail -f、ファイル名を口にしただけの
#       シェルにも一致し、ここで受け付けたものを後片付けがSIGKILLする
# @note cowork.shの自動起動パッチはchild_process.fork()で起動する
#       <electron> [nodeのオプション] <resourcesPath>/app.asar.unpacked/cowork-vm-service.js
#       という形 ([ELECTRON_RUN_AS_NODE]=1) で、手動起動は
#       node <path>になる
#       つまりargv[0]はインタプリタで、スクリプトの前に置けるのは
#       "-"で始まるオプションだけ、スクリプトの引数は
#       /cowork-vm-service.jsで終わる
# @note cmdlineはNULで分割して配列にする
#       tr '\0' ' 'では引数の境目が分からなくなるため
_is_cowork_fallback_daemon() {
	local -a argv
	local i
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1

	case ${argv[0]##*/} in
		# パッチのforkと手動起動が使うインタプリタ
		electron | node | nodejs)
			;;
		*)
			# それ以外は対象外
			return 1
			;;
	esac

	for ((i = 1; i < ${#argv[@]}; i++)); do
		# スクリプト本体に届いたらデーモンと確定する
		[[ ${argv[i]} == */cowork-vm-service.js ]] && return 0
		# スクリプトより前に置けるのは"-"付きのオプションだけ
		[[ ${argv[i]} == -* ]] || return 1
	done
	return 1
}

# このユーザーのcoworkデーモンのPIDを1行ずつ出力する
#
# @brief 候補を絞ってから引数の並びでデーモンだけを残す
# @return 0 = 常に成功、該当がなければ何も出力しない
# @note pgrepは候補を狭めるだけで、判定は
#       _is_cowork_fallback_daemonが行う
#       自前のランチャーのbashとその親を除くのは
#       _claude_desktop_ui_pidsと同じ
_cowork_fallback_daemon_pids() {
	local pid
	for pid in \
		$(pgrep -u "$(id -u)" -f 'cowork-vm-service\.js' 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		_is_cowork_fallback_daemon "$pid" || continue
		printf '%s\n' "$pid"
	done
}

# 孤児になったcowork-vm-serviceデーモンを終了させる
#
# @brief UIが動いていなければデーモンを掃除する
# @return 0 = 常に成功
# @note クラッシュや異常終了の後、coworkデーモンが
#       ElectronのUI本体より長く残ることがある
#       残ったデーモンは~/.config/Claude/Local Storage/の
#       LevelDBのロックを握り、さらに
#       $XDG_RUNTIME_DIR/cowork-vm-service.sockのUnixソケットを
#       束縛したままになる
#       そのため次の起動はLevelDBのせいで黙って終了するか
#       古いデーモンに繋がって真っ白なウィンドウのまま止まる
# @note cleanup_stale_lockとcleanup_stale_cowork_socketより前に
#       実行する、デーモンが残したファイルを掃除するため
cleanup_orphaned_cowork_daemon() {
	local -a pids
	mapfile -t pids < <(_cowork_fallback_daemon_pids)
	[[ ${#pids[@]} -gt 0 ]] || return 0

	# UIが動いていればデーモンは想定内なので触らない
	# pgrep -f 'claude-desktop'もapp.asarの指紋も使えない理由は
	# _claude_desktop_ui_is_aliveに書いた
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	# UIがないのでデーモンは孤児、終了させる
	# _kill_pids_escalatingはSIGTERMの約2秒後にも残っていれば
	# SIGKILLするため、次に動くcleanup_stale_cowork_socketは
	# デーモンがいない状態を見られる
	_kill_pids_escalating 'Killed orphaned cowork-vm-service daemon' \
		"${pids[@]}"
}

# この関数にcowork-vm-service.jsの判定は置かない
# ここに部分文字列を置くと、スクリプトを開いたエディタやtail -fにも
# 一致するため
# デーモンはcleanup_stale_desktop_helpersの中で
# _is_cowork_fallback_daemonが引数の並びで見分ける
#
# @brief Claude Desktopのヘルパーのコマンドラインかを判定する
# @param $1 空白で連結したコマンドライン
# @global APPDIR ... (参照のみ、AppImage版でのみ設定される)
# @return 0 = ヘルパー、1 = それ以外
# @note /proc/PID/cmdlineはNUL区切りでtrで連結するため
#       argv[0]は最初の空白までになる
#       実行しているバイナリで見分ける判定はすべてargv[0]を見て
#       文字列全体は見ない
#       バイナリ名を引数として渡しただけの傍観者
#       (gdb .../chrome_crashpad_handler core、coredumpctl gdb、
#       エディタ、less) を終了対象の一覧に入れないため
# @note argv[0]に空白がある場合は一致しない方向に倒れる
#       誤って一致することはない
#       RPM版のインストール先に空白はなく
#       空白を含むパスにマウントしたAppImageは掃除されないだけ
_desktop_helper_cmdline_matches() {
	local cmdline="$1"
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"

	local argv0="${cmdline%% *}"
	local appimage_tree=''
	[[ -n ${APPDIR:-} ]] && appimage_tree="$APPDIR/usr/lib/"

	case "$argv0" in
		# coworkのLinuxヘルパー
		*cowork-linux-helper*)
			return 0
			;;
		# 自前ツリーのCrashpad
		*/usr/lib/claude-desktop/*chrome_crashpad_handler*)
			# Crashpadは監視対象のブラウザより長く残るように
			# できているため、下の--type=の判定では拾えない
			# 生き残りで、--type=を付けない
			# パスの前方一致で自前のツリーに限定する
			# /usr/lib/chromium/chrome_crashpad_handlerという
			# 傍観者まで一致させないため
			return 0
			;;
	esac

	# 同じCrashpadの生き残りが、自前のAppImageマウント内にいる場合
	# ランタイムはAppRunが終わるとすぐAppDirをアンマウントし
	# crashpadのテキストページはそのマウントからmmapされているため
	# 先に回収しないと終了のたびにSIGBUSでコアダンプを残す
	# 今回の起動の$APPDIRだけを対象にし
	# /tmp/.mount_*のツリーすべてを対象にはしない
	if [[ -n $appimage_tree && $argv0 == "$appimage_tree"* \
		&& $argv0 == *chrome_crashpad_handler* ]]; then
		return 0
	fi

	# Chromium自身のヘルパー、自前ツリーのargv[0]と--type=の
	# 両方が必要
	# ツリーの一致だけではChrome (Claude Desktopではない) が
	# 起動して寿命を管理するヘルパーにも当たってしまう
	if [[ $argv0 == */usr/lib/claude-desktop/* \
		|| ( -n $appimage_tree && $argv0 == "$appimage_tree"* ) ]]; then
		[[ $cmdline == *--type=* ]] && return 0
	fi

	# 自前のプロファイルを渡されたClaude DesktopのChromiumヘルパー
	# argv[0]がelectron (自前のnpm版Electronのツリー) か
	# claude-desktopで、--type=と自前の--user-data-dirを持つ
	# chromium --user-data-dir=~/.config/Claudeのように
	# 同じプロファイルを渡されただけの傍観者は一致しない
	case ${argv0##*/} in
		electron | claude-desktop)
			if [[ $cmdline == *--type=* \
				&& $cmdline == *"--user-data-dir=$config_dir "* ]]; then
				return 0
			fi
			;;
	esac

	# 拡張機能のサーバーはここではなく
	# cleanup_stale_desktop_helpersの中
	# (_is_claude_extension_server) で引数の並びから見分ける
	# $config_dir/Claude Extensions/の部分文字列は
	# 拡張機能のファイルを開いたpagerやエディタ、rgにも一致するため
	return 1
}

# PIDが導入済みClaude Desktop拡張機能のMCPサーバーか
#
# @brief 引数の並びから拡張機能のサーバーを見分ける
# @param $1 対象のPID
# @return 0 = サーバー、1 = 違う
# @note Claude Extensions/という部分文字列ではなく引数の並びで見る
#       argv[0]のベース名がインタプリタで、argv[1]または
#       --directoryの値が拡張機能のディレクトリの下にある形を取る
#       アプリがシステムのランタイムで起動するときの形で
#       node <ext>/server/index.js や uv run --directory <ext> ... が
#       これに当たる
# @note 同梱のNodeを使う場合はutilityProcess (--type=utility、
#       _desktop_helper_cmdline_matchesのツリー側の判定で拾える) か
#       npmのelectronバイナリを[ELECTRON_RUN_AS_NODE]=1で動かす形になり
#       後者はここでインタプリタとして数える
#       environが読めない場合は一致しない
# @note 既知の取りこぼし、拡張機能のディレクトリをカレントにして
#       相対引数だけで起動したサーバーはargvに拡張機能のパスが
#       現れないため一致しない
# @note cmdlineはNULで分割して配列にする
#       ディレクトリ名に空白が入るため
_is_claude_extension_server() {
	local ext_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Claude Extensions/"
	local -a argv
	local i
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1

	case ${argv[0]##*/} in
		# システムのランタイムで動くサーバー
		node | python* | uv | uvx | bun | deno)
			;;
		# 同梱のElectronをNodeとして動かす場合
		electron | claude-desktop)
			tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" \
				| grep -qx 'ELECTRON_RUN_AS_NODE=1' || return 1
			;;
		*)
			# それ以外のバイナリは対象外
			return 1
			;;
	esac

	# スクリプトの引数が拡張機能のディレクトリ配下なら確定
	[[ ${argv[1]:-} == "$ext_dir"* ]] && return 0
	# uv run --directory <ext> のようにディレクトリを先に渡す形も見る
	for ((i = 1; i < ${#argv[@]}; i++)); do
		case ${argv[i]} in
			# --directory=<ext> の形
			--directory=*)
				[[ ${argv[i]#--directory=} == "$ext_dir"* ]] && return 0
				;;
			# --directory <ext> の形
			--directory)
				[[ ${argv[i + 1]:-} == "$ext_dir"* ]] && return 0
				;;
		esac
	done
	return 1
}

# 最近の起動のプロセスグループ、1行ずつ、新しいものが最後
#
# @brief 起動の記録ファイルのパスを返す
# @return 0 = 常に成功
# @note 拡張機能サーバーの引数の形は「何であるか」を言うだけで
#       「誰が起動したか」は言わない
#       端末で uv run --directory <ext dir> を動かしている開発者も
#       同じ形になる
# @note アプリはサーバーを切り離さずに起動するため
#       サーバーはElectron本体のプロセスグループに残り
#       非対話で起動したランチャーは自分のbashと同じグループを共有する
#       起動のたびにそのグループを記録しておけば、後片付けは
#       「自前の起動のどれかが始めたか」を問える
#       端末のジョブは独自のグループを持つため対象外になり
#       アプリが切り離して起動したサーバーも対象外になる (安全側)
_launch_pgids_file() {
	printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse/launch-pgids"
}

# 今回の起動のプロセスグループを記録に加える
#
# @brief 記録を最大9件に保ったまま自分のプロセスグループを追記する
# @return 0 = 常に成功 (書けなくても起動は止めない)
# @note 書き込みは一時ファイル経由で置き換える
#       途中で失敗しても記録が壊れないようにするため
_record_launch_pgid() {
	local file pgid tmp
	file=$(_launch_pgids_file)
	pgid=$(_proc_stat_field "$$" 2) || return 0
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	tmp="$file.tmp.$$"
	{
		grep -vxF -- "$pgid" "$file" 2>/dev/null | tail -n 9
		printf '%s\n' "$pgid"
	} > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
	return 0
}

# PIDが最近の起動のプロセスグループに属するか
#
# @brief /procからプロセスグループを取り、記録と照合する
# @param $1 対象のPID
# @return 0 = 記録にある、1 = ないか取得できない
_pid_in_launch_group() {
	local pgid
	pgid=$(_proc_stat_field "$1" 2) || return 1
	grep -qxF -- "$pgid" "$(_launch_pgids_file)" 2>/dev/null
}

# ヘルパーの候補になりうるPIDを列挙する
#
# @brief pgrepの1回の走査で候補を集める
# @return 0 = 常に成功、該当がなければ何も出力しない
# @note ここでは候補を広く取り、実際の判定は
#       cleanup_stale_desktop_helpersの各判定に任せる
_desktop_helper_candidate_pids() {
	pgrep -u "$(id -u)" -f 'cowork-vm-service\.js|cowork-linux-helper|--user-data-dir=.*[/]Claude|Claude Extensions|/usr/lib/claude-desktop/|/usr/lib/node_modules/electron/dist/' 2>/dev/null
}

# 前回の起動が残したヘルパーを終了させる
#
# @brief UIが動いていなければ候補を判定して終了させる
# @return 0 = 常に成功
# @note ヘルパーをインスタンスごとに切り分けていないため
#       UI (どのインスタンスでも) が動いていれば後片付けはすべて止める
#       安全側だが取りこぼしは残る
cleanup_stale_desktop_helpers() {
	# UIが動いていれば後片付けは止める、所有を切り分けていないため
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	local pids pid cmdline
	pids=$(_desktop_helper_candidate_pids) || return 0

	local matched=()
	for pid in $pids; do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		[[ ${_electron_child_pid:-} == "$pid" ]] && continue
		if _is_cowork_fallback_daemon "$pid"; then
			matched+=("$pid")
			continue
		fi
		if _is_claude_extension_server "$pid"; then
			_pid_in_launch_group "$pid" && matched+=("$pid")
			continue
		fi
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_desktop_helper_cmdline_matches "$cmdline" || continue
		matched+=("$pid")
	done

	[[ ${#matched[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed stale Claude Desktop helpers' \
		"${matched[@]}"
}

# 持ち主がいないSingletonLockを片付ける
#
# @brief ロックが指すPIDが動いていなければロックを消す
# @return 0 = 常に成功
# @note ElectronはrequestSingleInstanceLock()が失敗すると
#       何も告げずに終了する
#       クラッシュや更新の失敗で残ったロックは、利用者に何も
#       表示しないまますべての起動を止めてしまう
# @note ロックは"hostname-PID"を指すシンボリックリンク
cleanup_stale_lock() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local lock_file="$config_dir/SingletonLock"

	[[ -L $lock_file ]] || return 0

	local lock_target
	lock_target="$(readlink "$lock_file" 2>/dev/null)" || return 0

	local lock_pid="${lock_target##*-}"

	# 数値のPIDを取り出せたかを確かめる
	[[ $lock_pid =~ ^[0-9]+$ ]] || return 0

	# 生きているPIDはこちらが判断しない
	# 持ち主はこのランチャーが判別できないClaude Desktopかもしれず
	# (名前を変えたAppImageや展開したもの、他のビルド)
	# そのロックを消すと同じプロファイルで2つ目のインスタンスが起動する
	# PIDが使い回されていても害はない
	# ChromiumのProcessSingletonが持ち主の実行ファイルを自分と比べ
	# 別物なら起動時に自分でunlinkするため
	kill -0 "$lock_pid" 2>/dev/null && return 0

	rm -f "$lock_file"
	log_message "Removed stale SingletonLock (PID $lock_pid no longer running)"
}

# 待ち受けていないcowork-vm-serviceのソケットを片付ける
#
# @brief デーモンがいなければソケットファイルを消す
# @return 0 = 常に成功
# @note サービスデーモンは
#       $XDG_RUNTIME_DIR/cowork-vm-service.sockにUnixソケットを作る
#       クラッシュや異常終了の後はソケットファイルだけが残り
#       待ち受けがないため、アプリの接続はENOENTではなく
#       ECONNREFUSEDで失敗する
# @note cleanup_orphaned_cowork_daemonより後に実行する
#       孤児のデーモンはそこで終了させる
#       その順序なら、デーモンがいればソケットは使用中
#       いなければソケットは古い、と決められる
# @note socatや経過時間ではなくこの関係を使う
#       以前の24時間の判定では最近のクラッシュで掃除が効かなかった
#       デーモンは引数の並びで見分けるため
#       スクリプトを開いたエディタやtail -fではソケットは消えない
cleanup_stale_cowork_socket() {
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

	[[ -S $sock ]] || return 0

	# デーモンが動いていればソケットも使われている
	# cleanup_orphaned_cowork_daemonはすでに走っており
	# 孤児はSIGKILLまで含めて片付いているため
	# ここで残っているのは孤児ではないデーモン
	if [[ -n $(_cowork_fallback_daemon_pids) ]]; then
		return 0
	fi

	# デーモンがいなければクラッシュの残骸、消す
	rm -f "$sock"
	log_message "Removed stale cowork-vm-service socket (no daemon running)"
}

# 起動の前に、ユーザー設定とCoworkのストアの索引ファイルを
# キャッシュディレクトリへ退避する
#
# @brief 対象ファイルをファイルごとに最大5世代、キャッシュに残す
# @return 0 = 常に成功 (起動を止めない)
# @note 実際に変わったときだけ世代を進める (cmp -s)
#       毎回作り直すと世代が入れ替わり
#       消える前の控えが失われてしまう
# @note 失敗しても起動は止めない、すべてのエラー経路が0で戻る
backup_user_config() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local backup_dir
	backup_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse"
	backup_dir="$backup_dir/config-backups"
	local keep=5

	mkdir -p "$backup_dir" 2>/dev/null || return 0

	local -a sources=("$config_dir/claude_desktop_config.json")

	local lam="$config_dir/local-agent-mode-sessions"
	if [[ -d $lam ]]; then
		local f
		for f in "$lam"/*/*/spaces.json \
			"$lam"/*/*/remote-session-spaces.json \
			"$lam"/*/*/scheduled-tasks.json; do
			[[ -f $f ]] && sources+=("$f")
		done
	fi

	local src flat newest i
	for src in "${sources[@]}"; do
		[[ -f $src ]] || continue

		flat="${src#"$config_dir"/}"
		flat="${flat//\//__}"
		newest="$backup_dir/$flat.1"

		[[ -f $newest ]] && cmp -s "$src" "$newest" && continue

		for (( i = keep - 1; i >= 1; i-- )); do
			[[ -f "$backup_dir/$flat.$i" ]] && \
				mv -f "$backup_dir/$flat.$i" \
					"$backup_dir/$flat.$((i + 1))" 2>/dev/null
		done
		cp -f "$src" "$newest" 2>/dev/null && \
			log_message "Backed up $flat (keep $keep)"
	done
}

# AUTO-1、アプリは「ログイン時に起動」が有効なとき
# Exec=<ELFのパス>を持つXDGのautostartエントリを自分で書く
# ログイン時の起動はランチャーの方針 (Waylandの選択、GPUの復帰、
# --class) をすべて迂回してしまうため、起動のたびにExecを
# ランチャーへ書き換える
#
# @brief 消えた起動先を指しているautostartエントリを直す
# @param $1 エントリのExecに書くランチャーの絶対パス
# @return 0 = 常に成功 (直せなくても起動は止めない)
# @note 設定画面のトグルと衝突しない
#       上流の有効判定はファイルの有無とHidden=、
#       X-GNOME-Autostart-enabled=しか見ずExecの中身は見ない
#       トグルを入れるたびにアプリがエントリを書き直すため
#       この修正も起動のたびに必要になる
# @note 起動先が消えている場合だけ書き換える
#       (claude-desktop-debian #949)
#       Execの先がまだ動いている場合は別の生きているインストール
#       (AppImage版から見たRPM版の/usr/bin/claude-desktopや
#       同じエントリ名を共有する他社のパッケージ) のものなので
#       奪ってはならない
#       対象は消えたもの、マウントが外れたAppImageの
#       /tmp/.mount_claude*のパスや削除されたパッケージ
# @note 置き換え先が存在し実行できるかだけを見る
_autostart_target_exists() {
	[[ -f $1 && -x $1 ]]
}

# autostartエントリのExecをランチャーへ向け直す
#
# @brief 消えた起動先を指しているエントリだけを書き換える
# @param $1 ランチャーの絶対パス
# @return 0 = 常に成功
# @note 書き換えは一時ファイル経由で置き換える
#       途中で失敗してもエントリを壊さないため
heal_autostart_entry() {
	local launcher="$1"
	local entry_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
	local entry="$entry_dir/claude-desktop.desktop"
	local exec_line current args rest escaped new_line tmp line
	local replaced=false

	[[ -n $launcher && -f $entry ]] || return 0

	exec_line=$(LC_ALL=C grep -m1 '^Exec=' "$entry") || return 0

	# 引用符付きのExecは中のパスと後ろに続く引数に分ける
	if [[ $exec_line =~ ^Exec=\"([^\"]*)\"(.*)$ ]]; then
		current="${BASH_REMATCH[1]}"
		args="${BASH_REMATCH[2]}"
	else
		# 引用符なしは最初の空白までをパスとみなす
		rest="${exec_line#Exec=}"
		current="${rest%%[[:space:]]*}"
		args="${rest#"$current"}"
	fi

	[[ $current == "$launcher" ]] && return 0
	# 直すのはclaude-desktopを指しているエントリだけ
	# 他アプリのエントリを書き換えないため
	case "$current" in
		# 対象の名前
		*/claude-desktop) ;;
		# それ以外は触らない
		*) return 0 ;;
	esac
	# 起動先がまだ動くなら別のインストールのもの、触らない
	if _autostart_target_exists "$current"; then
		if [[ -n ${log_file:-} ]]; then
			log_message \
				"Autostart Exec $current still runs; leaving it (AUTO-1)"
		fi
		return 0
	fi

	escaped=$(_desktop_exec_quote "$launcher") || return 0
	new_line="Exec=$escaped$args"

	tmp="$entry.tmp.$$"
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $replaced == false && $line == Exec=* ]]; then
			printf '%s\n' "$new_line"
			replaced=true
		else
			printf '%s\n' "$line"
		fi
	done < "$entry" > "$tmp" || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$entry" || { rm -f "$tmp"; return 0; }

	if [[ -n ${log_file:-} ]]; then
		log_message \
			"Healed autostart Exec: $current -> $launcher (AUTO-1)"
	fi
	return 0
}

# $1をデスクトップエントリのExecのトークンとして
# 二重引用符で囲んだ形で出力する
#
# @brief Execのトークンとして安全な文字列に変換する
# @param $1 変換するパス
# @return 0 = 成功、1 = 改行を含むため表せない
# @note 仕様によりエスケープが2段になる
#       引用符の中では\、"、`、$の前にバックスラッシュを置き
#       値をデスクトップエントリの文字列として書くときに
#       バックスラッシュ自体を\\にする
#       (リテラルの"はファイル上で\\"になる)
# @note %はフィールドコードになるため%%にする
#       改行とCRはExecのトークンで表せないためそのパスは拒否する
_desktop_exec_quote() {
	local escaped="$1"
	[[ $escaped == *[$'\n\r']* ]] && return 1
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//\"/\\\"}
	escaped=${escaped//\`/\\\`}
	escaped=${escaped//\$/\\\$}
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//%/%%}
	printf '"%s"' "$escaped"
}

# このランチャーが生成したエイリアスを見分ける印
# 利用者が用意した同名のエントリを書き換えないために使う
readonly PORTAL_ENTRY_MARKER='X-Claude-Desktop-Suse-Portal-Alias=true'

# $1がアプリ自身が生成したエントリ (X-Claude-Generated=true) で
# TryExecが解決できなくなっている場合に0を返す
#
# @brief 消えた起動先を指すアプリ生成のエントリかを判定する
# @param $1 エントリのパス
# @return 0 = 古い、1 = そうではない
# @note 回転したAppImageのマウント先など、起動先が消えたものを拾う
#       アプリが自分で生成したものだけを対象にし
#       他者が置いたエントリには触らない
_portal_entry_is_stale_generated() {
	local entry="$1" try_exec

	LC_ALL=C grep -qxF 'X-Claude-Generated=true' "$entry" 2>/dev/null ||
		return 1
	try_exec=$(LC_ALL=C grep -m1 '^TryExec=' "$entry" 2>/dev/null) ||
		return 1
	try_exec=${try_exec#TryExec=}
	[[ -n $try_exec ]] || return 1
	if [[ $try_exec == /* ]]; then
		# 絶対パスは実行できるかだけを見る
		[[ ! -x $try_exec ]]
	else
		# 名前だけならPATHから解決できるかを見る
		! command -v "$try_exec" &> /dev/null
	fi
}

# Electron 44以降 (Chromium 152) は、GlobalShortcutsやSecretの
# ポータルを使う前に、asarのdesktopNameから.desktopを除いたidを
# org.freedesktop.host.portal.Registryへ登録する
# xdg-desktop-portal 1.20以降は<id>.desktopが入っていないidを拒否する
# RPM版はそのエントリをシステム全体に同梱するが
# 統合していないAppImageにはないため、ネイティブWaylandのときは
# $XDG_DATA_HOMEの下にHiddenのエイリアスを書く
#
# @brief ポータルが要求するidのエントリを用意する
# @param $1 Execに書くランチャーのパス
# @param $2 アプリのid (desktopNameから.desktopを除いたもの)
# @param $3 Icon=の名前
# @return 0 = 常に成功
# @note エイリアスはx-scheme-handler/claudeも持つ
#       setAsDefaultProtocolClientがclaude://を同じidに向けるため
#       自前のエイリアスならどのバックエンドでも最新に保つ
# @note システム側にidのエントリがあればエイリアスは不要
#       他者が置いたファイルには触らない
ensure_portal_app_id_entry() {
	local launcher="$1" app_id="$2" icon="${3:-}"
	local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
	local entry dir tmp exec_token ours=false stale=false
	local -a data_dirs=()

	[[ -n $app_id ]] || return 0
	entry="$data_home/applications/$app_id.desktop"

	if [[ -f $entry ]]; then
		# 自前のエイリアスか、アプリが生成した古いエントリかを見る
		if LC_ALL=C grep -qxF "$PORTAL_ENTRY_MARKER" "$entry" 2>/dev/null; then
			ours=true
		elif _portal_entry_is_stale_generated "$entry"; then
			stale=true
		fi
	fi

	IFS=: read -r -a data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
	for dir in "${data_dirs[@]}"; do
		# システム側にidのエントリがあればエイリアスは不要なので消す
		# 消すのは自前のものだけで、他者のファイルには触らない
		[[ -n $dir && -f $dir/applications/$app_id.desktop ]] || continue
		if [[ $ours == true ]]; then
			rm -f "$entry" &&
				log_message "Removed portal app-id entry $entry (system entry $dir/applications/$app_id.desktop exists)"
		fi
		return 0
	done

	if [[ $ours == false ]]; then
		# 自前のエイリアスがない場合はネイティブWaylandのときだけ書く
		# XWaylandで動かしている間はポータルにidを問い合わせない
		[[ ${is_wayland:-false} == true &&
			${use_x11_on_wayland:-true} == false ]] || return 0
	fi
	[[ -n $launcher ]] || return 0

	if [[ -f $entry && $ours == false && $stale == false ]]; then
		# 自前でもアプリ生成でもないエントリはそのまま残す
		log_message "Left portal app-id entry $entry in place (not written by the launcher)"
		return 0
	fi

	exec_token=$(_desktop_exec_quote "$launcher") || return 0
	mkdir -p "$data_home/applications" || return 0
	tmp="$entry.tmp.$$"
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Claude'
		printf 'Exec=%s %%u\n' "$exec_token"
		[[ -n $icon ]] && printf 'Icon=%s\n' "$icon"
		printf '%s\n' 'NoDisplay=true' 'MimeType=x-scheme-handler/claude;' \
			"$PORTAL_ENTRY_MARKER"
	} > "$tmp" || { rm -f "$tmp"; return 0; }

	if [[ $ours == true ]] && cmp -s "$tmp" "$entry"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$entry" || { rm -f "$tmp"; return 0; }
	[[ $stale == true ]] &&
		log_message "Replacing stale app-generated entry $entry (TryExec not found)"
	log_message "Wrote portal app-id entry $entry"
	return 0
}

# Electronが終了した後の後片付け
#
# @brief 孤児のデーモン、残ったヘルパー、古いロック、古いソケットを
#        この順に片付ける
# @return 0 = 常に成功
# @note デーモンを先に終了させてからソケットを判定できるよう
#       cleanup_orphaned_cowork_daemonを先に呼ぶ
cleanup_after_electron_exit() {
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
}

# ランチャーが受け取ったシグナルをElectronの子へ転送する
#
# @brief TERM、INT、HUPを子プロセスへそのまま渡す
# @param $1 シグナル名
# @global _electron_child_pid ... (参照のみ)
# @return 0 = 常に成功
# @note 子がいない場合 (起動前や終了後) は何もしない
_electron_launcher_forward_signal() {
	local signal="$1"

	if [[ -n ${_electron_child_pid:-} ]]; then
		kill "-$signal" "$_electron_child_pid" 2>/dev/null || true
	fi
}

# 1回のセッションがlauncher.logへ書ける量を抑える
#
# @brief 重複行の圧縮と出力上限でElectronのログを濾す
# @global ELECTRON_LOG_CAP_BYTES ... (参照のみ、既定は20MiB)
# @return 0 = 常に成功
# @note Electronの標準出力と標準エラーはセッションの間ずっと
#       ログに落ちるため、ループに陥ったChromiumのメッセージが
#       setup_loggingの起動時のローテーションまでに
#       ギガバイト級を書くことがある
#       対策は2つある
# @note 1、同じ行が続いたら1行と
#       "[launcher] last line repeated N more times"にまとめる
#       1行のループがどれだけ続いても2行で済む
# @note 2、ELECTRON_LOG_CAP_BYTES (既定20MiB) を超えたら
#       書き込みを止めるが読み取りは続ける
#       上限に達したことを示す行を1行書き、以降は読んで捨てる
#       パイプを閉じないためElectronにSIGPIPEが届かない
# @note 行ごとにfflush()するのでtail -fで追える
#       mawkとgawkのどちらも対応している
#       標準入力を読み標準出力へ書き、呼び出し側が標準出力を
#       ログに向ける
_electron_output_filter() {
	local max="${ELECTRON_LOG_CAP_BYTES:-$((20 * 1024 * 1024))}"

	awk -v max="$max" '
		function emit(line) {
			if (capped) return
			if (written >= max) {
				print "[launcher] output cap (" max " bytes) reached;" \
					" further output dropped this session"
				fflush()
				capped = 1
				return
			}
			print line
			fflush()
			written += length(line) + 1
		}
		function end_run() {
			if (repeat > 1) {
				emit("[launcher] last line repeated " (repeat - 1) \
					" more times")
			}
			repeat = 0
		}
		{
			if (capped) next
			if (have_prev && $0 == prev) {
				repeat++
				next
			}
			if (have_prev) end_run()
			prev = $0
			have_prev = 1
			repeat = 1
			emit($0)
		}
		END { end_run() }
	'
}

# Electronをバックグラウンドで起動し、TERM、INT、HUPを転送して
# 終了を待ち、残ったものを片付ける (cleanup_after_electron_exit)
#
# @brief Electronを起動し、その終了コードを返す
# @param $@ 起動するコマンドと引数
# @global _electron_child_pid ... (本関数で設定する)
# @return Electronの終了コード
# @note 起動前の後始末 (backup_user_config、heal_autostart_entry、
#       cleanup_*の呼び出し) は呼ぶ側のランチャー本体が行う
# @note ログは名前付きパイプ経由で濾す
#       プロセス置換 (> >(...)) ではなくパイプを使うのは
#       フィルタのPIDが分かり、終了の行を書く前に
#       ログを読み切れるようにするため
#       パイプを作れない場合は起動を止めず素のリダイレクトに落とす
# @note フィルタの待ちは約2秒で打ち切る
#       パイプの書き込み側を引き継いだヘルパーが本体より長く生きると
#       パイプが閉じないため、待ち切らずに止めて回収する
#       そうしないとLauncher Endの行の後にヘルパーの出力が
#       際限なく追記されてしまう
#       フィルタはawkを動かすサブシェルなので、先にawkへ
#       シグナルを送り親より長く残らないようにする
run_electron_and_cleanup() {
	local status fifo_dir fifo filter_pid=''

	_record_launch_pgid

	# プロセス置換ではなく名前付きパイプを使う
	# フィルタのPIDが分かり、終了の行を書く前にログを読み切れる
	# パイプを作れない場合は起動を止めず素のリダイレクトに落とす
	if fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-launcher.XXXXXX" \
		2>/dev/null) && mkfifo "$fifo_dir/electron.out" 2>/dev/null; then
		fifo="$fifo_dir/electron.out"
		_electron_output_filter < "$fifo" >> "$log_file" &
		filter_pid=$!
		"$@" > "$fifo" 2>&1 &
		_electron_child_pid=$!
	else
		[[ -n ${fifo_dir:-} ]] && rm -rf "$fifo_dir"
		"$@" >> "$log_file" 2>&1 &
		_electron_child_pid=$!
	fi

	trap '_electron_launcher_forward_signal TERM' TERM
	trap '_electron_launcher_forward_signal INT' INT
	trap '_electron_launcher_forward_signal HUP' HUP

	wait "$_electron_child_pid"
	status=$?
	while kill -0 "$_electron_child_pid" 2>/dev/null; do
		wait "$_electron_child_pid"  # 回収のみ、終了コードは保持する
	done

	trap - TERM INT HUP

	# フィルタを読み切ってから終了の行を書く
	# 待ちは約2秒で打ち切る
	# パイプの書き込み側を引き継いだヘルパーが本体より長く生きると
	# パイプが閉じないため、待ち切らずにフィルタを止めて回収する
	# そうしないとLauncher Endの行の後にヘルパーの出力が
	# 際限なく追記されてしまう
	# フィルタはawkを動かすサブシェルなので、先にawkへ
	# シグナルを送り親より長く残らないようにする
	if [[ -n $filter_pid ]]; then
		local i
		for (( i = 0; i < 20; i++ )); do
			kill -0 "$filter_pid" 2>/dev/null || break
			sleep 0.1
		done
		if kill -0 "$filter_pid" 2>/dev/null; then
			pkill -TERM -P "$filter_pid" 2>/dev/null
			kill "$filter_pid" 2>/dev/null
		fi
		wait "$filter_pid" 2>/dev/null
		rm -rf "$fifo_dir"
	fi

	log_message "Electron exited with code: $status"
	cleanup_after_electron_exit
	_electron_child_pid=''
	log_message '--- Claude Desktop Launcher End ---'

	return "$status"
}

# 永続的な環境変数を利用者ごとの設定ファイルから読み込む
#
# @brief KEY=value 形式の設定ファイルを許可リストで検証してexportする
# @return 0 = 常に成功
# @note GUIから起動した場合はデスクトップエントリで環境変数を
#       利用者ごとに設定できないため、対応する変数だけを
#       書けるファイルを用意する
# @note 読み込み (source) ではなく解析するのは意図的
#       下の許可リストの変数だけをexportでき
#       値がシェルの展開を通らないため
load_launcher_config() {
	local cfg
	cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-desktop-suse/environment"
	[[ -r $cfg ]] || return 0

	# 設定ファイルから設定できる変数の許可リスト
	local allowlist=' CLAUDE_USE_WAYLAND CLAUDE_PASSWORD_STORE'
	allowlist+=' CLAUDE_GTK_IM_MODULE CLAUDE_DISABLE_GPU'
	allowlist+=' CLAUDE_TITLEBAR_STYLE CLAUDE_MENU_BAR'
	allowlist+=' CLAUDE_KEEP_AWAKE CLAUDE_FORCE_SANDBOX'
	allowlist+=' CLAUDE_TRAY_USE_DARK_ICON'
	allowlist+=' COWORK_VM_BACKEND '
	local line key val
	while IFS= read -r line || [[ -n $line ]]; do
		# 空行とコメント行 (字下げしたコメントも) は無視する
		[[ -z ${line//[[:space:]]/} || \
			${line#"${line%%[![:space:]]*}"} == '#'* ]] && continue
		[[ $line == *=* ]] || continue

		key="${line%%=*}"
		key="${key//[[:space:]]/}"
		val="${line#*=}"
		val="${val#"${val%%[![:space:]]*}"}"
		val="${val%"${val##*[![:space:]]}"}"
		[[ $allowlist == *" $key "* ]] || {
			log_message "Config: ignoring unrecognized key '$key' in $cfg"
			continue
		}

		# 明示的にexportされた空の値はファイルより優先する
		[[ -v $key ]] && continue

		if [[ ($val == \"*\" && $val == *\") || \
			($val == \'*\' && $val == *\') ]]; then
			val="${val:1:${#val}-2}"
		fi
		export "$key=$val"
		log_message "Config: $key=$val (from $cfg)"
	done < "$cfg"
}

# 共通の環境変数を設定する
#
# @brief Electronとアプリの共通設定をexportする
# @return 0 = 常に成功
# @note [ELECTRON_FORCE_IS_PACKAGED]でapp.isPackagedがtrueになり
#       アプリはprocess.resourcesPathからリソースを解決する
#       この構成ではElectronのバイナリとappのリソースを
#       同じdist/resourcesの下に並べて置くため
#       resourcesPathはどの形態でも正しい場所を指す
setup_electron_env() {
	load_launcher_config
	export ELECTRON_FORCE_IS_PACKAGED=true
	# nativeとhybridはframe:trueで動くため
	# Electron側でもシステムのタイトルバーを強制する
	# hiddenはframe:falseとWCO設定を使うので設定しない
	if [[ $(_resolve_titlebar_style) != 'hidden' ]]; then
		export ELECTRON_USE_SYSTEM_TITLE_BAR=1
	fi
	# [CLAUDE_GTK_IM_MODULE]はLinuxのIBus連携が壊れた場合の
	# 選択式の上書き (#549)
	# [GTK_IM_MODULE]へ流すため、起動のたびに包まずに
	# ximなどを固定できる
	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		local prev="${GTK_IM_MODULE:-<unset>}"
		export GTK_IM_MODULE="$CLAUDE_GTK_IM_MODULE"
		log_message \
			"GTK_IM_MODULE override: $prev -> $GTK_IM_MODULE (via CLAUDE_GTK_IM_MODULE)"
	fi
	setup_tray_icon_env
}

# 上流の判定が拾わないデスクトップ向けにLinuxのtrayアイコンを選ぶ
# (claude-desktop-debian #604 から移植)
#
# @brief [CLAUDE_TRAY_USE_DARK_ICON]を決めてexportする
# @global CLAUDE_TRAY_USE_DARK_ICON ... (本関数で設定する)
# @return 0 = 常に成功
# @note アプリはkde、gnome、otherしか区別しないため
#       明るいGTKテーマと暗いパネルを組んだCinnamonでは
#       黒のTrayIconLinux.pngが選ばれてしまう
# @note scripts/patches/tray.shのtrayパッチが
#       [CLAUDE_TRAY_USE_DARK_ICON]を読む
#       1ならTrayIconLinux-Dark.png、0ならTrayIconLinux.pngを強制し
#       それ以外は上流の選択に任せる
# @note 明示された値が常に優先で、そうでなければ名前にdarkを
#       含むCinnamonテーマのときだけ有効にする
setup_tray_icon_env() {
	if [[ -n ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]; then
		export CLAUDE_TRAY_USE_DARK_ICON
		log_message \
			"Tray icon: CLAUDE_TRAY_USE_DARK_ICON=$CLAUDE_TRAY_USE_DARK_ICON (preset)"
		if [[ $CLAUDE_TRAY_USE_DARK_ICON != [01] ]]; then
			log_message \
				'Tray icon: preset is not 0/1 — the app ignores it, and Cinnamon auto-detect stays off'
		fi
		return 0
	fi

	local desktop="${XDG_CURRENT_DESKTOP:-}"
	[[ ${desktop,,} == *cinnamon* ]] || return 0
	command -v gsettings &>/dev/null || return 0

	local theme
	theme=$(gsettings get org.cinnamon.theme name 2>/dev/null) || return 0
	theme=${theme//\'/}
	[[ ${theme,,} == *dark* ]] || return 0

	export CLAUDE_TRAY_USE_DARK_ICON=1
	log_message \
		"Tray icon: cinnamon theme '$theme' has a dark panel; using TrayIconLinux-Dark.png (CLAUDE_TRAY_USE_DARK_ICON=1)"
}

#===============================================================================
# Doctor 診断
#
# run_doctorとその補助関数は同じディレクトリのdoctor.shにある
# ここで読み込むことで[run_doctor]を使う側は分割を知らずに
# そのまま呼べる
# doctor.shは各パッケージ形態 (rpm/AppImage) が
# launcher-common.shの隣に配置する
#===============================================================================
# shellcheck source=scripts/doctor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doctor.sh"
