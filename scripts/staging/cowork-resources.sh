#
# @file cowork-resources.sh
# @brief Coworkの実行時に使う資源をElectronのresourcesディレクトリへ複製する
#
# 対象はプラグイン用のシムスクリプト、ブラウザ連携のシム、KVMゲストのSDKに
# 使うアーキテクチャ別のsmol-bin VHDX、そしてThird-Party Inferenceの設定画面が
# 使うapp://プロトコルハンドラ向けのion-dist静的資産である
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : claude_extract_dir, electron_resources_dest,
#   architecture
# 変更するグローバル変数 : なし
#

#
# @brief Cowork用の資源をresourcesディレクトリへ複製する
# @global claude_extract_dir (参照のみ) Windows版の展開結果の置き場所
# @global electron_resources_dest (参照のみ) 複製先のresourcesディレクトリ
# @global architecture (参照のみ) smol-bin VHDXのアーキテクチャを選ぶ
# @note 資源が同梱されていない版もあるため、見つからない場合は警告だけで続行する
#
copy_cowork_resources() {
	section_header 'Cowork Resources'

	local resources_src="$claude_extract_dir/lib/net45/resources"

	# MCPプラグインのサンドボックス化にアプリが使うcowork-plugin-shim.shを複製する
	# 上流のファイルはWindowsの.exeを展開するとCRLFの改行で出てくるが、
	# bashの実行はCRLFのshebangやコマンド行を受け付けない (issue #499)
	local shim_src="$resources_src/cowork-plugin-shim.sh"
	local shim_dest="$electron_resources_dest/cowork-plugin-shim.sh"
	if [[ -f $shim_src ]]; then
		cp "$shim_src" "$shim_dest"
		sed -i 's/\r$//' "$shim_dest"
		chmod +x "$shim_dest"
		echo "Copied cowork-plugin-shim.sh"
	else
		echo "Warning: cowork-plugin-shim.sh not found at $shim_src"
	fi

	# 3.x以降はブラウザ連携のシムも複製する
	# アプリはresourcesからこれを読み、Claude Codeのセッションで$BROWSERとして
	# 設定するため、「URLを開く」要求はデスクトップアプリ経由で振り分けられる
	# 古いリリースには同梱されないので、ある場合だけ扱う
	local browser_shim_src="$resources_src/claude-browser-shim.js"
	if [[ -f $browser_shim_src ]]; then
		cp "$browser_shim_src" "$electron_resources_dest/" || exit 1
		echo 'Copied claude-browser-shim.js'
	fi

	# smol-bin VHDX (KVMゲストVMのSDKバイナリ) を複製する
	# アプリは起動時にこれをresourcesからバンドル先へコピーするが、
	# その処理はwin32限定なのでindex.jsへのパッチでLinuxでも動くようにしている
	# ファイル名はsmol-bin.{arch}.vhdxで、archはx64かarm64になる
	local smol_arch='x64'
	if [[ $architecture == 'arm64' ]]; then
		smol_arch='arm64'
	fi
	local smol_vhdx="$resources_src/smol-bin.${smol_arch}.vhdx"
	if [[ -f $smol_vhdx ]]; then
		cp "$smol_vhdx" \
			"$electron_resources_dest/smol-bin.${smol_arch}.vhdx"
		echo "Copied smol-bin.${smol_arch}.vhdx"
	else
		echo "Warning: smol-bin VHDX not found at $smol_vhdx"
		echo "KVM Cowork will rely on virtiofs for SDK access"
	fi

	# ion-distの静的資産を複製する
	# アプリはprocess.resourcesPath/ion-distを起点にapp://プロトコル
	# ハンドラを登録するが、資産が無いとThird-Party Inferenceの設定画面が
	# ERR_UNEXPECTEDで読み込みに失敗する (issue #488)
	# 4.xではion-dist.asarとして同梱され、アプリは
	# process.resourcesPath/ion-dist.asarから読むため通常のファイルである必要がある
	local ion_dist_src="$resources_src/ion-dist"
	if [[ -f $ion_dist_src.asar ]]; then
		cp "$ion_dist_src.asar" "$electron_resources_dest/ion-dist.asar" || exit 1
		echo 'Copied ion-dist.asar'
	elif [[ -d $ion_dist_src ]]; then
		cp -a "$ion_dist_src" "$electron_resources_dest/ion-dist"
		echo 'Copied ion-dist'
	else
		echo "Warning: ion-dist not found at $ion_dist_src" \
			'— Third-Party Inference setup will fail'
	fi

	section_footer 'Cowork Resources'
}
