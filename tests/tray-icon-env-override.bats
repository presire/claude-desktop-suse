#!/usr/bin/env bats
# shellcheck disable=SC2016  # Literal JS fixtures
#
# tray-icon-env-override.bats
#
# patch_tray_icon_env_override threads CLAUDE_TRAY_USE_DARK_ICON into
# upstream's TrayIconLinux ternary (ported from claude-desktop-debian
# tests/tray-icon-selection.bats, #604/#820/#876). The near-miss
# fixtures sit one edit away from the anchor on purpose: loosening the
# regex, dropping the exactly-1 assertion or dropping the pre-splice
# guard turns their expected hard-fail into a pass and goes red.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	build_dir="$BATS_TEST_TMPDIR/.vite/build"
	mkdir -p "$build_dir"
	main_js="$build_dir/index.chunk-test.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/tray.sh
	source "$SCRIPT_DIR/../scripts/patches/tray.sh"

	# The shape the pinned SUSE bundle ships (see tray-patches.bats).
	suse_ternary='case"png":return e||QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'
	suse_patched='return e||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	upstream_ternary='case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	patched_expr='process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	# Property-chain callee: the #820 mispatch glued the tri-state onto
	# the retained `p.`; the leading `t=` pins the splice start.
	chain_ternary='case`png`:t=p.lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	chain_patched='t=process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(p.lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	mispatched_ternary='case`png`:t=p.process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
}

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
	# PATCH_STAGE_RERUN replays patch_tray_icon_selection over a chunk
	# this patch already rewrote; it must log, not warn.
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
	# Runs the patched text. `e` is upstream's tray rebuild flag: =0
	# pins the plain glyph on a normal launch but cannot beat `e||`
	# on a rebuild (Debian #876, a limit of the anchor's reach).
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
