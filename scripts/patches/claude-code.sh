#
# @file patches/claude-code.sh
# @brief Claude CodeのバイナリをLinux向けのバンドルから使えるようにする
#
# Claude Codeがホストのプラットフォームを判定する関数getHostPlatformは
# win32しか返さず、Linuxでは例外を投げる
# そのためlinux-arm64とlinux-x64を返す分岐を追加し、
# バンドルに同梱されたClaude Codeのバイナリをそのまま選べるようにする
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js
# 変更するグローバル変数 : なし
#

#
# @brief getHostPlatformにLinuxのプラットフォーム判定を追加する
# @global main_js (参照のみ: メインプロセスのJavaScriptのパス)
# @global patch_noop_declared (本関数から_declare_patch_noop経由で設定する)
# @note 判定が既にある場合は何も変更せず、何も変更しない処理として記録する
#       上流の書式は2種類あるため、新しい書式から順に照合する
#       どちらにも一致しない場合は警告を出すだけで、ビルドは止めない
#
patch_linux_claude_code() {
	local index_js="$main_js"
	if grep -q 'process.platform==="linux".*linux-arm64.*linux-x64' "$index_js"; then
		echo 'Linux claude code binary support already present'
		_declare_patch_noop
		return
	fi

	# 新しい書式 (Claude 1.1.3541以降)
	# getHostPlatformがwin32のアーキテクチャ判定を含む形になった
	# 照合する形 : if(process.platform==="win32")return e==="arm64"?"win32-arm64":"win32-x64";throw new Error(...)
	if grep -qP 'if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s+[$\w]+\s*===\s*"arm64"\s*\?\s*"win32-arm64"\s*:\s*"win32-x64"\s*;\s*throw' "$index_js"; then
		sed -i -E 's/if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s+([[:alnum:]_$]+)\s*===\s*"arm64"\s*\?\s*"win32-arm64"\s*:\s*"win32-x64"\s*;\s*throw/if(process.platform==="win32")return \1==="arm64"?"win32-arm64":"win32-x64";if(process.platform==="linux")return \1==="arm64"?"linux-arm64":"linux-x64";throw/' "$index_js"
		echo 'Added linux claude code support (new arch-aware format)'
	# 古い書式 (Claude 1.1.3363以前)
	# win32のアーキテクチャ判定が無く、常にwin32-x64を返していた
	elif grep -qP 'if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s*"win32-x64"\s*;' "$index_js"; then
		sed -i -E 's/if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s*"win32-x64"\s*;/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' "$index_js"
		echo 'Added linux claude code support (legacy format)'
	else
		echo 'Warning: Could not find getHostPlatform pattern to patch for Linux claude code support'
	fi
}
