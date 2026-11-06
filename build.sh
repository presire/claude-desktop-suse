#!/usr/bin/env bash
#
# @file build.sh
# @brief Claude DesktopをopenSUSE/SLE向けの.rpmと.AppImageに組み直す
#
# Anthropicが配布するWindowsのnupkgを取得して展開し、
# SUSE向けのパッチを当ててから、Electronアプリとしてパッケージに詰める
# 途中の段階はscripts/配下の関数に分かれており、このファイルは順番を決める
#

# グローバル変数 (関数が設定し、以降の段階で使う)
architecture=''                # 対象のアーキテクチャ (amd64 または arm64)
override_arch=''               # [--arch]で指定されたアーキテクチャ
distro_family=''               # 判定したディストリビューション (suse または unknown)
claude_nupkg_url=''            # 取得するnupkgのURL
claude_nupkg_filename=''       # 取得したnupkgのファイル名
claude_nupkg_sha1=''           # RELEASESに載っているSHA-1 (取得内容の照合用)
claude_version_override=''     # [--claude-version]の値 (X.Y.Z または latest)
claude_sha256_override=''      # [--claude-sha256]で上書きされたnupkgのSHA-256
claude_nupkg_sha256=''         # 実際に照合するSHA-256 (固定値か上書き値)
version=''                     # ビルドするClaude Desktopのバージョン
release_tag=''                 # パッケージの版を分けるためのリリースタグ (例 : v1.3.2+claude1.1.799)
build_format=''                # 出力形式 (rpm または appimage)
cleanup_action='yes'           # [--cleanup]または[--no-cleanup]の指定内容
perform_cleanup=false          # 中間ファイルを消すかどうかの判定結果
test_flags_mode=false          # [--test]で引数の解釈だけを確かめるモードか
local_exe_path=''              # [--local-exe]で渡されたnupkgのパス
source_dir=''                  # scriptsとassetsを読むリポジトリのルート
node_pty_dir=''                # ビルド済みnode-ptyの置き場所 (npm installを省略する)
original_user=''               # build.shを起動したユーザー名 (nvmとNodeの場所を調べるのに使う)
original_home=''               # そのユーザーのHOME (同上)
project_root=''                # 成果物を置くリポジトリのルート
work_dir=''                    # ビルド途中のファイルを置く作業ディレクトリ
app_staging_dir=''             # パッケージに詰める前のアプリのツリー
chosen_electron_module_path='' # 採用したElectronモジュールのパス
electron_var=''                # 展開先のElectronが使う変数の名前
electron_var_re=''             # その変数を探すための正規表現
asar_exec=''                   # asarコマンドの実行方法
claude_extract_dir=''          # nupkgを展開したディレクトリ
electron_resources_dest=''     # Electronのresourcesを置く先
node_pty_build_dir=''          # node-ptyをビルドするディレクトリ
final_output_path=''           # 作った成果物のパス (次の手順の案内に使う)
install_prefix='/usr/lib'      # インストール先の接頭辞

# パッケージのメタデータ (定数)
readonly PACKAGE_NAME='claude-desktop'
readonly MAINTAINER='Claude Desktop Linux Maintainers'
readonly DESCRIPTION='Claude Desktop for Linux'
# pgrepでコマンドラインを照合するための--classの値 (#779)
# Chromiumがウィンドウに付けるクラス (下のSTARTUP_WM_CLASS) とは別物である
readonly WM_CLASS='Claude'
export WM_CLASS

# パッケージに載せる.desktopのStartupWMClass (#779)
# patch_app_asarがステージング済みのasarのpackage.json desktopNameから求める
# 求まるまでは空のままにし、run_packagingが壊れた.desktopを出さないようにする
STARTUP_WM_CLASS=''
export STARTUP_WM_CLASS

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # 以降のsourceはこの位置を基準にする
# shellcheck source=scripts/_common.sh
source "$script_dir/scripts/_common.sh"
# shellcheck source=scripts/setup/detect-host.sh
source "$script_dir/scripts/setup/detect-host.sh"
# shellcheck source=scripts/setup/dependencies.sh
source "$script_dir/scripts/setup/dependencies.sh"
# shellcheck source=scripts/setup/download.sh
source "$script_dir/scripts/setup/download.sh"
# shellcheck source=scripts/staging/electron.sh
source "$script_dir/scripts/staging/electron.sh"
# shellcheck source=scripts/staging/icons.sh
source "$script_dir/scripts/staging/icons.sh"
# shellcheck source=scripts/staging/locales.sh
source "$script_dir/scripts/staging/locales.sh"
# shellcheck source=scripts/staging/ssh-helpers.sh
source "$script_dir/scripts/staging/ssh-helpers.sh"
# shellcheck source=scripts/staging/cowork-resources.sh
source "$script_dir/scripts/staging/cowork-resources.sh"
# shellcheck source=scripts/patches/_common.sh
source "$script_dir/scripts/patches/_common.sh"
# shellcheck source=scripts/patches/app-asar.sh
source "$script_dir/scripts/patches/app-asar.sh"
# shellcheck source=scripts/patches/file-manager-entries.sh
source "$script_dir/scripts/patches/file-manager-entries.sh"
# shellcheck source=scripts/patches/tray.sh
source "$script_dir/scripts/patches/tray.sh"
# shellcheck source=scripts/patches/quick-window.sh
source "$script_dir/scripts/patches/quick-window.sh"
# shellcheck source=scripts/patches/claude-code.sh
source "$script_dir/scripts/patches/claude-code.sh"
# shellcheck source=scripts/patches/cowork.sh
source "$script_dir/scripts/patches/cowork.sh"
# shellcheck source=scripts/patches/wco-shim.sh
source "$script_dir/scripts/patches/wco-shim.sh"
# shellcheck source=scripts/patches/config.sh
source "$script_dir/scripts/patches/config.sh"
# shellcheck source=scripts/patches/org-plugins.sh
source "$script_dir/scripts/patches/org-plugins.sh"
# shellcheck source=scripts/patches/terminal-da-reply.sh
source "$script_dir/scripts/patches/terminal-da-reply.sh"
# shellcheck source=scripts/patches/exit-accelerator.sh
source "$script_dir/scripts/patches/exit-accelerator.sh"
# shellcheck source=scripts/patches/virtiofsd-probe.sh
source "$script_dir/scripts/patches/virtiofsd-probe.sh"



#===============================================================================
# パッケージ作成
#===============================================================================

#
# @brief 選ばれた出力形式のパッケージ作成スクリプトを呼び、成果物をカレントに移す
# @global build_format、architecture、version、work_dir、app_staging_dir (参照のみ)
# @global STARTUP_WM_CLASS、PACKAGE_NAME、MAINTAINER、DESCRIPTION、install_prefix (参照のみ)
# @global final_output_path (本関数で設定する)
# @note 成果物は後片付けの前にカレントディレクトリへ移し、作業ディレクトリごと消えても残す
#       見つからなかった場合は"Not Found"を入れ、次の手順で誤った案内を出さない
#
run_packaging() {
	section_header 'Call Packaging Script'

	# どの出力形式でもStartupWMClassを.desktopへ埋め込む
	# patch_app_asarがasarのdesktopNameから求められていない場合は、
	# 壊れた.desktopを出さないよう、ここで止める
	if [[ -z $STARTUP_WM_CLASS ]]; then
		echo 'Error: STARTUP_WM_CLASS is empty — patch_app_asar did not' \
			'derive it from the staged app.asar desktopName (see' \
			'scripts/patches/app-asar.sh)' >&2
		exit 1
	fi

	local output_path=''

	case "$build_format" in
		rpm)
			# RPMはspecを解釈させるため、パッケージ作成スクリプトに任せる
			echo "Calling RPM packaging script for $architecture..."
			chmod +x "scripts/packaging/rpm.sh" || exit 1
			if ! "scripts/packaging/rpm.sh" \
				"$version" "$architecture" "$work_dir" "$app_staging_dir" \
				"$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION" "$install_prefix"; then
				echo 'RPM packaging script failed.' >&2
				exit 1
			fi

			local pkg_file
			pkg_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}*.rpm" | head -n 1)
			echo 'RPM Build complete!'
			if [[ -n $pkg_file && -f $pkg_file ]]; then
				output_path="./$(basename "$pkg_file")"
				mv "$pkg_file" "$output_path" || exit 1
				echo "Package created at: $output_path"
			else
				echo 'Warning: Could not determine final .rpm file path.'
				output_path='Not Found'
			fi
			;;
		appimage)
			# AppImageはappimagetoolに任せ、出来た.desktopも一緒に残す
			echo "Calling AppImage packaging script for $architecture..."
			chmod +x "scripts/packaging/appimage.sh" || exit 1
			if ! "scripts/packaging/appimage.sh" \
				"$version" "$architecture" "$work_dir" "$app_staging_dir" \
				"$PACKAGE_NAME"; then
				echo 'AppImage packaging script failed.' >&2
				exit 1
			fi

			local appimage_file
			appimage_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}-${architecture}.AppImage" | head -n 1)
			echo 'AppImage Build complete!'
			if [[ -n $appimage_file && -f $appimage_file ]]; then
				output_path="./$(basename "$appimage_file")"
				mv "$appimage_file" "$output_path" || exit 1
				echo "Package created at: $output_path"

				section_header 'Generate .desktop file for AppImage'
				local desktop_file="./${PACKAGE_NAME}-appimage.desktop"
				echo "Generating .desktop file for AppImage at $desktop_file..."
				cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $version)
Exec=$(basename "$output_path") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=$STARTUP_WM_CLASS
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop (AppImage)
EOF
				echo '.desktop file generated.'
			else
				echo 'Warning: Could not determine final .AppImage file path.'
				output_path='Not Found'
			fi
			;;
	esac

	# 次の手順の案内で使うため、成果物のパスを保持する
	final_output_path="$output_path"
}

#
# @brief 中間ファイルを消す (消す指定がある場合だけ)
# @global perform_cleanup、work_dir (参照のみ)
# @note 消すかどうかは[--cleanup]と[--no-cleanup]の指定で決まる
#       消さない場合も、作業ディレクトリの場所だけは伝える
#
cleanup_build() {
	section_header 'Cleanup'
	if [[ $perform_cleanup != true ]]; then
		echo "Skipping cleanup of intermediate build files in $work_dir."
		return
	fi

	echo "Cleaning up intermediate build files in $work_dir..."
	if rm -rf "$work_dir"; then
		echo "Cleanup complete ($work_dir removed)."
	else
		echo 'Cleanup command failed.'
	fi
}

#
# @brief 作った成果物の導入手順を表示する
# @global build_format、final_output_path (参照のみ)
# @note 成果物が見つからない場合は、誤った手順を出さずにその旨だけ伝える
#
print_next_steps() {
	echo -e '\n\033[1;34m====== Next Steps ======\033[0m'

	case "$build_format" in
		rpm)
			# 導入はzypperを基本にし、rpm直接指定も併記する
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				echo -e "To install the RPM package, run:"
				echo -e "   \033[1;32msudo zypper install $final_output_path\033[0m"
				echo -e "   (or \`sudo rpm -i $final_output_path\`)"
			else
				echo -e 'RPM package file not found. Cannot provide installation instructions.'
			fi
			;;
		appimage)
			# AppImageはデスクトップ統合とclaude://の処理をGear Leverに任せる
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				echo -e "AppImage created at: \033[1;36m$final_output_path\033[0m"
				echo -e '\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration'
				# shellcheck disable=SC2016  # 表示用のバッククォートなので展開しない
				echo -e 'and to handle the `claude://` login process correctly.'
				echo -e '\nTo install Gear Lever:'
				echo -e '   1. Install via Flatpak:'
				echo -e '      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m'
				echo -e '   2. Integrate your AppImage with just one click:'
				echo -e '      - Open Gear Lever'
				echo -e "      - Drag and drop \033[1;36m$final_output_path\033[0m into Gear Lever"
				echo -e "      - Click 'Integrate' to add it to your app menu"
				# 更新情報を埋め込めるのは、リリース用にビルドした場合だけである
				if [[ ${GITHUB_ACTIONS:-} == 'true' ]]; then
					echo -e '\n   This AppImage includes embedded update information!'
				else
					echo -e '\n   This locally-built AppImage does not include update information.'
					echo -e '   For automatic updates, download release versions: https://github.com/presire/claude-desktop-suse/releases'
				fi
			else
				echo -e 'AppImage file not found. Cannot provide usage instructions.'
			fi
			;;
	esac

	echo -e '\033[1;34m======================\033[0m'
}

#===============================================================================
# メイン処理
#===============================================================================

#
# @brief 引数を解釈してから、取得、パッチ、ステージング、パッケージ作成を順に実行する
# @param $@ コマンドライン引数
# @note 段階ごとにコメントで区切ってある
#       [--test]が指定された場合は、決まった設定だけを表示してビルドせずに終わる
#
main() {
	# 段階1: 準備
	parse_arguments "$@"
	detect_architecture
	detect_distro
	check_system_requirements
	resolve_latest_url

	# テストモードは、取得先と設定を確かめるところで終える
	if [[ $test_flags_mode == true ]]; then
		echo '--- Test Flags Mode Enabled ---'
		echo "Build Format: $build_format"
		echo "Target Architecture: $architecture"
		echo "Clean Action: $cleanup_action"
		echo "Install Prefix: $install_prefix"
		echo "Download URL: $claude_nupkg_url"
		echo "Nupkg: $claude_nupkg_filename"
		echo "Expected SHA-256: ${claude_nupkg_sha256:-none}"
		echo 'Exiting without build.'
		exit 0
	fi

	check_dependencies
	setup_work_directory
	setup_nodejs
	setup_electron_asar

	# 段階2: ダウンロードと展開
	download_claude_installer

	# 段階3: パッチとステージング
	patch_app_asar
	install_node_pty
	finalize_app_asar
	stage_electron
	process_icons
	copy_ssh_helpers
	copy_cowork_resources
	copy_locale_files

	cd "$project_root" || exit 1 # 成果物をカレントに置くため、リポジトリのルートへ戻る

	# 段階4: パッケージ作成
	run_packaging

	# 段階5: 後片付けと完了
	cleanup_build

	echo 'Build process finished.'
	print_next_steps
}

# 引数をすべてmainへ渡す
main "$@"

exit 0
