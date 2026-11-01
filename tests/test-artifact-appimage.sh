#!/usr/bin/env bash
#
# @file test-artifact-appimage.sh
# @brief .AppImageの成果物を展開して、中身と起動が期待どおりかを確かめる
#
# 引数のディレクトリから最初の.AppImageを見つけ、実行できることと
# ELF形式であることを確かめてから、FUSEでのマウント、展開したAppDirの構成、
# ウィンドウクラス、asarの中身、doctorと[--version]、
# Xvfb上での起動までを順に検証する
#
# 使い方 : test-artifact-appimage.sh <成果物のあるディレクトリ>
# 終了コード : 0 = すべての検査が合格、1 = 失敗あり
#              SKIPはそのまま記録し、ARTIFACT_FAIL_ON_SKIP=1なら失敗にする
#
# 注意 : 導入を伴わないため、ホストのパッケージには触れない
#        FUSEが使えない環境ではマウントの検査だけをSKIPにする
#

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
if [[ ! -d $artifact_dir || ! -r $artifact_dir ]]; then
	printf '[FAIL] Artifact directory is not readable: %s\n' "$artifact_dir" >&2
	exit 1
fi
artifact_dir="$(cd "$artifact_dir" && pwd)" || exit 1
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

#
# @brief AppImageのマウントをパス指定で外す
# @note 実行環境のFUSE側のデーモンは自前のセッションへ分離する
#       そのため--appimage-mountのプロセスを止めても、マウントが残ることがある
#       マウントを外せばデーモンは自然に終了する
#
_unmount_appimage() {
	[[ -n ${mount_point:-} ]] || return 0
	if mountpoint -q "$mount_point" 2>/dev/null; then
		fusermount3 -u "$mount_point" 2>/dev/null \
			|| fusermount -u "$mount_point" 2>/dev/null
	fi
	mount_point=''
}

#
# @brief AppImageの検査で作ったものを、1か所で片付ける
# @note 中断された起動と一時ディレクトリは_launch_smoke_cleanupが片付ける
#       マウントと展開ディレクトリはAppImage固有なので、ここで扱う
#
_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${mount_pid:-} ]] && kill "$mount_pid" 2>/dev/null
	_unmount_appimage
	[[ -n ${mount_log:-} ]] && rm -f "$mount_log"
	[[ -n ${extract_dir:-} ]] && rm -rf "$extract_dir"
}
trap _cleanup EXIT INT TERM

component_id='io.github.presire.claude-desktop-suse' # desktopエントリとアイコンの名前 (実行時のウィンドウクラスにもなる)

# AppImageを探す (.zsyncは更新用の補助ファイルなので除く)
appimage_file=$(find "$artifact_dir" -name '*.AppImage' \
	! -name '*.zsync' -type f | head -1)
if [[ -z $appimage_file ]]; then
	skip "No AppImage artifact available in $artifact_dir"
	print_summary
	exit 0
fi
pass "Found AppImage: $(basename "$appimage_file")"

# --- 実行権限 ---
chmod +x "$appimage_file"
assert_executable "$appimage_file"

# --- ファイル形式 ---
file_type=$(file -b "$appimage_file")
if [[ $file_type == *"ELF"* ]] || [[ $file_type == *"executable"* ]]; then
	pass "AppImage is an ELF executable"
else
	fail "AppImage file type unexpected: $file_type"
fi

# --- FUSEでのマウント ---
# AppImageは静的なtype2ランタイムを内蔵し、FUSEを自分で組み込む
# そのため必要なのはfusermount3だけで、libfuse2は要らない
# --appimage-mountはマウント先を表示してから、止められるまでマウントを保持する
# その下にAppRunが現れれば、単に展開したのではなく実際にマウントできたと分かる
if ! command -v fusermount3 &>/dev/null \
	&& ! command -v fusermount &>/dev/null; then
	skip "fusermount3/fusermount not installed (zypper install fuse3)"
elif [[ ! -c /dev/fuse || ! -r /dev/fuse ]]; then
	skip "/dev/fuse is not available in this environment"
else
	mount_log=$(mktemp)
	"$appimage_file" --appimage-mount > "$mount_log" 2>&1 &
	mount_pid=$!
	mount_point=''
	# マウントが終わるまで最大10秒待ち、AppRunが現れた時点で成功とみなす
	for _ in {1..100}; do
		mount_point=$(head -1 "$mount_log")
		[[ -n $mount_point && -x $mount_point/AppRun ]] && break
		sleep 0.1
	done
	if [[ -n $mount_point && -x $mount_point/AppRun ]]; then
		pass "AppImage mounts via FUSE ($mount_point)"
	else
		fail "AppImage did not mount: $(head -3 "$mount_log" | tr '\n' ' ')"
	fi
	kill "$mount_pid" 2>/dev/null
	wait "$mount_pid" 2>/dev/null
	mount_pid=''
	_unmount_appimage
fi

# --- AppImageの展開 ---
extract_dir=$(mktemp -d)
cd "$extract_dir" || exit 1
"$appimage_file" --appimage-extract >/dev/null 2>&1
appdir="$extract_dir/squashfs-root"

if [[ -d $appdir ]]; then
	pass "--appimage-extract succeeded"
else
	fail "--appimage-extract failed (no squashfs-root)"
	print_summary
fi

# --- AppDirの構成 ---
assert_file_exists "$appdir/AppRun"
assert_executable "$appdir/AppRun"

# 最上位のdesktopエントリ
if [[ -f "$appdir/${component_id}.desktop" ]]; then
	pass "Top-level .desktop file exists"
	assert_contains "$appdir/${component_id}.desktop" \
		'Type=Application' "Desktop entry Type correct"
	assert_contains "$appdir/${component_id}.desktop" \
		'Exec=AppRun' "Desktop entry Exec points to AppRun"
	assert_contains "$appdir/${component_id}.desktop" \
		"StartupWMClass=$component_id" \
		"Desktop entry StartupWMClass matches appimage desktopName"
else
	fail "No top-level .desktop file"
fi

# 標準の場所にあるdesktopエントリ
assert_file_exists \
	"$appdir/usr/share/applications/${component_id}.desktop"

# 最上位のアイコン
if [[ -f "$appdir/${component_id}.png" ]]; then
	pass "Top-level icon present"
else
	fail "No top-level icon found"
fi

# .DirIcon
assert_file_exists "$appdir/.DirIcon"

# AppStreamのメタデータ
# project_licenseは、利用者が起動するClaudeアプリ自身のライセンスを書く
# RPMに載せているmetainfoと揃えるためである
appdata="$appdir/usr/share/metainfo/${component_id}.appdata.xml"
assert_file_exists "$appdata"
assert_contains "$appdata" \
	'<project_license>LicenseRef-proprietary</project_license>' \
	"AppStream project_license is LicenseRef-proprietary"
assert_contains "$appdata" \
	"<icon type=\"stock\">${component_id}</icon>" \
	"AppStream metainfo names the stock icon"
if command -v appstreamcli &> /dev/null; then
	assert_command_succeeds "appstreamcli accepts the metainfo" \
		appstreamcli validate --no-net "$appdata"
else
	skip "appstreamcli not installed (zypper install AppStream)"
fi

# --- Electronの実行ファイル ---
electron_path="$appdir/usr/lib/node_modules/electron/dist/electron"
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# --- ランチャーのライブラリ ---
assert_file_exists "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# --- AppRunの内容 ---
assert_contains "$appdir/AppRun" 'launcher-common.sh' \
	"AppRun sources launcher-common.sh"
assert_contains "$appdir/AppRun" 'run_doctor' \
	"AppRun references run_doctor"
assert_contains "$appdir/AppRun" 'build_electron_args' \
	"AppRun calls build_electron_args"
assert_contains "$appdir/AppRun" 'run_electron_and_cleanup' \
	"AppRun keeps Electron as a child (run_electron_and_cleanup)"

# --- アプリの中身 (asar) ---
resources_dir="$appdir/usr/lib/node_modules/electron/dist/resources"
validate_app_contents "$resources_dir" "$appdir/${component_id}.desktop"
assert_no_pe_native_modules "$resources_dir/app.asar.unpacked"

doctor_exit=0
"$appimage_file" --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- ランチャーの[--version] (起動しない経路) ---
# 焼き込まれた版は成果物のファイル名から取る
# (claude-desktop-<version>-<arch>.AppImage)
appimage_version="$(basename "$appimage_file")"
appimage_version="${appimage_version#claude-desktop-}"
appimage_version="${appimage_version%.AppImage}"
appimage_version="${appimage_version%-*}"
run_version_flag_test 'AppImage' \
	"claude-desktop $appimage_version" exact "$appimage_file"

# --- 画面なしでの起動確認 ---
# 取り残しの掃除はCIでだけ行う
# 手元では'mount_claude'が開発中のClaude Desktop AppImageの実行にも一致するため
run_launch_smoke_test 'AppImage' '' "$appimage_file"

# --- 後片付け ---
rm -rf "$extract_dir"

print_summary
