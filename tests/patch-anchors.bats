#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # リテラルのJavaScript、Batsはサブシェルで実行する
#
# @file patch-anchors.bats
# @brief パッチのアンカーがバンドルの表記揺れに耐えることを検証する
#
# patch_quick_window、patch_org_plugins_path、patch_virtiofsd_probeを対象に、
# バンドルの書き方が変わっても正しい位置にだけパッチが当たることを確認する
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
