#!/usr/bin/env bash

#
# @file appimage.sh
# @brief ステージング済みのアプリからAppImageを組み立てる
#
# AppDirを組み立て、AppRun・デスクトップエントリ・アイコン・AppStreamの
# メタ情報を入れ、appimagetoolで1つのAppImageにまとめる
# GitHub Actionsでは更新情報を埋め込み、.zsyncも公開用の名前へ移す
#
# 使い方 : appimage.sh <version> <architecture> <work_dir> <app_staging_dir>
#          <package_name>
# 終了コード : 0 = AppImageを生成できた、1 = 引数不正または生成の失敗
#

# メインスクリプトから受け取る引数
version="$1"
architecture="$2"
work_dir="$3"           # 作業ディレクトリの最上位 (例 : ./build)
app_staging_dir="$4"    # アプリ一式を用意したディレクトリ
package_name="$5"

# 版番号はAppRunの--versionの即時応答に入るため、
# 不正な値はパッケージを作る前に弾いて上流で止める
if [[ -z $version || ! $version =~ ^[0-9]+(\.[0-9]+)+(-[0-9]+(\.[0-9]+)*)?$ ]]; then
	echo "Error: invalid build version '$version'" >&2
	echo 'Expected a non-empty version starting with a digit' >&2
	exit 1
fi

echo '--- Starting AppImage Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

component_id='io.github.presire.claude-desktop-suse'
# AppDirの配置先を決める
# AppImage内部のパスは慣習どおり/usr/libを使い、
# SUSEホストの/usr/lib64とは独立に扱う
appdir_path="$work_dir/${component_id}.AppDir"
rm -rf "$appdir_path"
mkdir -p "$appdir_path/usr/bin" || exit 1
mkdir -p "$appdir_path/usr/lib" || exit 1
mkdir -p "$appdir_path/usr/share/icons/hicolor/256x256/apps" || exit 1
mkdir -p "$appdir_path/usr/share/applications" || exit 1

echo 'Staging application files into AppDir...'
# Electronのディレクトリ構成を先に作るため、node_modulesから複製する
if [[ -d $app_staging_dir/node_modules ]]; then
	echo 'Copying node_modules from staging to AppDir...'
	cp -a "$app_staging_dir/node_modules" "$appdir_path/usr/lib/" || exit 1
fi

# process.resourcesPathが指すElectronのresourcesへapp.asarを入れる
resources_dir="$appdir_path/usr/lib/node_modules/electron/dist/resources"
mkdir -p "$resources_dir" || exit 1
if [[ -f $app_staging_dir/app.asar ]]; then
	cp -a "$app_staging_dir/app.asar" "$resources_dir/" || exit 1
fi
if [[ -d $app_staging_dir/app.asar.unpacked ]]; then
	cp -a "$app_staging_dir/app.asar.unpacked" "$resources_dir/" || exit 1
fi
echo 'Application files copied to Electron resources directory'

# 共有ランチャーライブラリを複製する (launcher-common.shは実行時に
# doctor.shを読み込むため、両方を同じディレクトリへ置く)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$appdir_path/usr/lib/claude-desktop" || exit 1
cp "$(dirname "$script_dir")/launcher-common.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "$appdir_path/usr/lib/claude-desktop/launcher-common.sh"
cp "$(dirname "$script_dir")/doctor.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
echo 'Shared launcher library + doctor copied'

# AppDir単体で動くよう、ElectronをAppDir内に必ず同梱する
bundled_electron_path="$appdir_path/usr/lib/node_modules/electron/dist/electron"
echo "Checking for executable at: $bundled_electron_path"
if [[ ! -x $bundled_electron_path ]]; then
	echo 'Electron executable not found or not executable in staging area.' >&2
	echo "Path checked: $bundled_electron_path" >&2
	echo 'AppImage requires Electron to be bundled. Ensure the main script copies it correctly.' >&2
	exit 1
fi
chmod +x "$bundled_electron_path" || exit 1

# AppRunスクリプトを生成する
echo 'Creating AppRun script...'
cat > "$appdir_path/AppRun" << 'EOF'
#!/usr/bin/env bash

# Find the location of the AppRun script
appdir=$(dirname "$(readlink -f "$0")")

# Source shared launcher library
source "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# Handle --doctor flag before anything else
if [[ "${1:-}" == '--doctor' ]]; then
	electron_path="$appdir/usr/lib/node_modules/electron/dist/electron"
	run_doctor "$electron_path" 'appimage'
	exit $?
fi

# --version fast path: print stamped version and exit 0 before any
# logging, display detection, D-Bus/sandbox, or Electron launch.
if [[ "${1:-}" == '--version' ]]; then
	echo '@@PACKAGE_NAME@@ @@VERSION@@'
	exit 0
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env
cleanup_replaced_desktop_ui
cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_cowork_socket
heal_autostart_entry "${APPIMAGE:-}"
backup_user_config

# Detect display backend
detect_display_backend
ensure_portal_app_id_entry "${APPIMAGE:-}" 'io.github.presire.claude-desktop-suse' \
	'io.github.presire.claude-desktop-suse'

# Log startup info
log_message '--- Claude Desktop AppImage Start ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"
log_message "APPDIR: $appdir"
log_session_env

# Path to the bundled Electron executable. It auto-loads
# resources/app.asar; passing the path again reaches the app as a file
# to open (claude-desktop-debian #696/#700).
electron_exec="$appdir/usr/lib/node_modules/electron/dist/electron"

# Build electron args (appimage mode probes the user-namespace sandbox
# and adds --no-sandbox only when it cannot start)
build_electron_args 'appimage'

# Change to HOME directory before launching Electron to avoid CWD permission issues
cd "$HOME" || exit 1

# Execute Electron. AppRun stays alive as Electron's parent so it can
# filter output into the log and reap Cowork/helper processes the app
# leaves behind; the FUSE mount is held until that cleanup finishes.
log_message "Executing: $electron_exec ${electron_args[*]} $*"
run_electron_and_cleanup "$electron_exec" "${electron_args[@]}" "$@"
EOF
chmod +x "$appdir_path/AppRun" || exit 1
# AppRunのヒアドキュメントは実行時の展開に任せる引用形式なので、
# ビルド時に決まる--versionの値を後から差し込む
sed -i "s/@@PACKAGE_NAME@@/$package_name/; s/@@VERSION@@/$version/" \
	"$appdir_path/AppRun" || exit 1
echo 'AppRun script created'

# AppDir内に同梱するデスクトップエントリを生成する
echo 'Creating bundled desktop entry...'
cat > "$appdir_path/$component_id.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=AppRun %u
Icon=$component_id
Type=Application
Terminal=false
Categories=Network;Utility;
Comment=Claude Desktop for Linux
MimeType=x-scheme-handler/claude;
StartupWMClass=$STARTUP_WM_CLASS
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop
EOF
mkdir -p "$appdir_path/usr/share/applications" || exit 1
cp "$appdir_path/$component_id.desktop" "$appdir_path/usr/share/applications/" || exit 1
echo 'Bundled desktop entry created and copied to usr/share/applications/'

# アイコンを複製する
echo 'Copying icons...'
# icotoolが付ける画像の番号はリリースごとに変わるためサイズだけで照合する
icon_source_path="$work_dir/claude_*_256x256x32.png"
for candidate in "$work_dir"/claude_*_256x256x32.png; do
	[[ -f $candidate ]] && icon_source_path="$candidate" && break
done
if [[ -f $icon_source_path ]]; then
	cp "$icon_source_path" "$appdir_path/usr/share/icons/hicolor/256x256/apps/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}" || exit 1
	cp "$icon_source_path" "$appdir_path/.DirIcon" || exit 1
	echo 'Icon copied to standard path, top-level (.png and no ext), and .DirIcon'
else
	echo "Warning: Missing 256x256 icon at $icon_source_path. AppImage icon might be missing."
fi

# AppStreamのメタ情報を生成する
echo 'Creating AppStream metadata...'
metadata_dir="$appdir_path/usr/share/metainfo"
mkdir -p "$metadata_dir" || exit 1

appdata_file="$metadata_dir/${component_id}.appdata.xml"

# project_licenseは利用者が起動するアプリ (プロプライエタリなClaude本体) を表す
# MITのパッケージ用スクリプトではなく、
# scripts/packaging/のRPM用メタ情報と揃える
cat > "$appdata_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$component_id</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <developer id="io.github.presire">
    <name>presire</name>
  </developer>

  <name>Claude Desktop</name>
  <summary>Unofficial desktop client for Claude AI</summary>

  <description>
    <p>
      Provides a desktop experience for interacting with Claude AI, wrapping the web interface.
    </p>
  </description>

  <launchable type="desktop-id">${component_id}.desktop</launchable>
  <icon type="stock">${component_id}</icon>

  <url type="homepage">https://github.com/presire/claude-desktop-suse</url>
  <screenshots>
      <screenshot type="default">
          <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>
      </screenshot>
  </screenshots>
  <provides>
    <binary>AppRun</binary>
  </provides>

  <categories>
    <category>Network</category>
    <category>Utility</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$version" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $version.</p>
      </description>
    </release>
  </releases>

</component>
EOF
echo "AppStream metadata created at $appdata_file"

# appimagetoolは内部でappstream-glibのappstream-utilも動かし、
# こちらはAppStreamの参照実装が許す<icon>を受け付けない
# ("<icon> not allowed in desktop appdata")
# そのためappstreamcliで先に検証し、appimagetool側の検査は下で切る
if command -v appstreamcli &> /dev/null; then
	if ! appstreamcli validate --no-net --explain "$appdata_file"; then
		echo "AppStream validation failed: $appdata_file" >&2
		exit 1
	fi
else
	echo 'appstreamcli not found - skipping AppStream validation (zypper install AppStream)' >&2
fi


# appimagetoolを用意する
# appimagetoolはパッケージの対象アーキテクチャではなく、
# 実行するホストのアーキテクチャで動くネイティブバイナリなので、
# uname -mで厳密に選ぶ
# 対象アーキテクチャは後で埋め込むARCHと実行用ランタイムにだけ使う
host_arch=$(uname -m)
case "$host_arch" in
	x86_64|aarch64) ;;
	*)
		echo "Unsupported host architecture for appimagetool: $host_arch" >&2
		exit 1
		;;
esac

# AppImageのツール一式はバージョンとSHA-256で固定する
# (claude-desktop-debian #932からの移植)
# AppImageKitの旧continuousランタイムはlibfuse.so.2へ動的リンクしており、
# 最小構成のopenSUSE/SLEには必ずしも入っていない
# type2-runtimeのビルドはFUSEを静的リンクしているため、
# ホストにlibfuse2が無くてもAppImageを動かせる
# appimagetoolは対応するAppImage/appimagetoolプロジェクトから取得する
APPIMAGETOOL_VERSION='1.9.1'                                                                     # appimagetoolの固定バージョン
APPIMAGETOOL_SHA256_X86_64='ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'    # appimagetoolのx86_64向けSHA-256
APPIMAGETOOL_SHA256_AARCH64='f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158'   # appimagetoolのaarch64向けSHA-256
TYPE2_RUNTIME_VERSION='20251108'                                                                 # type2-runtimeの固定バージョン
TYPE2_RUNTIME_SHA256_X86_64='2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'   # x86_64向けtype2ランタイムのSHA-256
TYPE2_RUNTIME_SHA256_AARCH64='00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444'  # aarch64向けtype2ランタイムのSHA-256

#
# @brief 固定したSHA-256のファイルを取得し、手元の複製があれば再利用する
# @param $1 取得元のURL
# @param $2 保存先のパス
# @param $3 期待するSHA-256
# @return 0 = 検証済みのファイルがある、1 = 取得または検証に失敗した
# @note ハッシュが一致しないファイルは削除してから失敗を返すため、
#       壊れた取得物が次のビルドで再利用されることはない
#
fetch_pinned() {
	local url="$1" dest="$2" sha256="$3"
	local checksum_line="$sha256  $dest"
	if [[ -f $dest ]] \
		&& sha256sum -c --status <<< "$checksum_line" 2> /dev/null; then
		echo "Using cached $dest"
		return 0
	fi
	echo "Downloading $url"
	if ! wget -q -O "$dest" "$url"; then
		echo "Failed to download $url" >&2
		rm -f "$dest"
		return 1
	fi
	if ! sha256sum -c --status <<< "$checksum_line"; then
		echo "SHA-256 mismatch for $dest (expected $sha256)" >&2
		rm -f "$dest"
		return 1
	fi
	return 0
}

appimagetool_path=''

# まずシステムのPATHを探す
# ランタイムは下で--runtime-fileにより差し替えるため、
# ローカルのツールでもlibfuse2不要のAppImageを作れる
if command -v appimagetool &> /dev/null; then
	appimagetool_path=$(command -v appimagetool)
	echo "Found appimagetool in PATH: $appimagetool_path"
fi

# 見つからない場合はホストのアーキテクチャ向けの固定版を使う
# 名前にバージョンを含めることで、--clean noのビルドが
# 古いAppImageKitの取得物を再利用しない
if [[ -z $appimagetool_path ]]; then
	case "$host_arch" in
		x86_64) appimagetool_sha256="$APPIMAGETOOL_SHA256_X86_64" ;;
		aarch64) appimagetool_sha256="$APPIMAGETOOL_SHA256_AARCH64" ;;
	esac
	appimagetool_url='https://github.com/AppImage/appimagetool/releases/download/'
	appimagetool_url+="${APPIMAGETOOL_VERSION}/appimagetool-${host_arch}.AppImage"
	appimagetool_path="$work_dir/appimagetool-${APPIMAGETOOL_VERSION}"
	appimagetool_path+="-${host_arch}.AppImage"
	fetch_pinned "$appimagetool_url" "$appimagetool_path" \
		"$appimagetool_sha256" || exit 1
	chmod +x "$appimagetool_path" || exit 1
fi

# マウントせずに実行するため、ビルドホストにもFUSEは要らない
export APPIMAGE_EXTRACT_AND_RUN=1

# squashfsに固める前にAppDirの権限を揃える
# 複製元のモードをそのまま引き継ぐため、厳しいumaskのビルドでは
# ディレクトリが0700のまま残ることがある
# mksquashfsはその値をそのまま記録するので、後からAppImageを起動した
# 利用者はapp.asar.unpacked/へ入れず、
# Coworkのデーモン自動起動が黙って失敗する
# (起動の可否はfs.existsSync()で判定している)
# 既定はディレクトリと実行ファイルが755、それ以外が644
echo 'Normalizing AppDir permissions...'
find "$appdir_path" -type d -exec chmod 755 {} + || exit 1
find "$appdir_path" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# AppImageを組み立てる
echo 'Building AppImage...'
output_filename="${package_name}-${version}-${architecture}.AppImage"
output_path="$work_dir/$output_filename"

# ARCHはファイル名のamd64/arm64ではなく、
# uname形式の対象アーキテクチャ (x86_64/aarch64) を入れる
# appimagetoolは自分に同梱されたランタイム (ホストのアーキテクチャ) を
# 必ず埋め込むため、対象アーキテクチャ向けの固定版type2ランタイムを
# --runtime-fileで押し込む
case "$architecture" in
	amd64)
		export ARCH='x86_64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_X86_64"
		;;
	arm64)
		export ARCH='aarch64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_AARCH64"
		;;
	*)
		echo "Unsupported target architecture for ARCH: $architecture" >&2
		exit 1
		;;
esac
echo "Using ARCH=$ARCH"

runtime_url='https://github.com/AppImage/type2-runtime/releases/download/'
runtime_url+="${TYPE2_RUNTIME_VERSION}/runtime-${ARCH}"
runtime_path="$work_dir/type2-runtime-${TYPE2_RUNTIME_VERSION}-${ARCH}"
fetch_pinned "$runtime_url" "$runtime_path" "$runtime_sha256" || exit 1

#
# @brief 作業ディレクトリから、固定したランタイムを指定してappimagetoolを動かす
# @param $@ appimagetoolへそのまま渡す引数
# @return appimagetoolの終了コード
# @note appimagetoolの引数解析は、ロケールの文字コードで変換できない
#       --runtime-fileの値を拒否する ("Invalid byte sequence in conversion input")
#       非ASCIIのディレクトリで取得した場合に起きるが、
#       位置引数のパスはそのまま渡される
#       そのため作業ディレクトリへ移動し、常にASCIIになるファイル名で
#       ランタイムを相対指定する
#
run_appimagetool() {
	(cd "$work_dir" && "$appimagetool_path" --no-appstream \
		--runtime-file "./${runtime_path##*/}" "$@")
}

# ローカルビルドでは更新情報を付けない
if [[ ${GITHUB_ACTIONS:-} != 'true' ]]; then
	echo 'Running locally - building AppImage without update information'
	echo '(Update info and zsync files are only generated in GitHub Actions for releases)'

	if ! run_appimagetool "$appdir_path" "$output_path"; then
		echo "Failed to build AppImage using $appimagetool_path" >&2
		exit 1
	fi
	echo "AppImage built successfully: $output_path"
	echo '--- AppImage Build Finished ---'
	exit 0
fi

# GitHub Actionsでは更新情報を埋め込む
echo 'Running in GitHub Actions - embedding update information for automatic updates...'

# 書式 : gh-releases-zsync|<ユーザー>|<リポジトリ>|<タグ>|<ファイル名のパターン>
update_info="gh-releases-zsync|presire|claude-desktop-suse|latest|claude-desktop-*-${architecture}.AppImage.zsync"
echo "Update info: $update_info"

# appimagetoolは.zsyncを自分で書き出す (zsyncmakeは不要)
# 出力先はカレントディレクトリ (run_appimagetoolにより作業ディレクトリ) の
# AppImageの基本名になる
# 古いファイルが下の確認を通ってしまわないよう先に消し、
# その後、従来どおり公開しているAppImageの隣へ移す
zsync_cwd="$work_dir/${output_filename}.zsync"
zsync_file="${output_path}.zsync"
rm -f "$zsync_cwd" "$zsync_file"

if ! run_appimagetool --updateinformation "$update_info" \
	"$appdir_path" "$output_path"; then
	echo "Failed to build AppImage using $appimagetool_path" >&2
	exit 1
fi

echo "AppImage built successfully with embedded update info: $output_path"
if [[ -f $zsync_cwd && $zsync_cwd != "$zsync_file" ]]; then
	mv "$zsync_cwd" "$zsync_file" || exit 1
fi
# 埋め込んだ更新情報は、導入済みのAppImageをこのファイルへ向ける
# これが無いリリースは対処更新を壊すため、欠落は致命的として扱う
if [[ ! -f $zsync_file ]]; then
	echo "zsync file not found at $zsync_file" >&2
	exit 1
fi
echo "zsync file generated: $zsync_file"

echo '--- AppImage Build Finished ---'

exit 0
