#
# @file org-plugins.sh
# @brief Linuxでもorg-plugins機能を有効にするため、プラットフォーム判定へlinux分岐を注入する
#
# 上流はdarwinとwin32の分岐しか持たず、既定ではnullを返す
# そのためLinuxではorg-pluginsのマーケットプレイス機能が黙って無効になる
# case"linux":return"/etc/claude/org-plugins"を追加して有効化する
#
# /etc/claude/org-pluginsはMDM(Mobile Device Management、端末管理)で
# 配布する設定の置き場所としてFHSに沿っており
# Claude Codeの/etc/claude-code/と同じ考え方で選んでいる
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js
# 変更するグローバル変数 : なし
#

# アンカーに使う引用符クラス(バッククォート出力にも一致させる、Debian #820)
_ORG_Q='[`"'"'"']'

#
# @brief org-pluginsのパス解決switchへlinux分岐を注入する
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @stdout 適用またはスキップのメッセージ
# @note アンカーが見つからない場合や一意に決められない場合は、
#       メッセージを出して戻り、ビルドは失敗させない
#
patch_org_plugins_path() {
	local index_js="$main_js"

	# 既にLinux分岐がある場合は何もしない
	# 上流が将来linux分岐を追加する可能性があるため
	# 引用符クラスと\s*を使い、自前で注入した形にも一致させる
	if grep -qP "case\\s*${_ORG_Q}linux${_ORG_Q}\\s*:\\s*return\\s*${_ORG_Q}/etc/claude/org-plugins" \
		"$index_js"; then
		echo 'Linux org-plugins path already present'
		return
	fi

	# darwin側のパス文字列はバンドル全体で一意なので、存在確認のアンカーに使う
	# パスの内側だけを見るため、区切り文字の引用符クラスは要らない
	# このアンカーはパッチ後も残るので、再実行時も冪等判定より先に解決できる
	local anchor='Application Support/Claude/org-plugins'
	if ! grep -qF "$anchor" "$index_js"; then
		echo 'Warning: org-plugins path resolver not found' \
			'in this version, skipping' >&2
		return
	fi

	# minify済みの形は次のとおり
	#   ..."org-plugins");default:return null}
	#
	# "org-plugins")の直後にdefault:return nullが続く複合アンカーは
	# このswitch文だけに現れる
	# win32分岐の終わりとdefault分岐の間に
	# case"linux":return"/etc/claude/org-plugins";を挿入する
	# 注入するcaseは自前のJSなので、二重引用符のままでよい
	#
	# トークン間の\s*は将来の空白の揺れに備える
	# 実際の対象ファイルは常にminify済み
	# switch文が複数見つかった場合は、どの箇所か決められないため
	# 適用せずに警告を出す
	local switch_re="(${_ORG_Q}org-plugins${_ORG_Q}\\)\\s*;\\s*)"
	switch_re+="(default\\s*:\\s*return\\s+null)"
	if ! _assert_single_anchor_match "$index_js" \
		"$switch_re" 'org-plugins switch'; then
		echo 'Warning: org-plugins switch pattern not matched' \
			'unambiguously, skipping' >&2
		return
	fi
	sed -i -E \
		"s/${switch_re}/\\1case\"linux\":return\"\\/etc\\/claude\\/org-plugins\";\\2/" \
		"$index_js"
	echo 'Added Linux org-plugins path (/etc/claude/org-plugins)'
}
