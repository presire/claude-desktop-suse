#!/usr/bin/env bash

#
# @file rpm.sh
# @brief ステージング済みのアプリからRPMパッケージを組み立てる
#
# メインスクリプトから受け取った値でrpmbuild向けのspecを生成し、
# アイコン・デスクトップエントリ・ランチャーをまとめてパッケージに入れる
# 生成物はファイル名を統一するため作業ディレクトリ直下へ移し替える
#
# 使い方 : rpm.sh <version> <architecture> <work_dir> <app_staging_dir>
#          <package_name> <maintainer> <description> [install_prefix]
# 終了コード : 0 = RPMを生成できた、1 = 引数不正または生成の失敗
#

# メインスクリプトから受け取る引数
version="$1"
architecture="$2"
work_dir="$3"           # 作業ディレクトリの最上位 (例 : ./build)
app_staging_dir="$4"    # アプリ一式を用意したディレクトリ
package_name="$5"
# 6番目のmaintainerはspecでは使わないが、引数の並びを揃えるため受け取る
description="$7"
install_prefix="${8:-/usr/lib}"

# 版番号は生成するランチャーの--versionの即時応答とrpmのVersionの
# 両方に入るため、不正な値はパッケージを作る前に弾いて上流で止める
if [[ -z $version || ! $version =~ ^[0-9]+(\.[0-9]+)+(-[0-9]+(\.[0-9]+)*)?$ ]]; then
	echo "Error: invalid build version '$version'" >&2
	echo 'Expected a non-empty version starting with a digit' >&2
	exit 1
fi

echo '--- Starting RPM Package Build ---'
echo "Version: $version"

# rpmのVersionにはハイフンを入れられないため、版にハイフンがあれば
# ハイフンの前をversion、後ろをreleaseとして分ける
# 例 : "1.1.799-1.3.3" は rpm_version="1.1.799"、rpm_release="1.3.3" になる
if [[ $version == *-* ]]; then
	rpm_version="${version%%-*}"
	rpm_release="${version#*-}"
	echo "RPM Version: $rpm_version"
	echo "RPM Release: $rpm_release"
else
	rpm_version="$version"
	rpm_release="1"
fi
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"
echo "Install Prefix: $install_prefix"

# パッケージの対象アーキテクチャをrpmの名前に変換する
case "$architecture" in
	amd64) rpm_arch='x86_64' ;;
	arm64) rpm_arch='aarch64' ;;
	*)
		echo "Unsupported architecture for RPM: $architecture" >&2
		exit 1
		;;
esac

# rpmbuildのディレクトリ構成を置く場所
rpmbuild_dir="$work_dir/rpmbuild"

# 前回の生成物が混ざらないよう、ディレクトリごと作り直す
rm -rf "$rpmbuild_dir"

# rpmbuildが必要とするディレクトリをまとめて作成する
echo "Creating RPM build structure in $rpmbuild_dir..."
mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} || exit 1

# launcher-common.shなどを参照するため、このスクリプトの場所を控える
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# specが参照するファイルを先に集めておくステージング領域
staging_dir="$work_dir/rpm-staging"
rm -rf "$staging_dir"
mkdir -p "$staging_dir" || exit 1

# AppStreamのメタ情報をステージングする (インストール先は%filesで指定する)
metainfo_name='io.github.presire.claude-desktop-suse.metainfo.xml'
cp "$script_dir/$metainfo_name" "$staging_dir/$metainfo_name" || exit 1

# デスクトップエントリを生成する
echo 'Creating desktop entry...'
cat > "$staging_dir/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=$STARTUP_WM_CLASS
EOF

# ランチャースクリプトを生成する
echo 'Creating launcher script...'
cat > "$staging_dir/claude-desktop" << EOF
#!/usr/bin/env bash

# Source shared launcher library
source "$install_prefix/$package_name/launcher-common.sh"

# Handle --doctor flag before anything else
if [[ "\${1:-}" == '--doctor' ]]; then
	local_electron_path="$install_prefix/$package_name/node_modules/electron/dist/electron"
	run_doctor "\$local_electron_path" 'rpm'
	exit \$?
fi

# --version fast path: print baked version and exit 0 before any
# logging, display detection, D-Bus/sandbox, or Electron launch.
if [[ "\${1:-}" == '--version' ]]; then
	echo "$package_name $version"
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
heal_autostart_entry '/usr/bin/$package_name'
backup_user_config

# Log startup info
log_message '--- Claude Desktop Launcher Start ---'
log_message "Timestamp: \$(date)"
log_message "Arguments: \$@"
log_session_env

# Check for display
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Claude Desktop requires a graphical desktop environment.' >&2
	echo 'Please run from within an X11 or Wayland session, not from a TTY.' >&2
	exit 1
fi

# Detect display backend
detect_display_backend
if [[ \$is_wayland == true ]]; then
	log_message 'Wayland detected'
fi
ensure_portal_app_id_entry '/usr/bin/$package_name' 'claude-desktop' 'claude-desktop'

# Determine Electron executable path
electron_exec='electron'
local_electron_path="$install_prefix/$package_name/node_modules/electron/dist/electron"
if [[ -f \$local_electron_path ]]; then
	electron_exec="\$local_electron_path"
	log_message "Using local Electron: \$electron_exec"
else
	if command -v electron &> /dev/null; then
		log_message "Using global Electron: \$electron_exec"
	else
		log_message 'Error: Electron executable not found'
		if command -v zenity &> /dev/null; then
			zenity --error \
				--text='Claude Desktop cannot start because the Electron framework is missing.'
		elif command -v kdialog &> /dev/null; then
			kdialog --error \
				'Claude Desktop cannot start because the Electron framework is missing.'
		fi
		exit 1
	fi
fi

# Build electron args
build_electron_args 'rpm'

# The bundled Electron auto-loads resources/app.asar; passing it again
# reaches the app as a file to open (claude-desktop-debian #696/#700).
# Only a PATH-resolved electron boots default_app and needs the path.
if [[ \$electron_exec == 'electron' ]]; then
	electron_args+=("$install_prefix/$package_name/node_modules/electron/dist/resources/app.asar")
fi

# Change to application directory
app_dir="$install_prefix/$package_name"
log_message "Changing directory to \$app_dir"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }

# Execute Electron. The launcher stays alive as Electron's parent so
# it can filter output into the log and reap Cowork/helper processes
# the app leaves behind when it exits.
log_message "Executing: \$electron_exec \${electron_args[*]} \$*"
run_electron_and_cleanup "\$electron_exec" "\${electron_args[@]}" "\$@"
EOF
chmod +x "$staging_dir/claude-desktop"

# specファイルを生成する
echo 'Creating RPM spec file...'

# アイコンの導入コマンドと%filesの一覧を組み立てる
icon_install_cmds=""
icon_file_entries=""
# icotoolはclaude.icoの中の位置でファイル名を付けるが、
# その順序はリリースごとに変わるためサイズの接尾辞だけで照合する
for size in 16 24 32 48 64 256; do
	icon_source_path=''
	for candidate in "$work_dir"/claude_*_"${size}x${size}"x32.png; do
		[[ -f $candidate ]] && icon_source_path="$candidate" && break
	done
	if [[ -n $icon_source_path ]]; then
		icon_install_cmds+="mkdir -p %{buildroot}/usr/share/icons/hicolor/${size}x${size}/apps
install -Dm 644 $icon_source_path %{buildroot}/usr/share/icons/hicolor/${size}x${size}/apps/claude-desktop.png
"
		icon_file_entries+="/usr/share/icons/hicolor/${size}x${size}/apps/claude-desktop.png
"
	fi
done

cat > "$rpmbuild_dir/SPECS/$package_name.spec" << SPECEOF
Name:           $package_name
Version:        $rpm_version
Release:        $rpm_release%{?dist}
Summary:        $description

License:        Proprietary
URL:            https://claude.ai

# Disable automatic dependency scanning (we bundle everything)
AutoReqProv:    no

# Disable debug package generation
%define debug_package %{nil}

# Disable binary stripping (Electron binaries don't like it)
%define __strip /bin/true

# Disable build ID generation (avoids issues with Electron binaries)
%define _build_id_links none

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on openSUSE and SUSE Linux Enterprise distributions.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}$install_prefix/$package_name
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/bin

# Install icons
$icon_install_cmds

# Copy application files
cp -r $app_staging_dir/node_modules %{buildroot}$install_prefix/$package_name/
cp $app_staging_dir/app.asar %{buildroot}$install_prefix/$package_name/node_modules/electron/dist/resources/
cp -r $app_staging_dir/app.asar.unpacked %{buildroot}$install_prefix/$package_name/node_modules/electron/dist/resources/

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
cp $(dirname "$script_dir")/launcher-common.sh %{buildroot}$install_prefix/$package_name/
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" %{buildroot}$install_prefix/$package_name/launcher-common.sh
cp $(dirname "$script_dir")/doctor.sh %{buildroot}$install_prefix/$package_name/

# Install desktop entry
install -Dm 644 $staging_dir/claude-desktop.desktop %{buildroot}/usr/share/applications/claude-desktop.desktop

# Install launcher script
install -Dm 755 $staging_dir/claude-desktop %{buildroot}/usr/bin/claude-desktop

# Install AppStream metainfo (GNOME Software / KDE Discover)
install -Dm 644 $staging_dir/$metainfo_name %{buildroot}/usr/share/metainfo/$metainfo_name

# Normalize file modes. The cp -r above honors the build umask, and the
# "-" first field of %defattr ships buildroot *file* modes verbatim
# (only directory modes are forced to 0755), so a umask-077 build would
# package an unreadable app.asar and a non-executable electron binary.
# Must run before the chrome-sandbox chmod below so 4755 survives.
find %{buildroot}$install_prefix/$package_name -type f -exec chmod u=rwX,go=rX {} +

chmod 4755 %{buildroot}$install_prefix/$package_name/node_modules/electron/dist/chrome-sandbox

%post
# Update desktop database for MIME types
update-desktop-database /usr/share/applications &> /dev/null || true

%postun
# Update desktop database after removal
update-desktop-database /usr/share/applications &> /dev/null || true

%files
%defattr(-, root, root, 0755)
%attr(755, root, root) /usr/bin/claude-desktop
$install_prefix/$package_name
/usr/share/applications/claude-desktop.desktop
$icon_file_entries
/usr/share/metainfo/$metainfo_name
SPECEOF

echo 'RPM spec file created'

# RPMパッケージを組み立てる
echo 'Building RPM package...'


rpmbuild_log="$work_dir/rpmbuild.log"
rpmbuild --define "_topdir $rpmbuild_dir" \
	--define "_rpmdir $work_dir" \
	--target "$rpm_arch" \
	-bb "$rpmbuild_dir/SPECS/$package_name.spec" 2>&1 | tee "$rpmbuild_log"
if (( PIPESTATUS[0] != 0 )); then
	echo 'Failed to build RPM package' >&2
	exit 1
fi

if grep -qF 'File listed twice' "$rpmbuild_log"; then
	echo 'rpmbuild emitted "File listed twice" — %files has overlapping listings' >&2
	grep -F 'File listed twice' "$rpmbuild_log" >&2
	exit 1
	fi

# 生成されたRPMはサブディレクトリに入るため、探して移す
rpm_file=$(find "$work_dir" -name "${package_name}-${rpm_version}*.rpm" -type f | head -n 1)
if [[ -z $rpm_file ]]; then
	echo 'Could not find built RPM file' >&2
	exit 1
fi

# ファイル名を揃えるため、作業ディレクトリ直下の一定の名前へ改名する
# 名前に使うのはハイフン分割前の$versionで、従来の名前と互換になる
final_rpm="$work_dir/${package_name}-${version}-1.${rpm_arch}.rpm"
if [[ $rpm_file != "$final_rpm" ]]; then
	mv "$rpm_file" "$final_rpm" || exit 1
fi

echo "RPM package built successfully: $final_rpm"
echo '--- RPM Package Build Finished ---'

exit 0
