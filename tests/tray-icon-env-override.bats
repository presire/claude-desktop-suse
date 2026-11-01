#!/usr/bin/env bats
# shellcheck disable=SC2016 # JavaScriptを文字列リテラルとして渡す
#
# @file tray-icon-env-override.bats
# @brief 環境変数でトレイアイコンの明暗を上書きするパッチのテスト
#
# patch_tray_icon_env_overrideは、上流のTrayIconLinuxの三項演算子に
# CLAUDE_TRAY_USE_DARK_ICONの判定を差し込む
# claude-desktop-debianのtests/tray-icon-selection.batsからの移植で、#604 / #820 / #876 に関係する
#
# 惜しい形の固定データは、わざとアンカーから1箇所だけずらしてある
# 正規表現を緩める、一致件数がちょうど1件という確認を外す、
# 差し込み前のガードを外す、のいずれかをすると
# 本来は失敗すべきケースが通ってしまい、このテストが落ちる

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ

#
# @brief パッチ対象のチャンクを置くディレクトリを用意し、tray.shを読み込む
# @global build_dir パッチ対象のチャンクを置くディレクトリ (本関数で設定する)
# @global main_js パッチ対象のチャンク (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
# @global suse_ternary 固定したSUSE向けバンドルが持つ三項演算子 (本関数で設定する)
# @global suse_patched そのパッチ適用後に期待する形 (本関数で設定する)
# @global upstream_ternary 上流のチャンクが持つ三項演算子 (本関数で設定する)
# @global patched_expr そのパッチ適用後に期待する式 (本関数で設定する)
# @global chain_ternary 呼び出し先がプロパティの連鎖になっている形 (本関数で設定する)
# @global chain_patched そのパッチ適用後に期待する式 (本関数で設定する)
# @global mispatched_ternary 誤って適用されたときの形 (検出できることを確かめる)
#
setup() {
	build_dir="$BATS_TEST_TMPDIR/.vite/build"
	mkdir -p "$build_dir"
	main_js="$build_dir/index.chunk-test.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/tray.sh
	source "$SCRIPT_DIR/../scripts/patches/tray.sh"

	# 固定したSUSE向けバンドルが持つ形
	# tray-patches.batsも参照
	suse_ternary='case"png":return e||QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'
	suse_patched='return e||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	upstream_ternary='case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	patched_expr='process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	# 呼び出し先がプロパティの連鎖になっている形
	# #820の誤適用は、三状態の判定を残ったp.に貼り付けてしまった
	# 先頭のt=が、差し込みを始める位置を固定する役目を持つ
	chain_ternary='case`png`:t=p.lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	chain_patched='t=process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(p.lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	mispatched_ternary='case`png`:t=p.process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
}

#
# @brief パッチ対象のチャンクに中身を書き込む
# @param $1 チャンクに書くJavaScript
# @global main_js 書き込み先のチャンク (参照のみ)
#
_write_chunk() {
	printf '%s\n' "$1" > "$main_js"
}

_assert_chunk_untouched() {
	run grep -qF 'CLAUDE_TRAY_USE_DARK_ICON' "$main_js"
	[[ $status -ne 0 ]]
}

@test "tray env override: patches the pinned SUSE bundle shape" {
	_write_chunk "$suse_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "$suse_patched" "$main_js"
}

@test "tray env override: injects tri-state guard inside the ternary" {
	_write_chunk "$upstream_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "t=$patched_expr" "$main_js"
}

@test "tray env override: matches the beautified-spacing form" {
	cat > "$main_js" << 'EOF'
        t =
          oPe() === "gnome" || G.nativeTheme.shouldUseDarkColors
            ? "TrayIconLinux-Dark.png"
            : "TrayIconLinux.png";
EOF
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "$patched_expr" "$main_js"
}

@test "tray env override: idempotent and byte-identical on re-run" {
	_write_chunk "$suse_ternary"
	patch_tray_icon_env_override
	cp "$main_js" "$BATS_TEST_TMPDIR/first-run.js"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'already applied'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/first-run.js"
}

@test "tray env override: icon selection still recognises the patched ternary" {
	# PATCH_STAGE_RERUNで、このパッチが書き換えた後のチャンクに
	# patch_tray_icon_selectionを再実行する
	# 警告ではなくログを出すべき
	electron_var_re='o'
	_write_chunk "function z(e){switch(process.platform===\"win32\"?\"ico\":\"png\"){$suse_ternary}}"
	patch_tray_icon_env_override
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already handles Linux theme'* ]]
	[[ $output != *WARNING* ]]
}

@test "tray env override: bundle without the literals is skipped with a warning" {
	_write_chunk 'case"png":return"TrayIconTemplate.png"'
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'CLAUDE_TRAY_USE_DARK_ICON is inert'* ]]
	_assert_chunk_untouched
}

@test "tray env override: Win32 ico lookalike is not patched" {
	_write_chunk 'case"ico":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";break'
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'inert'* ]]
	_assert_chunk_untouched
}

@test "tray env override: near-miss without the GNOME half fails" {
	_write_chunk 'case"png":t=G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'found 0'* ]]
	_assert_chunk_untouched
}

@test "tray env override: duplicate anchor site fails" {
	_write_chunk "$upstream_ternary$upstream_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'found 2'* ]]
}

@test "tray env override: bundler indirect-call shape patches" {
	_write_chunk 'case"png":t=(0,Ei.oPe)()==="gnome"||Ei.G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF '!=="0"&&((0,Ei.oPe)()==="gnome"||Ei.G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png"' \
		"$main_js"
}

@test "tray env override: property-chain callee keeps its prefix" {
	_write_chunk "$chain_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "$chain_patched" "$main_js"
}

@test "tray env override: near-miss optional-chaining callee fails" {
	_write_chunk 'case`png`:t=p?.lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray env override: near-miss await-prefixed callee fails" {
	_write_chunk 'case`png`:t=await lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray env override: near-miss private-name callee fails" {
	_write_chunk 'case`png`:t=this.#lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray env override: near-miss comparison-prefixed callee fails" {
	local prefix
	for prefix in 'a===' 'a!==' 'a<=' 'a>=' 'a=='; do
		_write_chunk "case\`png\`:t=${prefix}oPe()===\`gnome\`||R.nativeTheme.shouldUseDarkColors?\`TrayIconLinux-Dark.png\`:\`TrayIconLinux.png\`;break"
		run patch_tray_icon_env_override
		[[ $status -eq 1 ]]
		[[ $output == *'matched mid-expression'* ]]
		_assert_chunk_untouched
	done
}

@test "tray env override: near-miss bitwise-or-prefixed callee fails" {
	_write_chunk 'case`png`:t=a|oPe()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray env override: compound-assignment prefix still patches" {
	_write_chunk 'case`png`:t+=oPe()===`gnome`||G.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "t+=$patched_expr" "$main_js"
}

@test "tray env override: arrow-body ternary patches" {
	_write_chunk 'let f=()=>oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";'
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "=>$patched_expr" "$main_js"
}

@test "tray env override: an already-mispatched bundle fails loudly" {
	_write_chunk "$mispatched_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'bundle is corrupt'* ]]
}

@test "tray env override: resolves the anchor from a sibling chunk" {
	printf '%s\n' 'require("./other.js")' > "$main_js"
	printf '%s\n' "$suse_ternary" > "$build_dir/index.js"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF "$suse_patched" "$build_dir/index.js"
}

@test "tray env override: literals in two sibling chunks fail" {
	printf '%s\n' 'require("./other.js")' > "$main_js"
	printf '%s\n' "$suse_ternary" > "$build_dir/a.js"
	printf '%s\n' "$suse_ternary" > "$build_dir/b.js"
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'refusing to guess'* ]]
}

@test "tray env override: runtime truth table on the SUSE shape" {
	# パッチ後のテキストを実際に動かす
	# eは上流がトレイを作り直すときに立てるフラグである
	# 通常の起動では0なので通常のアイコンに固定できるが、
	# 作り直しのときはe||の判定に勝てない(Debian #876、アンカーが届く範囲の限界)
	_write_chunk "function icon(e){switch(\"png\"){$suse_ternary}}"
	patch_tray_icon_env_override
	cat > "$BATS_TEST_TMPDIR/run.js" <<-'EOF'
		const fs = require('fs');
		const path = require('path');
		const src = fs.readFileSync(process.argv[2], 'utf8');
		const prelude = 'const QVt=()=>"kde";' +
			'const o={nativeTheme:{shouldUseDarkColors:false}};';
		const mod = path.join(path.dirname(process.argv[2]), 'mod.js');
		fs.writeFileSync(mod, prelude + src + ';module.exports=icon;');
		const icon = require(mod);
		console.log(icon(false), icon(true));
	EOF

	run env CLAUDE_TRAY_USE_DARK_ICON=1 node "$BATS_TEST_TMPDIR/run.js" \
		"$main_js"
	[[ $status -eq 0 ]]
	[[ $output == 'TrayIconLinux-Dark.png TrayIconLinux-Dark.png' ]]

	run env CLAUDE_TRAY_USE_DARK_ICON=0 node "$BATS_TEST_TMPDIR/run.js" \
		"$main_js"
	[[ $status -eq 0 ]]
	[[ $output == 'TrayIconLinux.png TrayIconLinux-Dark.png' ]]

	run env -u CLAUDE_TRAY_USE_DARK_ICON node \
		"$BATS_TEST_TMPDIR/run.js" "$main_js"
	[[ $status -eq 0 ]]
	[[ $output == 'TrayIconLinux.png TrayIconLinux-Dark.png' ]]
}
