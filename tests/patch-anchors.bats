#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # リテラルのJavaScript、Batsはサブシェルで実行する
#
# @file patch-anchors.bats
# @brief パッチのアンカーがバンドルの表記揺れに耐えることを検証する
#
# patch_quick_window、patch_org_plugins_path、patch_virtiofsd_probe、
# patch_file_manager_entries_linuxを対象に、バンドルの書き方が変わっても
# 正しい位置にだけパッチが当たることを確認する
# 対象の修正は上流のclaude-desktop-debian #820、#821、#919から移植した
# 検証する性質は次のとおり
#
#   * 引用符の種類 : 新しいバンドルは文字列リテラルをバッククォートの
#     テンプレートで再出力するため、"だけをアンカーにすると何にも一致しない
#     ['"] の文字クラスで両方を受ける
#   * QUICK_ENTRYタグ : setAlwaysOnTopのアンカーにタグの存在を要求し、
#     タグより前の古いバンドルには旧形式へのフォールバックを使う
#   * virtiofsdプローブの左辺 : await F(x)形式と裸の識別子形式の両方を受ける
#   * 一致件数 : アンカーがちょうど1件のときだけパッチを当て、
#     複数件なら警告してスキップする (恣意的な位置は書き換えない)
#   * 再実行 : 2回目の実行でファイルのバイト列が変わらないこと
#   * PATCH_STAGE_RERUNのダイジェスト : 再実行しても二重に適用されない
#     パッチを検出するための補助関数
#   * パッチ効果の確認 : 効果あり、許可リスト済みの何も変更しない処理、
#     失敗の3つを区別する
#
# テスト用の固定データ (fixture) は人工的に作っているが、
# DebianとSUSEのバンドルで実際に見つかったminify済みの形を模している
# (旧形式のダブルクォート、バッククォートでの再出力、シングルクォート)

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"
QW_SH="$SCRIPT_DIR/../scripts/patches/quick-window.sh"
ORG_SH="$SCRIPT_DIR/../scripts/patches/org-plugins.sh"
VFSD_SH="$SCRIPT_DIR/../scripts/patches/virtiofsd-probe.sh"
APP_ASAR_SH="$SCRIPT_DIR/../scripts/patches/app-asar.sh"
FM_SH="$SCRIPT_DIR/../scripts/patches/file-manager-entries.sh"

#
# @brief テストごとの一時ディレクトリを作り、検証対象のパッチ関数を読み込む
# @global TEST_TMP (本関数で設定する) テスト専用ディレクトリ
# @return 0 = 成功、mktempやsourceが失敗したときはその終了コード
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/quick-window.sh
	source "$QW_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/org-plugins.sh
	source "$ORG_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/virtiofsd-probe.sh
	source "$VFSD_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/app-asar.sh
	source "$APP_ASAR_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/file-manager-entries.sh
	source "$FM_SH"
}

#
# @brief テスト専用ディレクトリを削除する
# @return 常に0 (後片付けの失敗でテスト結果を変えない)
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief 渡されたJavaScript断片をfixture.jsとして書き出し、パッチ対象に設定する
# @param $1 パッチを当てる対象のJavaScript断片
# @global main_js (本関数で設定する) パッチ関数が対象として読むパス
#
write_fixture() {
	printf '%s' "$1" > "$TEST_TMP/fixture.js"
	main_js="$TEST_TMP/fixture.js"
}

#
# @brief ファイルの内容のSHA-256を求める (パッチ前後のバイト比較に使う)
# @param $1 対象ファイル
# @stdout SHA-256の16進文字列
# @return 0 = 成功、1 = ファイルを読めない
#
sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# quick-windowのfixtureで共通に使うパート2の末尾
# QuickEntryのログアンカーと、ドット付きのexports.mainWindow経由のshow()呼び出しを含む
# フォーカスと可視性のヘルパーはわざと模していない
# パート2は呼び出し地点の両側を捕捉するため、定義側の名前を必要としない
QW_TAIL='function n1(){return!0}isWindowFocused:()=>!!n1();_.info("[QuickEntry] Navigating to existing chat");_.info("[QuickEntry] Creating new chat with submit_quick_entry");n1()||exports.mainWindow.show()'

# =============================================================================
# quick-window パート1 : QUICK_ENTRYタグ付きアンカーと旧形式のフォールバック
# =============================================================================

@test "quick-window: tagged double-quoted shape extracts the var" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
}

@test "quick-window: tagged backtick shape extracts the var" {
	write_fixture 'n.n.QUICK_ENTRY),R.setAlwaysOnTop(!0,`pop-up-menu`),R.webContents;N6()||R.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: R'* ]]
	grep -qF 'R.blur(),R.hide()' "$main_js"
}

@test "quick-window: tagged single-quoted shape extracts the var" {
	write_fixture "Il.QUICK_ENTRY),Sa.setAlwaysOnTop(!0,'pop-up-menu'),Sa.webContents;N6()||Sa.hide();${QW_TAIL}"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: Sa'* ]]
	grep -qF 'Sa.blur(),Sa.hide()' "$main_js"
}

@test "quick-window: legacy bare shape still works when the tag is absent" {
	write_fixture 'Sa.setAlwaysOnTop(!0,"pop-up-menu"),Sa.webContents;N6()||Sa.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: Sa'* ]]
	grep -qF 'Sa.blur(),Sa.hide()' "$main_js"
}

@test "quick-window: whitespace around the call args is tolerated" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop( !0 , "pop-up-menu" ),er.webContents;N6()||er.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
}

@test "quick-window: duplicate tagged anchors warn and skip" {
	write_fixture 'Li.QUICK_ENTRY),mY.setAlwaysOnTop(!0,"pop-up-menu"),a;Li.QUICK_ENTRY),nZ.setAlwaysOnTop(!0,"pop-up-menu"),b;N6()||mY.hide();'"$QW_TAIL"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "quick-window: second run is byte-identical with no WARNING" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	patch_quick_window >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "quick-window: dotted show handle is captured whole" {
	# .show()の受け手を裸の識別子だけに限ると別の場所を書き換えてしまうため、
	# exports.mainWindowをそのまま1つのハンドルとして捕捉する
	# 可視性の判定は捕捉したハンドルへ直接埋め込む
	# (2.37337.1の呼び出し地点には呼び出せる上流のヘルパーが存在しない)
	# fixtureは断片で単体では構文が成立しないため、node --checkは行わない
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	patch_quick_window >/dev/null
	grep -qF '(!exports.mainWindow||exports.mainWindow.isDestroyed()?!1:exports.mainWindow.isVisible())' "$main_js"
	grep -qF 'n1())||exports.mainWindow.show()' "$main_js"
}

@test "quick-window: 2.37337.1 shape with extra call in the tag gap" {
	# QUICK_ENTRYタグと書き換え対象の間に余分な呼び出し (ここではt0r(AJ)) が入る形
	# 送信経路はko()||B.show()を呼び、可視性のヘルパーはアロー関数の
	# プロパティとしてしか存在しないため、定義側の探索では名前を特定できない
	# そのため定義側ではなく呼び出し地点の捕捉で対応する
	write_fixture 'Ni(AJ.webContents,ji.QUICK_ENTRY),t0r(AJ),AJ.setAlwaysOnTop(!0,`pop-up-menu`),AJ.webContents;X6()||AJ.hide();isWindowFocused:()=>!!ko()||r()||!1,isWindowVisible:()=>!!(B&&!B.isDestroyed()&&B.isVisible());_.info("[QuickEntry] Creating new chat with submit_quick_entry");!B||B.isDestroyed()||(ko()||B.show(),B.focus())'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: AJ'* ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'AJ.blur(),AJ.hide()' "$main_js"
	grep -qF '(!B||B.isDestroyed()?!1:B.isVisible())' "$main_js"
}

@test "quick-window: ambiguous show sites warn and skip the site" {
	# アンカーより後ろにshow()の呼び出しが2箇所ある
	# 1つ目を書き換えると恣意的な位置に当たるため、パート2は警告だけして
	# バイト列を変更しない (パート1は曖昧さがないのでそのまま適用される)
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();_.info("[QuickEntry] Creating new chat with submit_quick_entry");a()||b.show();c()||d.show()'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'2 raw and 0 patched show() sites near'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	# どちらのshow()呼び出しも可視性の判定を挟まずバイト列のまま残る
	grep -qF 'a()||b.show();c()||d.show()' "$main_js"
}

# パッチ前のfixtureの共通部分 : アンカーの直前までと、ログアンカー、パッチ後の期待値
QW_HEAD='Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'
QW_LOG='_.info("[QuickEntry] Creating new chat with submit_quick_entry");'
QW_GATED='((process.env.XDG_CURRENT_DESKTOP||"").toLowerCase().includes("kde")?(!B||B.isDestroyed()?!1:B.isVisible()):ko())||B.show()'

@test "quick-window: an unrelated XDG_CURRENT_DESKTOP mention is not taken as already patched" {
	write_fixture "${QW_HEAD}${QW_LOG}console.log(process.env.XDG_CURRENT_DESKTOP);ko()||B.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'show() already patched'* ]]
	grep -qF "console.log(process.env.XDG_CURRENT_DESKTOP);${QW_GATED}" "$main_js"
}

@test "quick-window: a duplicated log anchor warns and leaves the show() site alone" {
	write_fixture "${QW_HEAD}${QW_LOG}ko()||B.show();${QW_LOG}ko()||B.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'occurs more than once'* ]]
	[[ $(grep -o 'ko()||B.show()' "$main_js" | wc -l) -eq 2 ]]
	[[ $(grep -o 'B.isVisible()' "$main_js" | wc -l) -eq 0 ]]
}

@test "quick-window: whitespace and newlines inside the show() site are tolerated" {
	write_fixture "${QW_HEAD}${QW_LOG}"$'!B||(ko ()\n||\nB . show ( ),B.focus())'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF "!B||(${QW_GATED},B.focus())" "$main_js"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $output == *'show() already patched'* ]]
	[[ $output != *'WARNING'* ]]
	[[ $(sha_of "$main_js") == "$before" ]]
}

@test "quick-window: a whitespace-split dotted handle is captured whole" {
	write_fixture "${QW_HEAD}${QW_LOG}!B||(exports . focused () || B . show (),B.focus())"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated exports.focused()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF ':exports.focused())||B.show(),B.focus())' "$main_js"
	[[ $(< "$main_js") != *'exports . ('* ]]
	# fixtureの先頭部分は完全なプログラムではないため、対象箇所だけを切り出して構文を確認する
	local site="${TEST_TMP}/site.js"
	grep -oP '!B\|\|\(.*,B\.focus\(\)\)$' "$main_js" > "$site"
	node --check "$site"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $output == *'show() already patched'* ]]
	[[ $(sha_of "$main_js") == "$before" ]]
}

@test "quick-window: a mix of raw and patched show() sites warns and skips" {
	write_fixture "${QW_HEAD}${QW_LOG}${QW_GATED};a()||b.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'1 raw and 1 patched show() sites near'* ]]
	grep -qF "${QW_GATED};a()||b.show()" "$main_js"
}

# =============================================================================
# org-plugins : 引用符の種類、空白の許容、一致件数がちょうど1件であること
# =============================================================================

@test "org-plugins: injects the linux case on the double-quoted shape" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return C.join("C:\\Program Files","Claude","org-plugins");default:return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: injects the linux case on the backticked shape" {
	write_fixture 'return`/Library/Application Support/Claude/org-plugins`;case`win32`:return j(`C:\\Program Files`,`Claude`,`org-plugins`);default:return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: injects the linux case on the single-quoted shape" {
	write_fixture "return'/Library/Application Support/Claude/org-plugins';case'win32':return j('C:\\\\Program Files','Claude','org-plugins');default:return null}}"
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: whitespace around the switch arm is tolerated" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return C.join("C:\\Program Files","Claude","org-plugins") ; default : return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF '/etc/claude/org-plugins' "$main_js"
}

@test "org-plugins: duplicate switch sites warn and skip" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return"x","org-plugins");default:return null};"org-plugins");default:return null}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	run grep -qF '/etc/claude/org-plugins' "$main_js"
	[[ $status -ne 0 ]]
}

@test "org-plugins: second run is byte-identical" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return"x","org-plugins");default:return null}'
	patch_org_plugins_path >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'already present'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "org-plugins: missing resolver warns and skips" {
	write_fixture 'var unrelated=true;'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'Warning'* ]]
}

# =============================================================================
# file-manager-entries : Linuxだけゲートを開き、Windowsと無関係なreturn!1は変えない
# =============================================================================

# アプリが起動時に書く.desktopの生成関数を模す。
# Execの引用関数はreplaceAll("%","%%")、テンプレートは
# X-KDE-ServiceTypes=KonqPopupMenu/Pluginを安定した目印にする。
# minifyされた関数名は実際のバンドルごとに変わる。
FM_GATE='function kho(e){return[a.join("kservices5/ServiceMenus",e)]}function Aho(){return!1}'
FM_GENERATOR='var Sho="X-Claude-Generated=true";function Mho(e){return`"${e.replace(/[\\"`$]/g,(e=>`\\${e}`)).replaceAll("%","%%")}"`}function Fho(e,t){return["[Desktop Entry]","Type=Service",`TryExec=${t.tryExec}`,`MimeType=${t.mimeType}`,"X-KDE-Protocols=file",`Actions=${t.action}`,"X-KDE-ServiceTypes=KonqPopupMenu/Plugin",Sho,"",`[Desktop Action ${t.action}]`,`Name=${t.name}`,`Icon=${n.default.basename(e)}`,`Exec=${t.exec}`,""].join(`\n`)}'

write_fm_fixture() {
	write_fixture "$1$FM_GENERATOR"
}

@test "file-manager-entries: enables only the Linux gate and leaves decoys" {
	write_fm_fixture 'function kho(e){return[n.default.join(Oho(),"kio/servicemenus",e),n.default.join(Oho(),"kservices5/ServiceMenus",e)]}function Aho(){return!1}function decoy(){return!1}'
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'function Aho(){return process.platform==="linux"}' "$main_js"
	grep -qF 'function decoy(){return!1}' "$main_js"
}

@test "file-manager-entries: patched gate is true only on Linux" {
	write_fm_fixture 'function kho(e){return[n.default.join(Oho(),"kservices5/ServiceMenus",e)]}function Aho(){return!1}'
	patch_file_manager_entries_linux >/dev/null
	cat > "$TEST_TMP/gate-check.js" <<'JS'
const fs = require('fs');
const vm = require('vm');
const code = fs.readFileSync(process.argv[2], 'utf8');
const match = code.match(
	/function [\w$]+\(\)\s*\{\s*return process\.platform==="linux"\s*\}/);
if (!match) process.exit(1);
for (const platform of ['linux', 'win32', 'darwin']) {
	const gate = vm.runInNewContext('(' + match[0] + ')', {
		process: { platform },
	});
	if (gate() !== (platform === 'linux')) process.exit(1);
}
JS
	run node "$TEST_TMP/gate-check.js" "$main_js"
	[[ $status -eq 0 ]]
}

@test "file-manager-entries: accepts a renamed minified gate argument" {
	write_fm_fixture 'function qho(q){return[n.default.join(Oho(),"kservices5/ServiceMenus",q)]}function Aho(){return!1}'
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'function Aho(){return process.platform==="linux"}' "$main_js"
}

@test "file-manager-entries: accepts backticks and spaced gate body" {
	write_fm_fixture 'function K(e){return[n.default.join(O(),`kio/servicemenus`,e),n.default.join(O(), `kservices5/ServiceMenus`,e)]} function G(){ return !1 }'
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'function G(){ return process.platform==="linux" }' "$main_js"
}

@test "file-manager-entries: second run is byte-identical" {
	write_fm_fixture 'function kho(e){return[n.default.join(Oho(),"kservices5/ServiceMenus",e)]}function Aho(){return!1}'
	patch_file_manager_entries_linux >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	[[ $output == *'already enabled'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: existing Linux gate still gains serialization once" {
	write_fm_fixture 'function kho(e){return[n.default.join(Oho(),"kservices5/ServiceMenus",e)]}function Aho(){return process.platform==="linux"}'
	local before after once
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	[[ $output == *'already enabled'* ]]
	[[ $output == *'Serialized generated file-manager'* ]]
	once=$(sha_of "$main_js")
	[[ $before != "$once" ]]

	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	after=$(sha_of "$main_js")
	[[ $once == "$after" ]]
}

@test "file-manager-entries: duplicate anchor fails closed without writing" {
	write_fixture 'function k1(e){return[a.join("kservices5/ServiceMenus",e)]}function A(e){return!1}function k2(e){return[a.join("kservices5/ServiceMenus",e)]}function B(e){return!1}'
	local before
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $output == *'expected exactly one kservices5/ServiceMenus anchor'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: missing anchor or gate fails closed without writing" {
	write_fixture 'function kho(e){return[a.join("kservices5/ServiceMenus",e)]}function A(){return!0}'
	local before
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $output == *'gate'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]

	write_fixture 'var unrelated=true;'
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $output == *'expected exactly one kservices5/ServiceMenus anchor'* ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: generated Exec and TryExec survive GLib with special characters" {
	python3 -c 'from gi.repository import GLib' 2>/dev/null \
		|| skip 'python3 gi (GLib) not available'
	write_fixture "$FM_GATE$FM_GENERATOR"
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	cat > "$TEST_TMP/render.js" <<'JS'
const fs = require('fs');
const vm = require('vm');
const code = fs.readFileSync(process.argv[2], 'utf8');
const dir = process.argv[3];
const out = process.argv[4];
const ctx = { Sho: 'X-Claude-Generated=true',
	n: { default: { basename: p => p.slice(p.lastIndexOf('/') + 1) } } };
vm.createContext(ctx);
vm.runInContext(code, ctx);
fs.writeFileSync(out, ctx.Fho(dir, {
	action: 'sendToClaude',
	name: 'Send to Claude',
	mimeType: 'all/all;',
	tryExec: dir,
	exec: ctx.Mho(dir) + ' %F'
}));
JS
	local dir="$TEST_TMP/xdg a/quote\"dollar\$back\\slash\`tick"
	node "$TEST_TMP/render.js" "$main_js" "$dir" "$TEST_TMP/out.desktop"
	python3 - "$TEST_TMP/out.desktop" "$dir" <<'PY'
import sys
from gi.repository import GLib
path, expected = sys.argv[1], sys.argv[2]
kf = GLib.KeyFile()
kf.load_from_file(path, GLib.KeyFileFlags.NONE)
try_exec = kf.get_string('Desktop Entry', 'TryExec')
exec_line = kf.get_string('Desktop Action sendToClaude', 'Exec')
ok, argv = GLib.shell_parse_argv(exec_line)
assert try_exec == expected, (try_exec, expected)
assert ok and argv[0] == expected, (argv, expected)
PY
}

@test "file-manager-entries: preserves declarations between quote and template functions" {
	local head tail
	head="${FM_GENERATOR%%function Fho*}"
	tail="function Fho${FM_GENERATOR#*function Fho}"
	write_fixture "$FM_GATE${head}class KeepMe{}var keepMe=1;${tail}"

	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Serialized generated file-manager'* ]]
	grep -qF 'class KeepMe{}' "$main_js"
	grep -qF 'var keepMe=1;' "$main_js"
	grep -qF '/*claude-suse:file-manager-serialize*/' "$main_js"
}

@test "file-manager-entries: unknown Exec quote transform fails closed with the class intact" {
	local head tail quote before after
	head='var Sho="X-Claude-Generated=true";'
	# 波括弧を含む正規表現をExec引用関数へ足した、未知の変換形。
	quote='function Mho(e){return`"${e.replace(/[\\"`$]/g,(e=>`\\${e}`)).replace(/{/g,"").replaceAll("%","%%")}"`}'
	tail="${FM_GENERATOR#*function Fho}"
	write_fixture "$FM_GATE$head$quote"'class KeepMe{static brace="}"}'"function Fho${tail}"

	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $output == *'cannot parse the file-manager Exec quote function'* ]]
	grep -qF 'class KeepMe{static brace="}"}' "$main_js"
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: keeps a class whose string literal contains the function brace" {
	local head tail
	head="${FM_GENERATOR%%function Fho*}"
	tail="${FM_GENERATOR#*function Fho}"
	write_fixture "$FM_GATE$head"'class KeepMe{static brace="}"}'"function Fho$tail"

	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'class KeepMe{static brace="}"}' "$main_js"
	grep -qF '/*claude-suse:file-manager-serialize*/' "$main_js"
}

@test "file-manager-entries: keeps declarations after braces in the template body" {
	local head menu
	head="${FM_GENERATOR%%function Fho*}"
	menu='function Fho(e,t){return["[Desktop Entry]","Type=Service","}",`brace=${{a:"}"}.a}`,`TryExec=${t.tryExec}`,`MimeType=${t.mimeType}`,"X-KDE-Protocols=file",`Actions=${t.action}`,"X-KDE-ServiceTypes=KonqPopupMenu/Plugin",Sho,"",`[Desktop Action ${t.action}]`,`Name=${t.name}`,`Icon=${n.default.basename(e)}`,`Exec=${t.exec}`,""].join(`\n`)}'
	write_fixture "$FM_GATE$head$menu"'class KeepMe{static brace="}"}'

	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'class KeepMe{static brace="}"}' "$main_js"
	grep -qF '})(t.tryExec)}`' \
		"$main_js"
}

@test "file-manager-entries: keeps declarations after block and line comments with braces" {
	local head menu
	head="${FM_GENERATOR%%function Fho*}"
	menu='function Fho(e,t){return[
// {
"[Desktop Entry]", /* { */
"Type=Service",`TryExec=${t.tryExec}`,`MimeType=${t.mimeType}`,"X-KDE-Protocols=file",`Actions=${t.action}`,"X-KDE-ServiceTypes=KonqPopupMenu/Plugin",Sho,"",`[Desktop Action ${t.action}]`,`Name=${t.name}`,`Icon=${n.default.basename(e)}`,`Exec=${t.exec}`,""].join(`\n`)}'
	write_fixture "$FM_GATE$head$menu"'class KeepMe{static brace="}"}'

	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'class KeepMe{static brace="}"}' "$main_js"
	grep -qF '// {' "$main_js"
	grep -qF '/* { */' "$main_js"
	grep -qF '/*claude-suse:file-manager-serialize*/' "$main_js"
}

@test "file-manager-entries: rejects an ambiguous fake function in the menu comment" {
	local menu before after
	menu=${FM_GENERATOR/'"[Desktop Entry]"'/'/* function fake(e,t){return[ */"[Desktop Entry]"'}
	write_fixture "$FM_GATE$menu"
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: preserves named function expressions" {
	local menu
	menu=${FM_GENERATOR/'function Fho'/'var render=function Fho'}
	write_fixture "$FM_GATE$menu"
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	run node -e 'const vm=require("vm"),fs=require("fs"); const c={n:{default:{basename:()=>"icon"}}}; vm.createContext(c); vm.runInContext(fs.readFileSync(process.argv[1],"utf8"),c); const s=c.render("x",{tryExec:"a\\b",exec:"x"}); if (!s.includes("TryExec=a\\\\b")) process.exit(1)' "$main_js"
	[[ $status -eq 0 ]]
}

@test "file-manager-entries: fake TryExec in comments or strings cannot corrupt the bundle" {
	local decoy menu before after
	for decoy in '/* function fake(e,t){return[ `TryExec=${t.tryExec}` */' '"function fake(e,t){return[ `TryExec=${t.tryExec}`",'; do
		menu=${FM_GENERATOR/'"X-KDE-Protocols=file"'/"$decoy\"X-KDE-Protocols=file\""}
		write_fixture "$FM_GATE$menu"
		before=$(sha_of "$main_js")
		run patch_file_manager_entries_linux
		if [[ $status -eq 0 ]]; then
			run node -e 'const vm=require("vm"),fs=require("fs"); const c={n:{default:{basename:()=>"icon"}}}; vm.createContext(c); vm.runInContext(fs.readFileSync(process.argv[1],"utf8"),c); if (!c.Fho("x",{tryExec:"a\\b",exec:"x"}).includes("TryExec=a\\\\b")) process.exit(1)' "$main_js"
			[[ $status -eq 0 ]] || { printf '%s\n' "$output"; false; }
		else
			after=$(sha_of "$main_js")
			[[ $before == "$after" ]]
		fi
	done
}

@test "file-manager-entries: keeps the quote function expression separator" {
	local generator
	generator=${FM_GENERATOR/'function Mho'/'var quote=function Mho'}
	generator=${generator/'function Fho'/';function Fho'}
	write_fixture "$FM_GATE$generator"
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	run node --check "$main_js"
	[[ $status -eq 0 ]] || { printf '%s\n' "$output"; false; }
}

@test "file-manager-entries: stray serialization marker fails closed" {
	write_fixture "/*claude-suse:file-manager-serialize*/$FM_GATE$FM_GENERATOR"
	local before after
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: fake TryExec cannot replace an unknown real form" {
	local menu before after decoy
	for decoy in '/* function fake(e,t){return[ `TryExec=${t.tryExec}` */' $'// function fake(e,t){return[ `TryExec=${t.tryExec}`\n'; do
		menu=${FM_GENERATOR/'`TryExec=${t.tryExec}`'/'`TryExec=${t["tryExec"]}`'}
		menu=${menu/'"X-KDE-Protocols=file"'/"$decoy\"X-KDE-Protocols=file\""}
		write_fixture "$FM_GATE$menu"
		before=$(sha_of "$main_js")
		run patch_file_manager_entries_linux
		[[ $status -ne 0 ]]
		after=$(sha_of "$main_js")
		[[ $before == "$after" ]]
	done
}

@test "file-manager-entries: helper in a comment is not an applied patch" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" <<'JS'
const fs = require('fs');
const file = process.argv[2];
const code = fs.readFileSync(file, 'utf8');
const match = code.match(/`TryExec=\$\{\/\*claude-suse:file-manager-serialize\*\/[\s\S]*?\}\`/);
if (!match) process.exit(1);
fs.writeFileSync(file, code.replace(match[0], '`TryExec=${t.tryExec}`') + '\n// ' + match[0]);
JS
	local before after
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: distant real menu cannot be replaced by a commented function" {
	local padding menu before after
	printf -v padding '%*s' 17000 ''
	menu=${FM_GENERATOR/'`TryExec=${t.tryExec}`'/'`TryExec=${t["tryExec"]}`'}
	menu=${menu/'"X-KDE-Protocols=file"'/"\"$padding\",/* function fake(e,t){return[ \`TryExec=\${t.tryExec}\` */\"X-KDE-Protocols=file\""}
	# Node 22 cannot compile this valid resource declaration. The old patch
	# consequently skipped its only syntax check of the modified bundle.
	write_fixture "function resource(){using r=null;}$FM_GATE$menu"
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	if [[ $status -eq 0 ]]; then
		run node -e 'const vm=require("vm"),fs=require("fs"),assert=require("assert/strict"); const c={n:{default:{basename:()=>"icon"}}}; vm.createContext(c); vm.runInContext(fs.readFileSync(process.argv[1],"utf8").replace("function resource(){using r=null;}",""),c); assert.ok(c.Fho("x",{tryExec:"a\\b",exec:"x"}).includes("TryExec=a\\\\b"))' "$main_js"
		[[ $status -eq 0 ]] || { printf '%s\n' "$output"; false; }
	else
		after=$(sha_of "$main_js")
		[[ $before == "$after" ]]
	fi
}

@test "file-manager-entries: menu at the old search boundary stays byte-identical on replay" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	node - "$main_js" <<'JS'
const fs = require('fs');
const file = process.argv[2], code = fs.readFileSync(file, 'utf8');
const distance = code.indexOf('X-KDE-ServiceTypes=KonqPopupMenu/Plugin') - code.indexOf('function Fho');
fs.writeFileSync(file, code.replace('"[Desktop Entry]"', '"' + 'x'.repeat(16384 - distance - 3) + '","[Desktop Entry]"'));
JS
	patch_file_manager_entries_linux
	local before after
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]] || { printf '%s\n' "$output"; false; }
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: percent anchor only in a fake quote function fails without writing" {
	local quote menu before after
	quote=${FM_GENERATOR#*;}
	quote=${quote%%function Fho*}
	menu=${FM_GENERATOR/'.replaceAll("%","%%")'/'.split("%").join("%%")'}
	write_fixture "$FM_GATE/* $quote */$menu"
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "file-manager-entries: applied helper inside the menu comment is rejected" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" <<'JS'
const fs = require('fs');
const file = process.argv[2], code = fs.readFileSync(file, 'utf8');
const match = code.match(/`TryExec=\$\{\/\*claude-suse:file-manager-serialize\*\/[\s\S]*?\}\`/);
if (!match) process.exit(1);
// A line comment can contain the helper's own block comment unchanged.
fs.writeFileSync(file, code.replace(match[0], '// ' + match[0] + '\n`TryExec=${t.tryExec}`'));
JS
	local before after
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

assert_file_manager_fixture_rejected() {
	local before
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $(sha_of "$main_js") == "$before" ]]
}

@test "file-manager-entries: applied menu with another raw TryExec is rejected" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" <<'JS'
const fs = require('fs'), file = process.argv[2];
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('`Exec=${t.exec}`', '`TryExec=${t.tryExec}`,`Exec=${t.exec}`'));
JS
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: applied menu without Exec is rejected" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" <<'JS'
const fs = require('fs'), file = process.argv[2];
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('`Exec=${t.exec}`,', ''));
JS
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: unrelated patched quote cannot hide the raw real quote" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" "$FM_GENERATOR" <<'JS'
const fs = require('fs'), file = process.argv[2], generator = process.argv[3];
const code = fs.readFileSync(file, 'utf8');
const patched = code.slice(code.indexOf('function Mho'), code.indexOf('function Fho'));
const raw = generator.slice(generator.indexOf('function Mho'), generator.indexOf('function Fho'));
fs.writeFileSync(file, code.replace(patched, raw) + ';' + patched.replace('function Mho', 'function unusedQuote'));
JS
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: path anchor in a comment cannot identify the gate" {
	local gate
	gate=${FM_GATE/'kservices5/ServiceMenus'/'kservices5/\u0053erviceMenus'}
	write_fixture "function decoy(e){/* \"kservices5/ServiceMenus\" */return false}function unrelated(){return!1}$gate$FM_GENERATOR"
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: significant quote template whitespace is not formatting" {
	local generator
	generator=${FM_GENERATOR/'return`"${'/'return`" ${'}
	generator=${generator/'}"`}'/'} "`}'}
	write_fixture "$FM_GATE$generator"
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: spaced duplicate keys are rejected before and after application" {
	local applied
	for applied in no yes; do
		write_fixture "$FM_GATE$FM_GENERATOR"
		if [[ $applied == yes ]]; then
			patch_file_manager_entries_linux >/dev/null
		fi
		node - "$main_js" <<'JS'
const fs = require('fs'), file = process.argv[2];
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('`Exec=${t.exec}`', '`TryExec =${t.tryExec}`,`Exec=${t.exec}`'));
JS
		assert_file_manager_fixture_rejected
	done
}

@test "file-manager-entries: escaped percent arguments cannot hide an unpatched quote" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	patch_file_manager_entries_linux >/dev/null
	node - "$main_js" "$FM_GENERATOR" <<'JS'
const fs = require('fs'), file = process.argv[2], generator = process.argv[3];
const code = fs.readFileSync(file, 'utf8');
const patched = code.slice(code.indexOf('function Mho'), code.indexOf('function Fho'));
const raw = generator.slice(generator.indexOf('function Mho'), generator.indexOf('function Fho')).replace(/%/g, '\\x25');
fs.writeFileSync(file, code.replace(patched, raw) + ';' + patched.replace('function Mho', 'function unusedQuote'));
JS
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: automatic semicolon insertion in quote return is rejected" {
	local generator
	generator=${FM_GENERATOR/'return`'/$'return\n`'}
	write_fixture "$FM_GATE$generator"
	assert_file_manager_fixture_rejected
}

@test "file-manager-entries: tolerates whitespace and quote variants in serialization anchors" {
	local variant head tail menu before after
	local -a variants=(
		'replaceAll( "%" , "%%" )'
		"replaceAll('%','%%')"
		'replaceAll(`%`, `%%`)'
	)
	# 関数キーワード直後の改行と、テンプレート補間内の空白も同時に受ける。
	head='var Sho="X-Claude-Generated=true";function
Mho(e){return`"${e.replace(/[\\"`$]/g,(e=>`\\${e}`)).'
	tail='}"`}'
	menu='function
Fho(e,t){return["[Desktop Entry]","Type=Service",`TryExec=${ t . tryExec }`,`MimeType=${t.mimeType}`,"X-KDE-Protocols=file",`Actions=${t.action}`,"X-KDE-ServiceTypes=KonqPopupMenu/Plugin",Sho,"",`[Desktop Action ${t.action}]`,`Name=${t.name}`,`Icon=${n.default.basename(e)}`,`Exec=${ t . exec }`,""].join(`\n`)}'

	for variant in "${variants[@]}"; do
		write_fixture "${FM_GATE}${head}${variant}${tail}${menu}"
		run patch_file_manager_entries_linux
		[[ $status -eq 0 ]]
		[[ $output == *'Serialized generated file-manager'* ]]
		grep -qF "replaceAll('%','%%')" "$main_js"
		grep -qF '})(t.tryExec)}`' \
			"$main_js"
		before=$(sha_of "$main_js")

		run patch_file_manager_entries_linux
		[[ $status -eq 0 ]]
		after=$(sha_of "$main_js")
		[[ $before == "$after" ]]
	done
}

@test "file-manager-entries: serialization follows renamed minified functions" {
	write_fixture "$FM_GATE$FM_GENERATOR"
	sed -i -e 's/function Mho/function Zq/' -e 's/function Fho/function Wk/' \
		"$main_js"
	run patch_file_manager_entries_linux
	[[ $status -eq 0 ]]
	grep -qF 'function Zq(' "$main_js"
	grep -qF 'function Wk(' "$main_js"
	grep -qF '/*claude-suse:file-manager-serialize*/(function __claudeSuseDesktopString' "$main_js"
	run grep -qF 'function Mho(' "$main_js"
	[[ $status -ne 0 ]]
}

@test "file-manager-entries: ambiguous menu template fails closed without writing" {
	write_fixture "function kho(e){return[a.join(\"kservices5/ServiceMenus\",e)]}function Aho(){return!1}$FM_GENERATOR"'var decoy="X-KDE-ServiceTypes=KonqPopupMenu/Plugin";'
	local before
	before=$(sha_of "$main_js")
	run patch_file_manager_entries_linux
	[[ $status -ne 0 ]]
	[[ $output == *'expected exactly one file-manager menu template anchor'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

# =============================================================================
# virtiofsd-probe : 引用符の種類、await形式と裸の左辺、一致件数がちょうど1件であること
# =============================================================================

@test "virtiofsd: un-gates the double-quoted bare-identifier shape" {
	write_fixture 'Gon=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];async function Kon(e){const t=await Qot(Gon);return t||(e?loe(Won,Y.constants.X_OK):null)}'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return t||loe(Won,Y.constants.X_OK)' "$main_js"
}

@test "virtiofsd: un-gates the backticked await-inlined shape" {
	write_fixture 'kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];async function jT(e){return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)}'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return await FT(kT)||IT(TT,N.constants.X_OK)' "$main_js"
	run grep -qF '(e?IT(TT,N.constants.X_OK):null)' "$main_js"
	[[ $status -ne 0 ]]
}

@test "virtiofsd: un-gates the single-quoted shape" {
	write_fixture "Gon=['/usr/libexec/virtiofsd','/usr/bin/virtiofsd'];async function Kon(e){const t=await Qot(Gon);return t||(e?loe(Won,Y.constants.X_OK):null)}"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return t||loe(Won,Y.constants.X_OK)' "$main_js"
}

@test "virtiofsd: duplicate probe arrays warn and skip" {
	write_fixture 'a=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];return t||(e?loe(Won,Y.constants.X_OK):null);b=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];return u||(f?mex(Don,Z.constants.X_OK):null)'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	grep -qF 'return t||(e?loe(Won,Y.constants.X_OK):null)' "$main_js"
}

@test "virtiofsd: missing probe array skips without failing" {
	write_fixture 'var x=["/usr/bin/qemu-system-x86_64"];'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'skipped'* ]]
}

@test "virtiofsd: second run is byte-identical" {
	write_fixture 'kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];async function jT(e){return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)}'
	patch_virtiofsd_probe >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'already un-gated'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "virtiofsd: win32/darwin-gated evaluator with no probe is not needed" {
	# Windows由来のバンドルの形 (2.37337.1、1.44121.4も同じ)
	# Coworkの判定がwin32とdarwinだけを条件にしており、
	# ビルドツリーのどこにもvirtiofsdのバイナリ名が現れない
	# 外すべき条件が存在しないため、WARNINGではなく情報としてスキップする
	write_fixture 'if(e==="win32"){let e=Amr();if(!e.available)return{status:"unsupported",reason:`Missing HCS services: ${e.missingServices.join(", ")}`,unsupportedCode:"hcs_not_available"}}return{status:"supported"}'
	local before
	before=$(sha_of "$main_js")
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'patch not needed, skipping'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "virtiofsd: evaluator marker with a probe elsewhere stays a warning" {
	# 不要と言い切るにはビルドツリー全体にバイナリ名がないことが前提になる
	# 兄弟ファイルにプローブ文字列があるなら、解決処理は別のチャンクに
	# ある可能性があるため、情報としてのスキップではなくWARNINGとスキップに留める
	write_fixture 'if(e==="win32"){let e=Amr();if(!e.available)return{status:"unsupported",reason:`Missing HCS services: ${e.missingServices.join(", ")}`,unsupportedCode:"hcs_not_available"}}return{status:"supported"}'
	printf '%s' '["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"]' \
		> "$TEST_TMP/sibling-chunk.js"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'skipped'* ]]
}

# =============================================================================
# アンカーの一致件数を数える : _count_anchor_matches / _assert_single_anchor_match
# =============================================================================

@test "anchor helper: counts zero, one and many matches" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu");b.setAlwaysOnTop(!0,"pop-up-menu")'
	local n
	n=$(_count_anchor_matches "$main_js" 'setAlwaysOnTop')
	[[ $n -eq 2 ]]
	n=$(_count_anchor_matches "$main_js" 'no-such-anchor-xyz')
	[[ $n -eq 0 ]]
	n=$(_count_anchor_matches "$TEST_TMP/does-not-exist.js" 'x')
	[[ $n -eq 0 ]]
}

@test "anchor helper: exactly one match is quiet success" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu")'
	run _assert_single_anchor_match "$main_js" 'setAlwaysOnTop' 'probe'
	[[ $status -eq 0 ]]
	[[ $output != *'WARNING'* ]]
}

@test "anchor helper: zero and many matches warn" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu");b.setAlwaysOnTop(!0,"pop-up-menu")'
	run _assert_single_anchor_match "$main_js" 'setAlwaysOnTop' 'probe'
	[[ $status -ne 0 ]]
	[[ $output == *'matched 2 sites'* ]]
	run _assert_single_anchor_match "$main_js" 'no-such-anchor-xyz' 'probe'
	[[ $status -ne 0 ]]
	[[ $output == *'not found'* ]]
}

# =============================================================================
# PATCH_STAGE_RERUNのダイジェスト補助関数 : 再実行しても二重に適用されないことの検証
# =============================================================================

#
# @brief ダイジェスト計算が前提とするステージング構成を最小限だけ作る
# @global TEST_TMP テスト専用ディレクトリ (既存の値を使う)
# @return 0 = 成功、1 = 移動できない
# @note ダイジェストはステージングディレクトリを基準に計算するため、
#       作成後にここへ移動する
#
_make_build_tree() {
	mkdir -p "$TEST_TMP/staging/app.asar.contents/.vite/build"
	printf '%s' 'var core=1;' \
		> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	cd "$TEST_TMP/staging" || return 1
}

@test "rerun digest: stable across reads, changes with bytes" {
	_make_build_tree
	local first second
	first=$(_patch_bundle_digest)
	[[ -n $first ]]
	second=$(_patch_bundle_digest)
	[[ $first == "$second" ]]
	printf '%s' 'var extra=2;' \
		>> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	local third
	third=$(_patch_bundle_digest)
	[[ $third != "$first" ]]
}

@test "rerun digest: missing or empty tree fails" {
	cd "$TEST_TMP" || return 1
	run _patch_bundle_digest
	[[ $status -ne 0 ]]
	mkdir -p "$TEST_TMP/empty/app.asar.contents/.vite/build"
	cd "$TEST_TMP/empty" || return 1
	run _patch_bundle_digest
	[[ $status -ne 0 ]]
}

@test "rerun check: equal digests pass, differing digests fail loudly" {
	run _check_patch_stage_idempotent 'abc123' 'abc123'
	[[ $status -eq 0 ]]
	run _check_patch_stage_idempotent 'abc123' 'def456'
	[[ $status -ne 0 ]]
	[[ $output == *'Idempotency'* ]]
}

@test "rerun check: detects a deliberately non-idempotent fake patch" {
	_make_build_tree
	_fake_patch_appends() {
		printf '%s' '// fake' \
			>> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	}
	local before after
	before=$(_patch_bundle_digest)
	_fake_patch_appends
	after=$(_patch_bundle_digest)
	run _check_patch_stage_idempotent "$before" "$after"
	[[ $status -ne 0 ]]
	[[ $output == *'Idempotency: second patch pass'* ]]
}

# =============================================================================
# パッチ効果の確認 : 効果あり、何も変更しない処理、失敗の区別
# =============================================================================

@test "patch effect: changed digest is effective" {
	run _check_patch_effect patch_demo 'aaa' 'bbb'
	[[ $status -eq 0 ]]
	[[ $output == *'patch_demo changed the bundle (effective)'* ]]
}

@test "patch effect: non-allowlisted no-op fails and names the function" {
	run _check_patch_effect patch_demo 'aaa' 'aaa'
	[[ $status -ne 0 ]]
	[[ $output == *"'patch_demo' left"* ]]
	[[ $output == *'_PATCH_EFFECT_ALLOWLIST'* ]]
}

@test "patch effect: allowlisted no-op passes with its reason" {
	run _check_patch_effect extract_electron_variable 'aaa' 'aaa' 1
	[[ $status -eq 0 ]]
	[[ $output == *'allowlisted no-op'* ]]
	[[ $output == *'writes no file'* ]]
}

@test "patch effect: allowlisted no-op without its declaration fails" {
	run _check_patch_effect patch_menu_bar_default 'aaa' 'aaa' ''
	[[ $status -ne 0 ]]
	[[ $output == *"'patch_menu_bar_default' is allowlisted but did not reach"* ]]
}

@test "patch effect: wrapper clears a stale no-op declaration" {
	_make_build_tree
	_PATCH_EFFECT_ALLOWLIST[_fake_allowlisted]='test entry'
	_fake_allowlisted() { :; }
	patch_noop_declared='1'
	run _run_suse_patch_function _fake_allowlisted check
	[[ $status -ne 0 ]]
	[[ $output == *'did not reach its reviewed no-op branch'* ]]
	_fake_declares() { _declare_patch_noop; }
	_PATCH_EFFECT_ALLOWLIST[_fake_declares]='test entry'
	run _run_suse_patch_function _fake_declares check
	[[ $status -eq 0 ]]
	[[ $output == *'_fake_declares is an allowlisted no-op'* ]]
}

@test "patch effect: a failing patch fails the stage in both modes" {
	_make_build_tree
	_fake_writes_then_fails() {
		printf 'x' >> app.asar.contents/.vite/build/index.js
		return 1
	}
	run _run_suse_patch_function _fake_writes_then_fails check
	[[ $status -ne 0 ]]
	[[ $output == *'_fake_writes_then_fails failed (exit 1)'* ]]
	[[ $output != *'effective'* ]]
	run _run_suse_patch_function _fake_writes_then_fails no-check
	[[ $status -ne 0 ]]
	[[ $output == *'_fake_writes_then_fails failed (exit 1)'* ]]
}

@test "patch effect: missing digest fails even for an allowlisted patch" {
	run _check_patch_effect extract_electron_variable 'aaa' '' 1
	[[ $status -ne 0 ]]
	[[ $output == *'missing digest'* ]]
	[[ $output == *'extract_electron_variable'* ]]
}

@test "patch effect: check mode runs the patch in the current shell" {
	_make_build_tree
	_fake_sets_global() { FAKE_PATCH_GLOBAL='kept'; }
	local rc=0
	# runを使わない : runはサブシェルで実行するため、
	# ラッパーがパッチを現在のシェルに残したかを確認できなくなる
	_run_suse_patch_function _fake_sets_global check \
		2>"$TEST_TMP/effect.err" || rc=$?
	[[ $rc -ne 0 ]]
	[[ ${FAKE_PATCH_GLOBAL:-} == 'kept' ]]
	grep -q "'_fake_sets_global' left" "$TEST_TMP/effect.err"
}

@test "patch effect: rerun mode skips the effect check" {
	_make_build_tree
	_fake_noop() { :; }
	run _run_suse_patch_function _fake_noop no-check
	[[ $status -eq 0 ]]
	[[ $output != *'Patch effect'* ]]
}
