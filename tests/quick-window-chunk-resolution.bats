#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file quick-window-chunk-resolution.bats
# @brief クイックウィンドウの各パッチが、自分のアンカーを持つファイルを解決する処理のテスト
#
# メインのチャンクにアンカーがあればそのファイルを使い、無ければ同じディレクトリの
# 兄弟のJavaScriptチャンクを1つだけ使う
# 上流がQuickEntryの送信経路をポップアップメニューの経路から分離することがあり、
# その場合もパッチ2はそのファイルを追わなければならない
# KDE向けのshow()修正を黙って飛ばしてはいけない
#
# 失敗側の確認も重要である
# 同じアンカーを持つ兄弟チャンクが2つあれば、
# 任意のファイルをパッチせずにビルドを失敗させる
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"           # パッチ共通の補助関数
QW_SH="$SCRIPT_DIR/../scripts/patches/quick-window.sh"          # 検証対象のクイックウィンドウ向けパッチ

#
# @brief パッチ共通の補助関数とクイックウィンドウ向けパッチを読み込む
# @global BUNDLE_DIR アプリのバンドルを置くディレクトリ (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
	mkdir -p "$BUNDLE_DIR"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/quick-window.sh
	source "$QW_SH"
}

# パッチ1がメインのチャンクで使う固定データ
# タグ付きのアンカーと、hide()を書き換える箇所を含む
QW_PART1='Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'

# パッチ2が使う固定データ
# パッチ後もログの文字列は残るため、再実行しても同じファイルを解決できる
# ドット付きのハンドル経由でshow()を呼ぶ箇所も含む
QW_PART2='_.info("[QuickEntry] Creating new chat with submit_quick_entry");n1()||exports.mainWindow.show()'

# パッチ2がshow()呼び出しの手前に差し込む、KDE向けの条件式
QW_GATE='(!exports.mainWindow||exports.mainWindow.isDestroyed()?!1:exports.mainWindow.isVisible())'

@test "quick-window: part 2 anchor in a sibling chunk is patched there" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-submit.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf '%s' "$QW_PART2" > "$submit_js"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Patched 1 quick entry show() calls'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$submit_js"
	run grep -qF 'exports.mainWindow' "$main_js"
	[[ $status -ne 0 ]]
}

@test "quick-window: part 1 in main and part 2 in a sibling are both patched" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-abc123.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf 'var unrelated=1;%s' "$QW_PART2" > "$submit_js"
	printf '%s' 'var decoy=2;' > "$BUNDLE_DIR/index.chunk-decoy.js"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	[[ $output == *'KDE-gated n1()/exports.mainWindow.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$submit_js"
}

@test "quick-window: anchor in two sibling chunks fails the build" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' 'var mainOnly=1;' > "$main_js"
	printf '%s' 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu");' \
		> "$BUNDLE_DIR/index.chunk-a.js"
	printf '%s' 'Il.QUICK_ENTRY),R.setAlwaysOnTop(!0,`pop-up-menu`);' \
		> "$BUNDLE_DIR/index.chunk-b.js"
	cp "$main_js" "$BATS_TEST_TMPDIR/main.before"
	cp "$BUNDLE_DIR/index.chunk-a.js" "$BATS_TEST_TMPDIR/a.before"
	cp "$BUNDLE_DIR/index.chunk-b.js" "$BATS_TEST_TMPDIR/b.before"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'matched 2 sibling chunks'* ]]
	[[ $output == *'refusing to guess'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/main.before"
	cmp "$BUNDLE_DIR/index.chunk-a.js" "$BATS_TEST_TMPDIR/a.before"
	cmp "$BUNDLE_DIR/index.chunk-b.js" "$BATS_TEST_TMPDIR/b.before"
}

@test "quick-window: rerun over split files is byte-identical" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-submit.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf '%s' "$QW_PART2" > "$submit_js"
	patch_quick_window > /dev/null
	cp "$main_js" "$BATS_TEST_TMPDIR/main.first"
	cp "$submit_js" "$BATS_TEST_TMPDIR/submit.first"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/main.first"
	cmp "$submit_js" "$BATS_TEST_TMPDIR/submit.first"
}

@test "quick-window: anchors in main keep the main-only path" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s%s' "$QW_PART1" "$QW_PART2" > "$main_js"
	local sibling="$BUNDLE_DIR/index.chunk-sibling.js"
	printf 'var a=1;%s' "$QW_PART2" > "$sibling"
	cp "$sibling" "$BATS_TEST_TMPDIR/sibling.before"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$main_js"
	cmp "$sibling" "$BATS_TEST_TMPDIR/sibling.before"
}

# 7.37095.0のQuick Entry契約を写した固定データ
# 送信ログは2箇所にあり、パッチ2はそこへ注入してはいけない
# 添付付き送信の入口(vga)が、ダイアログを閉じる前にshowMainWindowForSendを呼ぶ
# showはログの前、dismissはログの後にある実物と同じ並びにする
QW_MODERN='Il.QUICK_ENTRY),S7.setAlwaysOnTop(!0,"pop-up-menu"),S7.webContents;N6()||S7.hide();
var s2s=e.r({activateQuickEntryWindow:()=>w2s,handQuickEntryShortcutToPage:()=>C2s,requestQuickWindowDismissWithPayload:()=>j2s,showHeldQuickEntryNotice:()=>q2s,showMainWindowForSend:()=>x2s,stampSubmission:()=>A2s});
function b2s(e){Qz(),e.show(),e.focus()}
function x2s(){!V||V.isDestroyed()||b2s(V)}
function j2s(e,t,n,r=!1){r||x2s()}
async function vga({prompt:e,images:t,filePaths:r,chatId:a}){let{requestQuickWindowDismissWithPayload:o,showMainWindowForSend:s,stampSubmission:c}=await Promise.resolve().then((()=>s2s)),l=c(),u=r.length>0;u&&s(),N.info("Quick entry submitted",{});o({},l,{},u)}
_.info("[QuickEntry] Creating new chat with submit_quick_entry");P2s();
_.info("[QuickEntry] Creating new chat with submit_quick_entry");Z2s();'

@test "quick-window: 7.37095.0 modern contract passes both parts without touching the submit log" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "$QW_MODERN" > "$main_js"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: S7'* ]]
	[[ $output == *'Modern Quick Entry contract verified'* ]]
	[[ $output == *'showMainWindowForSend -> x2s -> b2s(V).show()'* ]]
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
	[[ $(grep -oF 'Creating new chat with submit_quick_entry' "$main_js" | wc -l) -eq 2 ]]
	# Part 1 injects exactly one XDG_CURRENT_DESKTOP guard for blur(); Part 2 must not inject a second guard or isVisible() near submit_quick_entry
	[[ $(grep -oF 'XDG_CURRENT_DESKTOP' "$main_js" | wc -l) -eq 1 ]]
	if grep -qF '.isVisible()' "$main_js"; then
		return 1
	fi

	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Modern Quick Entry contract verified'* ]]
	[[ $(sha256sum "$main_js" | cut -d' ' -f1) == "$before" ]]
}

# Oracle round-2 MAJOR #1 : 添付条件を反転した !u&&s() は、添付がない場合に
# show() を呼ぶ契約であり、添付付き送信の窓口ではない
@test "quick-window: a negated attachment gate cannot prove the show contract" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "$QW_MODERN" | sed 's/u&&s()/!u\&\&s()/' > "$main_js"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'attachment show() is not gated on attached files'* ]]
	grep -qF 'N.info("Quick entry submitted"' "$main_js"
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
}

# Oracle round-2 MAJOR #1 : 長さ0の判定 u=r.length===0;u&&s() も反転条件で
# あり、添付ありのときに show() を呼ばない
@test "quick-window: a zero-length attachment gate cannot prove the show contract" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "$QW_MODERN" | sed 's/u=r.length>0;u&&s()/u=r.length===0;u\&\&s()/' > "$main_js"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'attachment show() is not gated on attached files'* ]]
	grep -qF 'u=r.length===0;u&&s()' "$main_js"
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
}

# Oracle MAJOR #3 : 本物のdismiss呼び出しが消えても、N.info( の中の o( を
# dismissと誤認して成功にしてはいけない
@test "quick-window: a missing dismiss call fails even though N.info( is present" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "$QW_MODERN" | sed 's/;o({},l,{},u)//' > "$main_js"
	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'exactly one show call and one dismiss call'* ]]
	grep -qF 'N.info("Quick entry submitted"' "$main_js"
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
}

# Oracle MAJOR #3 : dismissがshowより先に走る並びは、添付送信の契約ではない
@test "quick-window: a dismiss that runs before the gated show fails" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "$QW_MODERN" | sed 's/u&&s(),N.info("Quick entry submitted",{});o({},l,{},u)/o({},l,{},u);u\&\&s(),N.info("Quick entry submitted",{})/' > "$main_js"
	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'does not show before dismissing'* ]]
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
}

@test "quick-window: a focus-gated showMainWindowForSend fails closed after part 1" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "${QW_MODERN/b2s(V)}/V.isFocused()\&\&b2s(V)}" > "$main_js"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'is focus-gated'* ]]
	grep -qF 'S7.blur(),S7.hide()' "$main_js"
}

@test "quick-window: a missing showMainWindowForSend target fails closed" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' "${QW_MODERN/showMainWindowForSend:()=>x2s/showMainWindowForSend:()=>z2s}" > "$main_js"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Quick window Part 2 could not be proven'* ]]
	[[ $output == *'no function definition for z2s'* ]]
}

@test "quick-window: a quick window without a hide site fails closed" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' 'Il.QUICK_ENTRY),S7.setAlwaysOnTop(!0,"pop-up-menu");' > "$main_js"
	cp "$main_js" "$BATS_TEST_TMPDIR/main.before"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'[FAIL] Expected exactly one unpatched quick window hide() site'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/main.before"
}
