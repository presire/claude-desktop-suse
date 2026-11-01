#
# @file wco-shim.sh
# @brief WCO(Window Controls Overlay、ウィンドウ枠のボタン領域)用のシムを
#        BrowserViewのプリロードへ埋め込む
#
# Linuxのトップバー風の操作を枠なしウィンドウでも成立させるための処理
# 実行用ではなく、build.shからsourceして使う
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : source_dir
# 変更するグローバル変数 : なし
#

#
# @brief WCOシムのソースをmainView.jsの先頭へ直接埋め込む
# @global source_dir (参照のみ) シムの元ファイル scripts/wco-shim.js を持つリポジトリ
# @note mainView.jsが見つからない場合は1で終了する
# @note 埋め込み済みかは __claude_wco_shim の有無で判定し、再実行しても二重に適用されない
#
patch_wco_shim() {
	echo '##############################################################'
	echo 'Inlining WCO shim into mainView.js (Linux topbar workaround)'

	local main_view='app.asar.contents/.vite/build/mainView.js'

	if [[ ! -f $main_view ]]; then
		echo "Error: mainView.js not found at $main_view." >&2
		exit 1
	fi

	if grep -q '__claude_wco_shim' "$main_view"; then
		echo 'mainView.js already has WCO shim, skipping inject'
		echo '##############################################################'
		return 0
	fi

	# サンドボックス化されたプリロードが読み込めるモジュールは
	# 許可リスト(electron、ipcRenderer、contextBridge、webFrameなど)に限られる
	# 兄弟ファイルへの相対requireはmodule not foundで失敗し、
	# プリロード全体が中断してしまう
	# その場合desktopBootFeaturesやmainViewがexposeInMainWorldで
	# 公開する残りのAPIも一緒に失われる
	# そのためrequireで読み込まず、シムのソースをmainView.jsの
	# 先頭へ直接埋め込む
	local shim_content
	shim_content=$(cat "$source_dir/scripts/wco-shim.js")
	local original
	original=$(cat "$main_view")
	printf '%s\n%s' "$shim_content" "$original" > "$main_view"
	echo 'Inlined WCO shim at top of mainView.js'
	echo '##############################################################'
}
