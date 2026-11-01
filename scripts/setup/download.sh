#
# @file download.sh
# @brief Claudeインストーラの取得と展開を行い、nupkgからバージョンを確定する
#
# 取得経路は2つある
#   1. --exe でローカルのインストーラを指定した場合は、.exeをコピーして
#      7zで展開し、中にあるnupkgを探す
#   2. nupkgを直接取得する場合は、resolve_latest_url()が決めたURLから
#      ダウンロードし、RELEASESのSHA-1と、固定値または--claude-sha256の
#      SHA-256で検証する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : work_dir, claude_nupkg_filename, claude_nupkg_url,
#   claude_nupkg_sha1, claude_nupkg_sha256, local_exe_path, project_root,
#   release_tag, architecture
# 変更するグローバル変数 : claude_extract_dir, version,
#   claude_nupkg_filename (--exeのときに実ファイル名で上書きする)
#

#
# @brief Claudeのインストーラを取得して展開し、同梱バージョンを読み取る
# @global work_dir (参照のみ) 展開先とインストーラの複製先に使う
# @global local_exe_path (参照のみ) 指定時はローカルの.exeから取得する
# @global claude_nupkg_url, claude_nupkg_filename (参照のみ) 直接取得するnupkg
# @global claude_nupkg_sha1 (参照のみ) RELEASESに載っている検証用ハッシュ
# @global claude_nupkg_sha256 (参照のみ) 固定値または--claude-sha256の検証用ハッシュ
# @global release_tag (参照のみ) 指定時はラッパー版をパッケージ版に足す
# @global project_root (参照のみ) 処理の終了時に戻る先
# @global claude_extract_dir 展開先ディレクトリを設定する
# @global version 検出したClaudeのバージョンを設定する
# @note 取得、検証、展開のいずれかに失敗した場合はexit 1で中断する
#
download_claude_installer() {
	section_header 'Download Claude Installer'

	claude_extract_dir="$work_dir/claude-extract"
	mkdir -p "$claude_extract_dir" || exit 1

	if [[ -n $local_exe_path ]]; then
		# ローカルの.exeを使う場合は、先に展開して中からnupkgを探す
		echo "Using local Claude installer: $local_exe_path"
		if [[ ! -f $local_exe_path ]]; then
			echo "Local installer file not found: $local_exe_path" >&2
			exit 1
		fi

		local claude_exe_path="$work_dir/$(basename "$local_exe_path")"
		cp "$local_exe_path" "$claude_exe_path" || exit 1
		echo 'Local installer copied to build directory'

		echo "Extracting exe to find nupkg..."
		if ! 7z x -y "$claude_exe_path" -o"$claude_extract_dir"; then
			echo 'Failed to extract installer exe' >&2
			exit 1
		fi

		cd "$claude_extract_dir" || exit 1
		local nupkg_path
		nupkg_path=$(find . -maxdepth 1 -name 'AnthropicClaude-*-full.nupkg' | head -1)
		if [[ -z $nupkg_path ]]; then
			echo "Could not find AnthropicClaude nupkg in extracted exe" >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		claude_nupkg_filename=$(basename "$nupkg_path")
		echo "Found nupkg in exe: $claude_nupkg_filename"
	else
		# nupkgを直接取得する
		echo "Downloading $claude_nupkg_filename for $architecture..."
		echo "URL: $claude_nupkg_url"
		cd "$claude_extract_dir" || exit 1
		if ! wget -O "$claude_nupkg_filename" "$claude_nupkg_url"; then
			echo "Failed to download nupkg from $claude_nupkg_url" >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo "Download complete: $claude_nupkg_filename"

		if [[ -n $claude_nupkg_sha1 ]]; then
			if ! verify_sha1 "$claude_nupkg_filename" \
				"$claude_nupkg_sha1" 'Claude nupkg'; then
				cd "$project_root" || exit 1
				exit 1
			fi
		fi
	fi

	# --exeと直接取得のどちらでもnupkgはここに残るため、
	# 固定値または--claude-sha256のSHA-256はこの位置で検証する
	# RELEASESにハッシュが載らない経路もこれで埋まる
	# (期待値が空の場合は固定値が無い版を選んだという意味なので飛ばす)
	if [[ -n $claude_nupkg_sha256 ]]; then
		if ! verify_sha256 "$claude_nupkg_filename" \
			"$claude_nupkg_sha256" 'Claude nupkg'; then
			cd "$project_root" || exit 1
			exit 1
		fi
	fi

	# バージョンはnupkgのファイル名から読み取る
	version=$(echo "$claude_nupkg_filename" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
	if [[ -z $version ]]; then
		echo "Could not extract version from nupkg filename: $claude_nupkg_filename" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Detected Claude version: $version"

	# --release-tagがある場合はラッパーの版を後ろに足して、
	# 同じClaude版でもラッパーの改版を区別できるようにする
	# (例 : v1.3.2+claude1.1.799 から 1.3.2 を取り出す)
	if [[ -n $release_tag ]]; then
		local wrapper_version
		wrapper_version=$(echo "$release_tag" | LC_ALL=C grep -oP '^v\K[0-9]+\.[0-9]+\.[0-9]+(?=\+claude)')
		if [[ -n $wrapper_version ]]; then
			version="${version}-${wrapper_version}"
			echo "Package version with wrapper suffix: $version"
		else
			echo "Warning: Could not extract wrapper version from release tag: $release_tag" >&2
		fi
	fi

	echo "Extracting nupkg..."
	if ! 7z x -y "$claude_nupkg_filename"; then
		echo 'Failed to extract nupkg' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo 'Resources extracted from nupkg'

	cd "$project_root" || exit 1
}
