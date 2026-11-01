#
# @file icons.sh
# @brief exeからアイコンを取り出し、トレイアイコンをLinuxのパネルで見える形に整える
#
# wrestoolとicotoolでアイコンを抽出し、BrowserWindowのタイトルバー用の
# アプリアイコンをresourcesへ複製する
# --dark指定時は既定のトレイアイコンを暗色版へ差し替え、
# 最後にトレイアイコンを完全不透明のPNGへ変換してパネル上で消えないようにする
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : claude_extract_dir, project_root, work_dir,
#   electron_resources_dest, dark_tray_icons
# 変更するグローバル変数 : なし
#

#
# @brief exeからアイコンを抽出し、タイトルバー用とトレイ用の画像を配置する
# @global claude_extract_dir (参照のみ) claude.exeと資源の置き場所
# @global project_root (参照のみ) 処理の終了時に戻る先
# @global work_dir (参照のみ) 抽出したPNGの置き場所
# @global electron_resources_dest (参照のみ) アイコンの複製先
# @global dark_tray_icons (参照のみ) trueなら暗色版のトレイアイコンを既定にする
# @note claude.exeやアイコンの抽出に失敗した場合はexit 1で中断する
#       トレイアイコン群やImageMagickが無い場合は警告だけで続行する
#
process_icons() {
	section_header 'Icon Processing'

	cd "$claude_extract_dir" || exit 1
	local exe_path='lib/net45/claude.exe'
	if [[ ! -f $exe_path ]]; then
		echo "Cannot find claude.exe at expected path: $claude_extract_dir/$exe_path" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo "Extracting application icons from $exe_path..."
	if ! wrestool -x -t 14 "$exe_path" -o claude.ico; then
		echo 'Failed to extract icons from exe' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if ! icotool -x claude.ico; then
		echo 'Failed to convert icons' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	cp claude_*.png "$work_dir/" || exit 1
	echo "Application icons extracted and copied to $work_dir"

	cd "$project_root" || exit 1

	# BrowserWindowのタイトルバーに出すアイコンをresourcesへ複製する
	# 256x256があればそれを使い、無ければ最も大きいものを代わりにする
	local app_icon=''
	for candidate in "$work_dir"/claude_*_256x256x32.png; do
		[[ -f $candidate ]] && app_icon="$candidate" && break
	done
	if [[ -z $app_icon ]]; then
		app_icon=$(ls -S "$work_dir"/claude_*.png 2>/dev/null | head -1)
	fi
	if [[ -n $app_icon ]]; then
		cp "$app_icon" "$electron_resources_dest/claude-desktop.png"
		echo "Copied app icon to resources: claude-desktop.png"
	else
		echo 'Warning: No app icon found for BrowserWindow titlebar'
	fi

	# トレイアイコンはアプリがresourcesから読むため、先に一式を複製する
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying and processing tray icon files for Linux...'
	if [[ ! -d $claude_locale_src ]]; then
		echo "Warning: Claude resources directory not found at $claude_locale_src"
		section_footer 'Icon Processing'
		return
	fi

	cp "$claude_locale_src/Tray"* "$electron_resources_dest/" 2>/dev/null || \
		echo 'Warning: No tray icon files found'

	# --dark指定時は既定のトレイアイコンを暗色版で置き換える
	# アプリが参照するのはDarkの付かない名前なので、複製して名前を揃える
	if [[ $dark_tray_icons == true ]]; then
		echo 'Replacing default tray icons with dark-mode variants...'
		local base dark
		for dark in "$electron_resources_dest"/TrayIconTemplate-Dark*.png; do
			[[ ! -f $dark ]] && continue
			base="${dark/-Dark/}"
			cp "$dark" "$base"
			echo "  $(basename "$dark") -> $(basename "$base")"
		done
		local dark_ico="$electron_resources_dest/Tray-Win32-Dark.ico"
		local base_ico="$electron_resources_dest/Tray-Win32.ico"
		if [[ -f $dark_ico ]]; then
			cp "$dark_ico" "$base_ico" || exit 1
			echo "  $(basename "$dark_ico") -> $(basename "$base_ico")"
		fi
		local dark_linux="$electron_resources_dest/TrayIconLinux-Dark.png"
		local base_linux="$electron_resources_dest/TrayIconLinux.png"
		if [[ -f $dark_linux ]]; then
			cp "$dark_linux" "$base_linux" || exit 1
			echo "  $(basename "$dark_linux") -> $(basename "$base_linux")"
		fi
		echo 'Dark-mode tray icons installed as default'
	fi

	# ImageMagickはmagick (7系) かconvert (6系) のどちらかで入るため、両方を見る
	local magick_cmd=''
	command -v magick &> /dev/null && magick_cmd='magick'
	[[ -z $magick_cmd ]] && command -v convert &> /dev/null && magick_cmd='convert'

	if [[ -z $magick_cmd ]]; then
		echo 'Warning: ImageMagick not found - tray icons may appear invisible'
		echo 'Tray icon files copied (unprocessed)'
		section_footer 'Icon Processing'
		return
	fi

	echo "Processing tray icons for Linux visibility (using $magick_cmd)..."
	local icon_file icon_name
	for icon_file in "$electron_resources_dest"/TrayIconTemplate*.png; do
		[[ ! -f $icon_file ]] && continue
		icon_name=$(basename "$icon_file")
		# Linuxのパネルは半透明のアイコンを背景に溶かしてしまうため、
		# アルファ値を0か1の二値に落として完全不透明にする
		if "$magick_cmd" "$icon_file" -channel A -fx 'a>0?1:0' +channel \
			"PNG32:$icon_file" 2>/dev/null; then
			echo "  Processed $icon_name (100% opaque)"
		else
			echo "  Failed to process $icon_name"
		fi
	done
	echo 'Tray icon files copied and processed'

	section_footer 'Icon Processing'
}
