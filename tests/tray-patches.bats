#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file tray-patches.bats
# @brief トレイ関連のパッチが何を書き換え、何を書き換えないかのテスト
#
# Claude 1.44121.4はmenuBarEnabledのコールバックを包み、
# Tray.setImageによる差分更新も既に持っている
# そのため排他制御と遅延のパッチは、ガードを二重に差し込まずに何もしない
#
# アイコン種別の決定は代入からリテラルのswitch("ico")へ変わり、
# LinuxではPNGの分岐へ解決しなければならない
# この形は2.37337.1でも続いており、pngの分岐はテーマに応じて
# TrayIconLinux-Dark.pngとTrayIconLinux.pngを選び分けている
# そのためアイコン選択のパッチは、三項演算子を見つけたら警告ではなくログを出して受け入れる
#
# サーバー側の利用メニュー制御が有効な2.37337.1は、コンテキストメニューを消し、
# right-clickとpopUpContextMenuに頼る
# しかしLinuxはright-clickを配送しない
# そのためLinuxではsetContextMenuの2か所とも制御を飛ばし、利用状況の行は残す
# 左クリックではトレイを開いたことを記録しなければならない

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ
TRAY_SH="$SCRIPT_DIR/../scripts/patches/tray.sh"                # 検証対象のトレイ向けパッチ

#
# @brief テスト用の一時ディレクトリとパッチ対象のindex.jsを用意し、tray.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメインプロセス側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
# @global electron_var バンドル内でElectronモジュールを指す変数名 (本関数で設定する)
# @global electron_var_re 同じ変数名を探すための正規表現 (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	electron_var='o'
	electron_var_re='o'
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/tray.sh
	source "$TRAY_SH"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
# @note setupが途中で失敗してTEST_TMPが未定義でも失敗しないよう、存在を確認してから削除する
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief 1.44121.4以降の形をした固定データを書く
# @global main_js 書き出し先のindex.js (参照のみ)
#
# menuBarEnabledを包む形と、リテラルのswitch("ico")、
# Tray.setImageによる差分更新を同時に持つ
#
write_latest_tray_fixture() {
	printf '%s' \
		'Nx.on("menuBarEnabled",(()=>{I3r()}));var J9=null,Y9=null;function I3r(){B3r(!1)}function z3r(e){switch("ico"){case"ico":return!e&&o.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";case"template-image":return"TrayIconTemplate.png";case"png":return e||QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"}}function B3r(e){let r=z3r(e);if(J9&&!J9.isDestroyed()){r!==Y9&&(J9.setImage(o.nativeImage.createFromPath(r)),Y9=r);return}J9=new o.Tray(o.nativeImage.createFromPath(r))}' \
		> "$main_js"
}

#
# @brief 旧来の形をした固定データを書く
# @global main_js 書き出し先のindex.js (参照のみ)
#
# アイコン種別を代入で決める形で、パッチが旧経路を処理できるかを見る
#
write_legacy_tray_fixture() {
	printf '%s' \
		'var cfg={tray:X="TrayIconTemplate.png"};function Lr(){switch("ico"){case"ico":return"Tray-Win32.ico";case"png":return"TrayIconLinux.png"}}' \
		> "$main_js"
}

#
# @brief アンカーに一致しない形の固定データを書く
# @global main_js 書き出し先のindex.js (参照のみ)
#
# 三項演算子で種別を決める形
# パッチは適用せず警告で止まるべきケース
#
write_anchor_miss_fixture() {
	printf '%s' \
		'var cfg={tray:X="plain.png"};function Mr(){switch(process.platform==="win32"?"ico":"png"){case"ico":return"a.ico";case"png":return"b.png"}}' \
		> "$main_js"
}

#
# @brief 利用メニュー制御を持つ2.37337.1の形をした固定データを書く
# @global main_js 書き出し先のindex.js (参照のみ)
#
# 制御が有効なときはコンテキストメニューを外す実装と、
# クリック・右クリックの処理、setContextMenuの2か所を含む
#
write_usage_gate_fixture() {
	printf '%s' \
		'var a={Tray:class{constructor(){this.calls=[],this.h={}}isDestroyed(){return!1}setContextMenu(m){this.calls.push(m===null?"null":m.label)}on(e,f){this.h[e]=f}popUpContextMenu(){}}};function ry(e){return globalThis.__gates[e]===!0}function B$(){return ry("1109029378")}var N$=1,P$=null,U=0;function WAi(e){if(!N$)return;e?.interaction&&(P$=Date.now())}var Y9=null,Z9=null,FQa=!1,$9=!1;function zji(){return{label:B$()?"usage"+U:"menu"}}function zQa(e){return e.label}function RQa(){if(!Y9||Y9.isDestroyed())return;if(B$()){FQa=!0,Y9.setContextMenu(null),$9=!1;return}let e=zji();$9&&Z9&&zQa(e)===zQa(Z9)||(Z9=e,Y9.setContextMenu(Z9),$9=!0)}function kZa(){return!1}var A=0;function qQa(){A++}function GQa(){Y9=new a.Tray(),Z9=zji(),Y9.on("click",(()=>{kZa()||qQa()})),Y9.on("right-click",(()=>{B$()&&WAi({invalidateInFlight:!1,interaction:!0}),Y9?.popUpContextMenu(Z9)})),B$()||(Y9.setContextMenu(Z9),$9=!0)}module.exports={run(){GQa(),U=1,RQa(),Y9.h.click();return{menus:Y9.calls,trayOpened:P$!==null,activated:A}}};' \
		> "$main_js"
}

#
# @brief トレイを作り、利用状況の変化のあとで更新し、左クリックする
# @param $1 判定させるプラットフォーム
# @param $2 利用メニューの制御 (onなら有効、offなら無効、既定はon)
# @stdout setContextMenuに渡された値、トレイを開いたか、活性化の回数をJSONで出す
#
run_usage_gate_fixture() {
	node -e '
globalThis.__gates = { "1109029378": process.argv[3] !== "off" };
Object.defineProperty(process, "platform", { value: process.argv[2] });
console.log(JSON.stringify(require(process.argv[1]).run()));
' "$main_js" "$1" "${2:-on}"
}

@test "linux tray menu: unpatched usage gate leaves Linux without a menu" {
	write_usage_gate_fixture
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["null"],"trayOpened":false,"activated":1}' ]]
}

@test "linux tray menu: gated menu sites and click handler are patched" {
	write_usage_gate_fixture
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'Found tray usage-menu gate: B$ (tray: Y9)'* ]]
	[[ $output == *'Kept tray context menu attached on Linux'* ]]
	[[ $output == *'Tray left-click records tray open on Linux'* ]]
	[[ $output == *'Patched tray usage menu for the Linux context menu'* ]]
	grep -qF 'if(process.platform!=="linux"&&B$()){FQa=!0,Y9.setContextMenu(null)' \
		"$main_js"
	grep -qF ',process.platform!=="linux"&&B$()||(Y9.setContextMenu(Z9)' \
		"$main_js"
	grep -qF 'Y9.on("click",(()=>{process.platform==="linux"&&B$()&&WAi({invalidateInFlight:!1,interaction:!0});kZa()||qQa()}))' \
		"$main_js"
	grep -qF 'function B$(){return ry("1109029378")}' "$main_js"
}

@test "linux tray menu: Linux keeps usage rows and left-click records tray open" {
	write_usage_gate_fixture
	patch_tray_linux_context_menu >/dev/null
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["usage0","usage1"],"trayOpened":true,"activated":1}' ]]
	run run_usage_gate_fixture linux off
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["menu"],"trayOpened":false,"activated":1}' ]]
	run run_usage_gate_fixture win32
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["null"],"trayOpened":false,"activated":1}' ]]
}

@test "linux tray menu: rerun is idempotent" {
	write_usage_gate_fixture
	patch_tray_linux_context_menu >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'context menu already kept on Linux (idempotent)'* ]]
	[[ $output == *'already records tray open on Linux (idempotent)'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "linux tray menu: spaced, multi-line bundle is patched once" {
	write_usage_gate_fixture
	sed -i \
		-e 's/if(B\$()){FQa=!0,Y9.setContextMenu(null)/if (B$ ()) {\n\t\tFQa = !0, Y9\n\t\t\t.setContextMenu (null)/' \
		-e 's/Y9\.on("click",(()=>{/Y9\n\t.on ("click", (() => {\n\t\t/' \
		-e 's/Y9\.on("right-click",(()=>{B\$()&&WAi({invalidateInFlight:!1,interaction:!0})/Y9.on ("right-click", (() => {\n\t\tB$ () \&\& WAi ({ invalidateInFlight: !1,\n\t\t\tinteraction: !0 })/' \
		-e 's/B\$()||(Y9\.setContextMenu(Z9)/B$ ()\n\t|| (Y9 . setContextMenu (Z9)/' \
		"$main_js"
	[[ $(grep -c . "$main_js") -eq 8 ]]
	run run_usage_gate_fixture linux
	[[ $output == '{"menus":["null"],"trayOpened":false,"activated":1}' ]]
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'Patched tray usage menu for the Linux context menu'* ]]
	grep -qF 'WAi({invalidateInFlight:!1,interaction:!0});' "$main_js"
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["usage0","usage1"],"trayOpened":true,"activated":1}' ]]
	run run_usage_gate_fixture win32
	[[ $output == '{"menus":["null"],"trayOpened":false,"activated":1}' ]]
	local before after
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'(idempotent)'*'(idempotent)'* ]]
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "linux tray menu: missing gated clear warns and leaves bytes unchanged" {
	write_latest_tray_fixture
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_linux_context_menu
	[[ $status -eq 1 ]]
	[[ $output == *'WARNING'*'found 0 and 1'*'patch not applied'* ]]
	[[ $output != *'Patched tray usage menu'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "linux tray menu: missing gated attach warns and leaves bytes unchanged" {
	write_usage_gate_fixture
	sed -i 's/B\$()||(Y9\.setContextMenu(Z9),\$9=!0)/Y9.setContextMenu(Z9)/' \
		"$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_linux_context_menu
	[[ $status -eq 1 ]]
	[[ $output == *'WARNING'*'found 1 and 0'*'patch not applied'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "linux tray menu: unrelated Linux check in click handler is not taken as patched" {
	write_usage_gate_fixture
	sed -i 's/Y9\.on("click",(()=>{kZa()/Y9.on("click",(()=>{process.platform==="linux"\&\&kZa(),kZa()/' \
		"$main_js"
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'Tray left-click records tray open on Linux'* ]]
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["usage0","usage1"],"trayOpened":true,"activated":1}' ]]
}

@test "linux tray menu: click handler starting with a statement stays valid" {
	write_usage_gate_fixture
	sed -i 's/Y9\.on("click",(()=>{kZa()||qQa()}))/Y9.on("click",(()=>{if(kZa())return;qQa()}))/' \
		"$main_js"
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	[[ $output == *'Tray left-click records tray open on Linux'* ]]
	grep -qF 'interaction:!0});if(kZa())return;qQa()}))' "$main_js"
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["usage0","usage1"],"trayOpened":true,"activated":1}' ]]
}

@test "linux tray menu: bundle patched with the old comma form is not patched twice" {
	write_usage_gate_fixture
	patch_tray_linux_context_menu >/dev/null
	sed -i 's/interaction:!0});kZa()||qQa()/interaction:!0}),kZa()||qQa()/' \
		"$main_js"
	grep -qF 'interaction:!0}),kZa()||qQa()}))' "$main_js"
	local before after
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_linux_context_menu
	[[ $status -eq 0 ]]
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "linux tray menu: unknown click handler keeps the menu but warns" {
	write_usage_gate_fixture
	sed -i 's/Y9\.on("click",(()=>{kZa()||qQa()})),//' "$main_js"
	sed -i 's/Y9\.h\.click()/0/' "$main_js"
	run patch_tray_linux_context_menu
	[[ $status -eq 1 ]]
	[[ $output == *'Kept tray context menu attached on Linux'* ]]
	[[ $output == *'WARNING'*"found 0 and 1"*'usage poll stays paused'* ]]
	run run_usage_gate_fixture linux
	[[ $status -eq 0 ]]
	[[ $output == '{"menus":["usage0","usage1"],"trayOpened":false,"activated":0}' ]]
}

@test "latest tray: wrapped settings callback is resolved" {
	write_latest_tray_fixture
	run patch_tray_menu_handler
	[[ $status -eq 0 ]]
	[[ $output == *'updater already updates in place'* ]]
	run grep -qF 'I3r._running' "$main_js"
	[[ $status -eq 1 ]]
}

@test "latest tray: existing in-place update is not reinjected" {
	write_latest_tray_fixture
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_inplace_update
	[[ $status -eq 0 ]]
	[[ $output == *'already has an in-place setImage path'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "latest tray: literal flavor switch selects PNG on Linux" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	grep -qF 'switch(process.platform==="win32"?"ico":"png")' "$main_js"
}

@test "latest tray: icon switch patch is idempotent" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_tray_icon_selection >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "current shape: upstream theme ternary is recognised, not warned" {
	write_latest_tray_fixture
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already handles Linux theme'* ]]
	[[ $output != *'WARNING'* ]]
	run grep -qF '?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' "$main_js"
	[[ $status -eq 0 ]]
}

@test "current shape: rerun reports switch already patched" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already uses PNG on Linux'* ]]
	[[ $output == *'already handles Linux theme'* ]]
}

@test "legacy shape: TrayIconTemplate assignment gains dark variant" {
	write_legacy_tray_fixture
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'Patched tray icon selection for Linux theme support'* ]]
	grep -qF 'X=o.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"' \
		"$main_js"
}

@test "legacy shape: rerun distinguishes already-patched" {
	write_legacy_tray_fixture
	patch_tray_icon_selection >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "anchor miss: warns on stderr and leaves bytes unchanged" {
	write_anchor_miss_fixture
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'*'theme-selection anchor not found'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}
