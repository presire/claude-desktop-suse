#
# @file locales.sh
# @brief Claudeのi18n用JSONをElectronのresourcesディレクトリへ複製する
#
# 上流のバンドルに言語ファイルが同梱されている場合だけ複製する
# 4.xでは言語ファイルはapp.asarの中にしか入っておらず、
# その場合は何もせずに通過する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : claude_extract_dir, electron_resources_dest,
#   app_staging_dir
# 変更するグローバル変数 : なし
#

#
# @brief resources直下の言語JSONをElectronのresourcesへ複製する
# @global claude_extract_dir (参照のみ) 言語ファイルの取得元
# @global electron_resources_dest (参照のみ) 言語ファイルの複製先
# @global app_staging_dir (参照のみ) 完了メッセージで示すステージング先
# @note 複製に失敗した場合はexit 1で中断する
#
copy_locale_files() {
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying Claude locale JSON files to Electron resources directory...'
	if [[ -d $claude_locale_src ]]; then
		# 地域の接尾辞を持たない言語ファイルがあるため、
		# "*-*.json"で絞り込まない (am.json、da.json、ru.jsonなど)
		# 言語ごとの一覧はtests/locale-staging.batsで固定している
		local -a locale_jsons=("$claude_locale_src/"*.json)
		if [[ -f ${locale_jsons[0]} ]]; then
			cp "${locale_jsons[@]}" "$electron_resources_dest/" || exit 1
			echo 'Claude locale JSON files copied to Electron resources directory'
		else
			# 4.xでは言語ファイルはapp.asar内のresources/i18nにしか無い
			echo 'No locale JSON next to app.asar; the bundle ships them inside app.asar'
		fi
	else
		echo "Warning: Claude locale source directory not found at $claude_locale_src"
	fi

	echo "app.asar processed and staged in $app_staging_dir"
}
