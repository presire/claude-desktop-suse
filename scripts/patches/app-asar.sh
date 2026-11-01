#
# @file patches/app-asar.sh
# @brief app.asarへのパッチ適用を全体として順に進める
#
# app.asarを取り出し、起動用の入口を差し替え、ネイティブモジュールをスタブに置き換え、
# 翻訳ファイルとトレイアイコンを配置したうえで、機能ごとのパッチを呼び出す
# 個々の書き換えは各パッチのスクリプトが完結させるので、
# ここでは何をどの順で適用するかだけを管理する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : claude_extract_dir、app_staging_dir、asar_exec、
#                          source_dir、build_format、dark_tray_icons、WM_CLASS
# 変更するグローバル変数 : main_js、STARTUP_WM_CLASS (exportする)、
#                          electron_var、electron_var_re
#                          (後ろ2つは呼び出したトレイのパッチが変更する)
#

#
# @brief app.asar.contents/package.jsonの項目を1つ読み出す
# @param $1 項目名
# @stdout 項目の値 (項目が無い場合は空)
# @note カレントディレクトリがapp.asar.contentsである前提で動く
#
_read_package_json_field() {
	local field="$1"
	node -e 'console.log(require("./app.asar.contents/package.json")[process.argv[1]] ?? "")' \
		"$field"
}

#
# @brief desktopNameからデスクトップエントリのStartupWMClassを導出する
# @param $1 package.jsonに書き込むdesktopName
# @stdout .desktopの接尾辞を除いた値
# @stderr 導出できない場合のエラー
# @return 0 = 導出できた、1 = 導出できない
# @note ChromiumはdesktopNameから.desktopの接尾辞を除いた値を、
#       実行時のX11のWM_CLASSとWaylandのapp_idにする
#       --class、productName、ELFのファイル名は見ない
#       そのため値は出荷形式に依存する (rpmはclaude-desktop.desktop、
#       AppImageはio.github.presire.claude-desktop-suse.desktop)
#       patch_app_asarがpackage.jsonに書き込む値と同じ変数から導出し、
#       2つの値がずれないようにする (#779)
#       空の値を返して先に進まず、ここで失敗させる
#       項目が無い、または接尾辞が変わったまま出荷すると、
#       自分のウィンドウをまとめられないdesktopエントリになるため
#
_derive_startup_wm_class() {
	local desktop_name="$1"

	if [[ -z $desktop_name ]]; then
		echo 'Error: desktopName is missing/empty — cannot derive' \
			'StartupWMClass. Upstream moved the field Chromium reads' \
			'the window class from; re-verify before shipping (#779).' >&2
		return 1
	fi
	if [[ $desktop_name != *.desktop ]]; then
		echo "Error: desktopName '$desktop_name' has no .desktop suffix" \
			'— upstream changed its shape; re-verify how Chromium' \
			'derives the window class before shipping (#779).' >&2
		return 1
	fi

	printf '%s\n' "${desktop_name%.desktop}"
}

#
# @brief パッチ関数を1つ、現在のシェルで実行する
# @param $1 実行するパッチ関数の名前
# @param $2 検証の方法 (check = 前後でダイジェストを比べる、no-check = 比べない)
# @global patch_noop_declared (本関数で空にする)
# @stderr 実行に失敗した場合、または効果を確認できなかった場合のメッセージ
# @return 0 = 実行でき、効果も確認できた、1 = それ以外
# @note トレイのパッチはelectron_varとelectron_var_reをグローバル変数として残し、
#       後続のパッチがそれを読む
#       そのため出力をサブシェルで受け取ると、値が失われてしまう
#       また、途中まで書き換えて失敗したパッチを、ダイジェストが動いたという理由で
#       有効とみなしてはいけないため、終了コードが0以外なら段階を失敗させる
#       最初の実行ではcheckを使い、.vite/buildのダイジェストが変わるか、
#       許可リストに載っている無変更であることを確認する
#       no-checkはPATCH_STAGE_RERUN=1による再実行用で、
#       個々のパッチが何も変更しないのが正しく、段階全体の冪等性だけを見る
#
_run_suse_patch_function() {
	local fn="$1"
	local mode="${2:-check}"
	local before after

	if [[ $mode == 'check' ]]; then
		before=$(_patch_bundle_digest) || {
			echo "Patch effect: cannot digest the bundle before $fn" >&2
			return 1
		}
	fi

	patch_noop_declared=''
	"$fn"
	local fn_status=$?
	if (( fn_status != 0 )); then
		echo "Patch stage: $fn failed (exit $fn_status)" >&2
		return 1
	fi

	if [[ $mode == 'check' ]]; then
		after=$(_patch_bundle_digest) || {
			echo "Patch effect: cannot digest the bundle after $fn" >&2
			return 1
		}
		_check_patch_effect "$fn" "$before" "$after" \
			"$patch_noop_declared" || return 1
	fi
}

#
# @brief パッチ段階を中断し、ビルド全体を失敗させる
# @global project_root (参照のみ)
# @stderr 中断したことを示すメッセージ
# @note 原因は呼び出し元が既に出しているため、ここでは案内だけを出す
#       カレントディレクトリはステージング先なので、元に戻してから終了する
#
_suse_patch_stage_fail() {
	echo 'Patch stage aborted. See the Patch effect message above.' >&2
	cd "$project_root" || exit 1
	exit 1
}

#
# @brief 機能ごとのパッチを、依存関係のある順に適用する
# @param $1 検証の方法 (check または no-check、省略時はcheck)
# @stdout 各パッチの進捗
# @note カレントディレクトリはapp_staging_dirで、main_jsは解決済みという前提
#       PATCH_STAGE_RERUN=1の冪等性の自己検査が、適用済みのツリーに
#       全く同じ順序を再実行できるよう、段階を関数として切り出している
#       再実行ではno-checkを渡し、個々のパッチの効果判定が
#       冪等性ガードを失敗とみなさないようにする
#       1つでも失敗したら、後続のパッチは適用せずに段階を中断する
#
_run_suse_patch_stage() {
	local mode="${1:-check}"
	# トレイのパッチが使うelectronモジュールの変数名を取り出す
	_run_suse_patch_function extract_electron_variable "$mode" || _suse_patch_stage_fail

	# nativeThemeを誤った変数から参照している箇所を直す
	_run_suse_patch_function fix_native_theme_references "$mode" || _suse_patch_stage_fail

	# トレイメニューのハンドラを差し替える
	_run_suse_patch_function patch_tray_menu_handler "$mode" || _suse_patch_stage_fail

	# テーマに応じたトレイアイコンの選択を追加する
	_run_suse_patch_function patch_tray_icon_selection "$mode" || _suse_patch_stage_fail

	# [CLAUDE_TRAY_USE_DARK_ICON]を尊重する
	# Cinnamonの暗いパネルでは明るいアイコンが見えないため (#604)
	_run_suse_patch_function patch_tray_icon_env_override "$mode" || _suse_patch_stage_fail

	# テーマの変更時に、トレイアイコンをその場で差し替える高速な経路を差し込む
	# アイコンを破棄して作り直す方法では、KDEでSNIの項目が二重に残る競合が起きるため
	_run_suse_patch_function patch_tray_inplace_update "$mode" || _suse_patch_stage_fail

	# Linuxではトレイのコンテキストメニューを残す
	# 上流の使用量メニューの分岐は、setContextMenuを右クリック時の
	# popUpContextMenuに置き換えるが、ElectronのLinuxでは動かない
	# 代わりに左クリックをトレイの起動として記録し、使用量の取得に使う
	_run_suse_patch_function patch_tray_linux_context_menu "$mode" || _suse_patch_stage_fail

	# menuBarEnabledが未設定のときにtrueになる既定値を入れる
	_run_suse_patch_function patch_menu_bar_default "$mode" || _suse_patch_stage_fail

	# クイックウィンドウを追加する
	_run_suse_patch_function patch_quick_window "$mode" || _suse_patch_stage_fail

	# 終了メニューの項目に[Ctrl]+[Q]を割り当てる (SUSE固有)
	_run_suse_patch_function patch_exit_accelerator "$mode" || _suse_patch_stage_fail

	# Claude CodeのLinux対応を追加する
	_run_suse_patch_function patch_linux_claude_code "$mode" || _suse_patch_stage_fail

	# ディレクトリかどうかを調べる補助関数で.asarのパスを除外する
	# ElectronのASAR仮想ファイルシステムがapp.asarをフォルダと誤認し、
	# Coworkへの振り分けを誤って起こさないようにするため (#383、#622、#632)
	_run_suse_patch_function patch_asar_path_filter "$mode" || _suse_patch_stage_fail

	# 引数からのファイルドロップ収集で.asarのパスを除外する
	# existsSyncの分岐がapp.asarをファイルドロップと誤認し、
	# ウィンドウを開き直すたびに許可の確認が出るため (#383、#622)
	_run_suse_patch_function patch_asar_argv_file_drop_guard "$mode" || _suse_patch_stage_fail

	# Linux向けのCoworkモードを有効にする (TypeScriptのVMクライアントとUnixソケット)
	_run_suse_patch_function patch_cowork_linux "$mode" || _suse_patch_stage_fail

	# 同梱のvirtiofsdを代替として使えるよう、探索の条件を外す
	_run_suse_patch_function patch_virtiofsd_probe "$mode" || _suse_patch_stage_fail

	# MDMで管理するプラグインのマーケットプレイス用に、
	# Linuxのorg-pluginsのパスを追加する
	_run_suse_patch_function patch_org_plugins_path "$mode" || _suse_patch_stage_fail

	# claude.aiのデスクトップ用トップバーがLinuxで描画されるよう、
	# WCO(Window Controls Overlay、ウィンドウ枠のボタン領域) の互換処理を
	# BrowserViewのプリロードに差し込む
	# このトップバーの表示は、バンドルのisWindows()による判定に依存しており、
	# 互換処理の中でもここが要になる
	# あわせてmatchMediaとwindowControlsOverlayも補う (保険)
	# 詳しくはdocs/learnings/linux-topbar-shim.mdを参照する
	_run_suse_patch_function patch_wco_shim "$mode" || _suse_patch_stage_fail

	# 設定の読み込みに失敗した状態で書き込むとmcpServersが消えるため、
	# その場合は既存のmcpServersを残す
	# 設定画面で削除したサーバーは、そのまま書き込む (#400)
	_run_suse_patch_function patch_config_write_merge "$mode" || _suse_patch_stage_fail

	# addTrustedFolderで.asarのパスを除外する
	# 不要な設定の書き込みが、古いキャッシュの上書き不具合を増やすため (#400)
	_run_suse_patch_function patch_asar_trusted_folder_guard "$mode" || _suse_patch_stage_fail

	# --add-dirの振り分けとセッションの復元から.asarのパスを取り除く
	# #640より前の壊れたセッションが、ローカルエージェントモードを
	# クラッシュさせないようにするため (#649)
	_run_suse_patch_function patch_asar_additional_dirs_guard "$mode" || _suse_patch_stage_fail
}

#
# @brief app.asarを取り出し、起動用の入口と同梱物を整えてからパッチ段階を実行する
# @global claude_extract_dir (参照のみ: nupkgを展開したディレクトリ)
# @global app_staging_dir (参照のみ: app.asarを展開する作業ディレクトリ)
# @global asar_exec (参照のみ: asarコマンドのパス)
# @global source_dir (参照のみ: scriptsとassetsを持つリポジトリのルート)
# @global build_format (参照のみ: rpm または appimage)
# @global dark_tray_icons (参照のみ: 暗いテーマ向けのアイコンを使うか)
# @global WM_CLASS (参照のみ: 期待するウィンドウクラス)
# @global main_js 解決したメインプロセスのJavaScript (本関数で設定する)
# @global STARTUP_WM_CLASS 導出した値 (本関数で設定し、exportする)
# @note 失敗した場合はプロジェクトのルートに戻ってビルドを止める
#       この先の処理も、カレントディレクトリがステージング先である前提で動く
#
patch_app_asar() {
	echo 'Processing app.asar...'
	cp "$claude_extract_dir/lib/net45/resources/app.asar" "$app_staging_dir/" || exit 1
	cp -a "$claude_extract_dir/lib/net45/resources/app.asar.unpacked" "$app_staging_dir/" || exit 1
	cd "$app_staging_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# ウィンドウ枠の調整を実行時に差し込むラッパーを配置する
	echo 'Creating BrowserWindow frame fix wrapper...'
	local original_main
	original_main=$(_read_package_json_field main)
	echo "Original main entry: $original_main"

	cp "$source_dir/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js || exit 1
	cp "$source_dir/scripts/frame-fix-menu.js" app.asar.contents/frame-fix-menu.js || exit 1
	cp "$source_dir/scripts/frame-fix-autostart.js" app.asar.contents/frame-fix-autostart.js || exit 1

	cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

	# BrowserWindowのウィンドウ枠とtitleBarStyleの調整は、
	# frame-fix-wrapper.jsがrequire('electron')にProxyを仕掛けて実行時に行う
	# そのためsedでの書き換えは要らず、ラッパーがオプションを見て
	# ポップアップとメインウィンドウを区別し、frameをtrueかfalseにする

	# package.jsonを書き換え、pkg.desktopNameを設定する
	# KDE Plasma Waylandで、インストールした.desktopファイルと
	# ウィンドウが同じグループになるようにするため (#562)
	# 値は出荷形式で変える
	# rpmではclaude-desktop.desktopをインストールする
	# AppImageはAppDirの中にio.github.presire.claude-desktop-suse.desktopを
	# 同梱し、Gear LeverやAppImageLauncherが統合に使うidになる
	echo 'Modifying package.json to load frame fix and add node-pty...'
	local desktop_name='claude-desktop.desktop'
	if [[ ${build_format:-} == 'appimage' ]]; then
		desktop_name='io.github.presire.claude-desktop-suse.desktop'
	fi
	node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.desktopName = process.argv[1];
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry, desktopName=' + process.argv[1] + ', and node-pty dependency');
" "$desktop_name"

	# パッケージ用のスクリプトとbuild.shは、この値を全ての.desktopの
	# StartupWMClassに埋め込む
	# 空の値のまま進むと壊れたエントリを出荷することになるため、
	# 導出できなければ処理を続けない
	# パッケージ用のスクリプトは子プロセスとして動くのでexportする
	STARTUP_WM_CLASS=$(_derive_startup_wm_class "$desktop_name") || {
		cd "$project_root" || exit 1
		exit 1
	}
	export STARTUP_WM_CLASS
	echo "StartupWMClass '$STARTUP_WM_CLASS' derived from desktopName '$desktop_name'"

	local product_name
	product_name=$(_read_package_json_field productName)
	if [[ $product_name != "$WM_CLASS" ]]; then
		echo "Error: upstream productName '$product_name' != WM_CLASS '$WM_CLASS'" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# 分割されたメインプロセスのチャンクはここで1度だけ解決する
	# 以降のパッチはmain_jsを読む
	# 上流1.19367.0以降、index.jsは本体のチャンク
	# (index.chunk-<hash>.js)をrequireするだけのスタブになった
	# パッチのアンカーはスタブではなくチャンクの中にある
	local stub_js='app.asar.contents/.vite/build/index.js'
	main_js=$(_resolve_main_js "$stub_js") || {
		echo 'Failed to resolve main-process JS from stub' >&2
		echo "  This usually means the installed Claude version's bundle" \
			'layout is newer than the patch scripts support.' >&2
		echo '  Build the verified default release instead (omit' \
			'--claude-version):' >&2
		echo '    ./build.sh --build rpm' >&2
		cd "$project_root" || exit 1
		exit 1
	}
	echo "Main-process JS: $main_js"

	# MB-1の検知用の仕掛け (tripwire)
	# メニューバーを表示したままにする既定値が残っているかを確認する
	# トレイのパッチはこの既定値を前提にしている
	# 上流が既定値を反転させると、Linuxではメニューバーが既定で非表示になる
	# 分割されたバンドルではアンカーがindex.chunk-<hash>.jsにあるため、
	# index.jsではなく解決後のファイルを確認する
	_check_mb1_tripwire "$main_js" || {
		cd "$project_root" || exit 1
		exit 1
	}
	echo 'Upstream tripwire clear (menuBarEnabled:!0 present)'

	# ネイティブモジュールの代わりにスタブを置く
	echo 'Creating stub native module...'
	mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1

	mkdir -p app.asar.contents/resources/i18n || exit 1
	# 地域を持たないファイル (am.json、ru.jsonなど) も含めて全ての翻訳を扱う
	# 3.xまではapp.asarの隣に同梱されていた
	# 4.xではapp.asarの中のresources/i18nに入っており、
	# メインプロセスはそこから読む (__dirname/../../resources/i18n)
	local -a locale_jsons=("$claude_extract_dir/lib/net45/resources/"*.json)
	if [[ -f ${locale_jsons[0]} ]]; then
		cp "${locale_jsons[@]}" app.asar.contents/resources/i18n/ || exit 1
	else
		local -a bundled_locales=(app.asar.contents/resources/i18n/*.json)
		if [[ ! -f ${bundled_locales[0]} ]]; then
			echo 'Error: no locale JSON next to app.asar and none in app.asar resources/i18n' >&2
			exit 1
		fi
		echo "app.asar already ships ${#bundled_locales[@]} locale files in resources/i18n"
	fi

	# パッケージ後 (process.resourcesPath) と未パッケージ (app.getAppPath()) の
	# どちらの経路からも見つけられるよう、トレイアイコンをasarに入れる
	cp "$claude_extract_dir/lib/net45/resources/Tray"* app.asar.contents/resources/ 2>/dev/null || \
		echo 'Warning: No tray icon files found for asar inclusion'

	# --dark指定時は、asarの中の既定のトレイアイコンを暗いテーマ向けに差し替える
	if [[ ${dark_tray_icons:-false} == true ]]; then
		echo 'Replacing asar tray icons with dark-mode variants...'
		local dark_icon base_icon
		for dark_icon in app.asar.contents/resources/TrayIconTemplate-Dark*.png; do
			[[ ! -f $dark_icon ]] && continue
			base_icon="${dark_icon/-Dark/}"
			cp "$dark_icon" "$base_icon"
		done
	fi

	_run_suse_patch_stage

	# 任意で有効にする冪等性の自己検査
	# 上流のDebian版のPATCH_STAGE_RERUN=1と同じ考え方で、
	# 適用済みのツリーに同じパッチを再実行し、1バイトでも変われば失敗させる
	# つまり、冪等性ガードが自分の出力を見落として二重に適用した場合を検出する
	# 変数が未設定のときの既定の動作は変えない
	if [[ ${PATCH_STAGE_RERUN:-} == '1' ]]; then
		echo 'PATCH_STAGE_RERUN=1: re-running patch stage' \
			'to verify idempotency...'
		local rerun_before rerun_after
		rerun_before=$(_patch_bundle_digest) || {
			echo 'Idempotency: cannot digest the patched' \
				'bundle' >&2
			cd "$project_root" || exit 1
			exit 1
		}
		_run_suse_patch_stage no-check
		rerun_after=$(_patch_bundle_digest) || {
			echo 'Idempotency: cannot digest the bundle' \
				'after the re-run' >&2
			cd "$project_root" || exit 1
			exit 1
		}
		_check_patch_stage_idempotent \
			"$rerun_before" "$rerun_after" || {
			cd "$project_root" || exit 1
			exit 1
		}
		echo 'Idempotency: second patch pass left the bundle unchanged'
	fi

	# LinuxのCoworkモード用に、CoworkのVMサービスを配置する
	echo 'Installing cowork VM service daemon...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		app.asar.contents/cowork-vm-service.js || exit 1
	echo 'Cowork VM service daemon installed'
}
