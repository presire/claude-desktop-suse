#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030  # JS fixture strings + per-test subshell locals
#
# resolve-main-js.bats
#
# Tests for the code-split main-process chunk resolution (_resolve_main_js
# in scripts/patches/_common.sh), the MB-1 tripwire helper
# (_check_mb1_tripwire), and the verify-patches.sh integration that
# follows the same resolver.
#
# Since upstream 1.19367.0, .vite/build/index.js is a stub that
# require()s index.chunk-<hash>.js. Patches must target the chunk, not
# the stub. These tests exercise the resolver's safe-name regex,
# fail-closed behavior, legacy fallback, and verify-patches wiring.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"
VERIFY_SH="$SCRIPT_DIR/../scripts/verify-patches.sh"
PATCH_DIR="$SCRIPT_DIR/../scripts/patches"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	BUILD_DIR="$TEST_TMP/app.asar.contents/.vite/build"
	mkdir -p "$BUILD_DIR"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# Helper: write a stub index.js
# =============================================================================
write_stub() {
	local content="$1"
	printf '%s\n' "$content" > "$BUILD_DIR/index.js"
	printf '%s\n' "$BUILD_DIR/index.js"
}

# Helper: write a chunk file
write_chunk() {
	local name="$1"
	local content="$2"
	printf '%s\n' "$content" > "$BUILD_DIR/$name"
	printf '%s\n' "$BUILD_DIR/$name"
}

# =============================================================================
# _resolve_main_js: legacy monolithic bundles
# =============================================================================

@test "legacy: monolithic index.js (no chunk requires) resolves to itself" {
	local stub
	stub=$(write_stub 'var e=require("electron");console.log("main process");')
	local resolved
	resolved=$(_resolve_main_js "$stub")
	[[ "$status" -eq 0 || $? -eq 0 ]]
	[[ "$resolved" == "$BUILD_DIR/index.js" ]]
}

@test "legacy: index.js with bare module requires (no chunk) resolves to itself" {
	local stub
	stub=$(write_stub 'var e=require("electron");var p=require("path");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$BUILD_DIR/index.js" ]]
}

@test "legacy: index.js referencing unrelated chunk names resolves to itself" {
	local stub
	stub=$(write_stub 'require("./renderer.chunk-abc123.js");require("electron");')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$BUILD_DIR/index.js" ]]
}

# =============================================================================
# _resolve_main_js: code-split stub → chunk
# =============================================================================

@test "split: single direct stub reference resolves to chunk" {
	local stub
	stub=$(write_stub 'require("./index.chunk-YOlx50gU.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-YOlx50gU.js" 'var e=require("electron");menuBarEnabled:!0;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "split: stub reference with unrelated chunk files ignores unreferenced chunks" {
	local stub
	stub=$(write_stub 'require("./index.chunk-abc123.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-abc123.js" 'var e=require("electron");')
	# Create unrelated chunk files that should be ignored
	write_chunk "index.chunk-def456.js" 'unreferenced;'
	write_chunk "renderer.chunk-xyz.js" 'unreferenced;'
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "split: double-quote require form resolves" {
	local stub
	stub=$(write_stub 'module.exports=require("./index.chunk-double1.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-double1.js" 'var x=1;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "split: single-quote require form resolves" {
	local stub
	stub=$(write_stub "require('./index.chunk-single1.js');")
	local chunk
	chunk=$(write_chunk "index.chunk-single1.js" 'var x=1;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "split: whitespace inside require() is tolerated" {
	local stub
	stub=$(write_stub 'require( "./index.chunk-ws1.js" );')
	local chunk
	chunk=$(write_chunk "index.chunk-ws1.js" 'var x=1;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "split: whitespace between require and paren is tolerated" {
	local stub
	stub=$(write_stub "require ( './index.chunk-ws2.js' );")
	local chunk
	chunk=$(write_chunk "index.chunk-ws2.js" 'var x=1;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

@test "error: mismatched require quotes are not accepted" {
	local stub
	stub=$(write_stub 'require("./index.chunk-mismatch.js'\'' );')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$BUILD_DIR/index.js" ]]
}

@test "split: multiple require calls but only one chunk reference resolves" {
	local stub
	stub=$(write_stub 'var e=require("electron");var p=require("path");require("./index.chunk-multi1.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-multi1.js" 'var x=1;')
	local resolved
	resolved=$(_resolve_main_js "$stub") || return 1
	[[ "$resolved" == "$chunk" ]]
}

# =============================================================================
# _resolve_main_js: unreferenced chunk markers not accepted
# =============================================================================

@test "ignore: chunk filename in a plain string (not require) does not trigger split" {
	local stub
	stub=$(write_stub 'var msg="loading index.chunk-plain.js";require("electron");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$BUILD_DIR/index.js" ]]
}

@test "ignore: chunk filename in a variable assignment does not trigger split" {
	local stub
	stub=$(write_stub 'var chunkName="index.chunk-varassign.js";require("electron");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$BUILD_DIR/index.js" ]]
}

# =============================================================================
# _resolve_main_js: error / fail-closed cases
# =============================================================================

@test "error: missing index.js returns 1" {
	run _resolve_main_js "$BUILD_DIR/nonexistent.js"
	[[ "$status" -eq 1 ]]
}

@test "error: no argument returns 1" {
	run _resolve_main_js
	[[ "$status" -eq 1 ]]
}

@test "error: zero-byte index.js returns 1" {
	: > "$BUILD_DIR/index.js"
	run _resolve_main_js "$BUILD_DIR/index.js"
	[[ "$status" -eq 1 ]]
}

@test "error: missing referenced chunk returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-missing.js");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"not found"* ]]
}

@test "error: zero-byte referenced chunk returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-zero.js");')
	: > "$BUILD_DIR/index.chunk-zero.js"
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
}

@test "error: multiple direct chunk references returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-first.js");require("./index.chunk-second.js");')
	write_chunk "index.chunk-first.js" 'var x=1;'
	write_chunk "index.chunk-second.js" 'var y=2;'
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"multiple"* ]]
}

@test "error: path traversal in chunk reference returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-../../etc/passwd");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"malformed/unsafe"* ]]
}

@test "error: embedded slash in chunk reference returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-foo/bar.js");')
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"malformed/unsafe"* ]]
}

@test "error: unsafe chunk reference does not fall back to legacy" {
	local stub
	stub=$(write_stub 'require("./index.chunk-../../etc/passwd");')
	# Even though the stub is clearly a stub (has a require), the
	# unsafe reference must NOT cause it to be treated as monolithic.
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
	[[ "$output" != *"$BUILD_DIR/index.js"* ]]
}

@test "error: mixed safe and unsafe chunk references returns 1" {
	local stub
	stub=$(write_stub 'require("./index.chunk-safe.js");require("./index.chunk-../bad.js");')
	write_chunk "index.chunk-safe.js" 'var x=1;'
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
}

@test "error: chunk with empty hash part (index.chunk-.js) is unsafe" {
	local stub
	stub=$(write_stub 'require("./index.chunk-.js");')
	write_chunk "index.chunk-.js" 'var x=1;'
	run _resolve_main_js "$stub"
	[[ "$status" -eq 1 ]]
}

# =============================================================================
# _check_mb1_tripwire
# =============================================================================

@test "mb1: present in monolithic index.js returns 0" {
	local stub
	stub=$(write_stub 'var e=require("electron");menuBarEnabled:!0;')
	run _check_mb1_tripwire "$stub"
	[[ "$status" -eq 0 ]]
}

@test "mb1: present only in chunk (not stub) returns 0" {
	local stub
	stub=$(write_stub 'require("./index.chunk-mb1.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-mb1.js" 'var settings={menuBarEnabled:!0};')
	run _check_mb1_tripwire "$chunk"
	[[ "$status" -eq 0 ]]
}

@test "mb1: absent returns 1" {
	local stub
	stub=$(write_stub 'var e=require("electron");menuBarEnabled:!1;')
	run _check_mb1_tripwire "$stub"
	[[ "$status" -eq 1 ]]
}

@test "mb1: missing path returns 1" {
	run _check_mb1_tripwire "$BUILD_DIR/nonexistent.js"
	[[ "$status" -eq 1 ]]
}

@test "mb1: no argument returns 1" {
	run _check_mb1_tripwire
	[[ "$status" -eq 1 ]]
}

@test "mb1: whitespace variant menuBarEnabled: !0 is accepted" {
	local stub
	stub=$(write_stub 'var settings={menuBarEnabled: !0};')
	run _check_mb1_tripwire "$stub"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# verify-patches.sh: chunk resolution integration
# =============================================================================

# Source verify-patches.sh for its load_markers (shared with verify-patches.bats)
setup_verify() {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/verify-patches.sh
	source "$VERIFY_SH"
	load_markers
}

@test "verify: directory with code-split stub resolves chunk for markers" {
	setup_verify
	local stub="$BUILD_DIR/index.js"
	printf '%s\n' 'require("./index.chunk-verify1.js");' > "$stub"
	local chunk="$BUILD_DIR/index.chunk-verify1.js"
	: > "$chunk"
	local sample
	for sample in "${marker_samples[@]}"; do
		printf '%s\n' "$sample" >> "$chunk"
	done
	# Build the directory layout verify-patches expects
	local staging="$TEST_TMP/staging"
	mkdir -p "$staging/app.asar.contents/.vite/build"
	cp "$stub" "$staging/app.asar.contents/.vite/build/index.js"
	cp "$chunk" "$staging/app.asar.contents/.vite/build/index.chunk-verify1.js"
	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected code-split directory input'
		echo "$output"
		return 1
	}
}

@test "verify: direct chunk file input works (treated as monolithic)" {
	setup_verify
	local chunk="$BUILD_DIR/index.chunk-direct.js"
	: > "$chunk"
	local sample
	for sample in "${marker_samples[@]}"; do
		printf '%s\n' "$sample" >> "$chunk"
	done
	run "$VERIFY_SH" "$chunk"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected direct chunk file input'
		echo "$output"
		return 1
	}
}

@test "verify: directory with code-split stub but missing chunk fails" {
	local stub="$BUILD_DIR/index.js"
	printf '%s\n' 'require("./index.chunk-gone.js");' > "$stub"
	local staging="$TEST_TMP/staging"
	mkdir -p "$staging/app.asar.contents/.vite/build"
	cp "$stub" "$staging/app.asar.contents/.vite/build/index.js"
	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 1 ]]
}

@test "verify: directory with code-split stub but unsafe chunk fails" {
	local stub="$BUILD_DIR/index.js"
	printf '%s\n' 'require("./index.chunk-../../bad.js");' > "$stub"
	local staging="$TEST_TMP/staging"
	mkdir -p "$staging/app.asar.contents/.vite/build"
	cp "$stub" "$staging/app.asar.contents/.vite/build/index.js"
	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 1 ]]
}

@test "verify: directory with legacy monolithic index.js still works" {
	setup_verify
	local staging="$TEST_TMP/staging"
	mkdir -p "$staging/app.asar.contents/.vite/build"
	: > "$staging/app.asar.contents/.vite/build/index.js"
	local sample
	for sample in "${marker_samples[@]}"; do
		printf '%s\n' "$sample" >> "$staging/app.asar.contents/.vite/build/index.js"
	done
	run "$VERIFY_SH" "$staging"
	[[ "$status" -eq 0 ]]
}

@test "verify: resolve_index_js sets resolved_main_js for chunk layout" {
	setup_verify
	local stub="$BUILD_DIR/index.js"
	printf '%s\n' 'require("./index.chunk-rij.js");' > "$stub"
	local chunk="$BUILD_DIR/index.chunk-rij.js"
	printf '%s\n' 'menuBarEnabled:!0' > "$chunk"
	local staging="$TEST_TMP/staging"
	mkdir -p "$staging/app.asar.contents/.vite/build"
	cp "$stub" "$staging/app.asar.contents/.vite/build/index.js"
	cp "$chunk" "$staging/app.asar.contents/.vite/build/index.chunk-rij.js"
	resolve_index_js "$staging" || return 1
	[[ "$resolved_main_js" == *"/index.chunk-rij.js" ]]
}

# =============================================================================
# Patch idempotency: same bytes after second application
# =============================================================================

@test "idempotency: patch_exit_accelerator applied twice yields same bytes" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/exit-accelerator.sh
	source "$PATCH_DIR/exit-accelerator.sh"
	local fixture="$TEST_TMP/fixture.js"
	local anchor='description:"Menu item for exiting the application"}),click:function(){}'
	printf '%s' "$anchor" > "$fixture"
	main_js="$fixture" patch_exit_accelerator >/dev/null 2>&1
	local hash1
	hash1=$(sha256sum "$fixture" | cut -d' ' -f1)
	main_js="$fixture" patch_exit_accelerator >/dev/null 2>&1
	local hash2
	hash2=$(sha256sum "$fixture" | cut -d' ' -f1)
	[[ "$hash1" == "$hash2" ]] || {
		echo "idempotency failed: hash1=$hash1 hash2=$hash2"
		return 1
	}
}

@test "idempotency: patch_org_plugins_path applied twice yields same bytes" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/org-plugins.sh
	source "$PATCH_DIR/org-plugins.sh"
	local fixture="$TEST_TMP/fixture.js"
	local anchor='"org-plugins");default:return null}'
	printf '%s' "$anchor" > "$fixture"
	main_js="$fixture" patch_org_plugins_path >/dev/null 2>&1
	local hash1
	hash1=$(sha256sum "$fixture" | cut -d' ' -f1)
	main_js="$fixture" patch_org_plugins_path >/dev/null 2>&1
	local hash2
	hash2=$(sha256sum "$fixture" | cut -d' ' -f1)
	[[ "$hash1" == "$hash2" ]] || {
		echo "idempotency failed: hash1=$hash1 hash2=$hash2"
		return 1
	}
}

# =============================================================================
# patch_asar_argv_file_drop_guard: async argv collector
# =============================================================================

@test "asar file-drop guard: patches the async stat collector" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$PATCH_DIR/cowork.sh"
	local fixture="$TEST_TMP/fixture.js"
	printf '%s' \
		'const $stat = $param.startsWith( "-" ) ? null : await $fs( $param );if($stat!=null&&$stat.isDirectory()){$dispatch($param,$handler,"folder");continue}' \
		> "$fixture"
	main_js="$fixture"

	run patch_asar_argv_file_drop_guard
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}
	grep -qF '$param.startsWith("-")||$param.endsWith(".asar")?null:await $fs($param)' \
		"$fixture"
}

@test "asar file-drop guard: applying twice is byte-idempotent" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$PATCH_DIR/cowork.sh"
	local fixture="$TEST_TMP/fixture.js"
	printf '%s' \
		'const a=p.startsWith("-")?null:await stat(p);if(a!=null&&a.isDirectory()){open(p,h,"folder");continue}' \
		> "$fixture"
	main_js="$fixture"

	run patch_asar_argv_file_drop_guard
	[[ "$status" -eq 0 ]] || return 1
	local hash1
	hash1=$(sha256sum "$fixture" | cut -d' ' -f1)
	run patch_asar_argv_file_drop_guard
	[[ "$status" -eq 0 ]] || return 1
	local hash2
	hash2=$(sha256sum "$fixture" | cut -d' ' -f1)
	[[ "$hash1" == "$hash2" ]] || {
		echo "idempotency failed: hash1=$hash1 hash2=$hash2"
		return 1
	}
}

@test "asar file-drop guard: fails closed when the async anchor is absent" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$PATCH_DIR/cowork.sh"
	local fixture="$TEST_TMP/fixture.js"
	printf '%s' 'const unrelated=true;' > "$fixture"
	main_js="$fixture"

	run patch_asar_argv_file_drop_guard
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'FATAL:'* ]]
}

@test "asar file-drop guard: fails closed on multiple async anchors" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$PATCH_DIR/cowork.sh"
	local fixture="$TEST_TMP/fixture.js"
	printf '%s\n%s' \
		'const a=p.startsWith("-")?null:await stat(p);' \
		'const b=p.startsWith("-")?null:await stat(p);' \
		> "$fixture"
	main_js="$fixture"

	run patch_asar_argv_file_drop_guard
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'matched 2 times'* ]]
}

# =============================================================================
# patch_asar_additional_dirs_guard: cross-chunk --add-dir filtering
# =============================================================================

@test "asar adddir guard: patches a safe sibling chunk" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$PATCH_DIR/config.sh"
	local main="$BUILD_DIR/index.chunk-main.js"
	local sibling="$BUILD_DIR/index.chunk-secondary.js"
	printf '%s' 'const mainChunk=true;' > "$main"
	printf '%s' 'for(let P of t)ne.push("--add-dir",P)' > "$sibling"
	main_js="$main"

	run patch_asar_additional_dirs_guard
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}
	grep -qF \
		'for(let P of t.filter(_d=>!_d.endsWith(".asar")))ne.push("--add-dir",P)' \
		"$sibling"
}

@test "asar adddir guard: patches session restore in another chunk" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$PATCH_DIR/config.sh"
	local main="$BUILD_DIR/index.chunk-main.js"
	local dispatch="$BUILD_DIR/index.chunk-dispatch.js"
	local session="$BUILD_DIR/index.chunk-session.js"
	printf '%s' 'const mainChunk=true;' > "$main"
	printf '%s' 'for(let P of t)ne.push("--add-dir",P)' > "$dispatch"
	printf '%s' '(d.userSelectedFolders||[]).map(async m=>m)' > "$session"
	main_js="$main"

	run patch_asar_additional_dirs_guard
	[[ "$status" -eq 0 ]] || return 1
	grep -qF \
		'(d.userSelectedFolders||[]).filter(_d=>!_d.endsWith(".asar")).map' \
		"$session"
}

@test "asar adddir guard: cross-chunk application is byte-idempotent" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$PATCH_DIR/config.sh"
	local main="$BUILD_DIR/index.chunk-main.js"
	local dispatch="$BUILD_DIR/index.chunk-dispatch.js"
	local session="$BUILD_DIR/index.chunk-session.js"
	printf '%s' 'const mainChunk=true;' > "$main"
	printf '%s' 'for(let P of t)ne.push("--add-dir",P)' > "$dispatch"
	printf '%s' '(d.userSelectedFolders||[]).map(async m=>m)' > "$session"
	main_js="$main"

	run patch_asar_additional_dirs_guard
	[[ "$status" -eq 0 ]] || return 1
	local hash1
	hash1=$(sha256sum "$dispatch" "$session" | sha256sum | cut -d' ' -f1)
	run patch_asar_additional_dirs_guard
	[[ "$status" -eq 0 ]] || return 1
	local hash2
	hash2=$(sha256sum "$dispatch" "$session" | sha256sum | cut -d' ' -f1)
	[[ "$hash1" == "$hash2" ]]
}

@test "asar adddir guard: fails closed on duplicate sibling dispatches" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$PATCH_DIR/config.sh"
	local main="$BUILD_DIR/index.chunk-main.js"
	local first="$BUILD_DIR/index.chunk-first.js"
	local second="$BUILD_DIR/index.chunk-second.js"
	printf '%s' 'const mainChunk=true;' > "$main"
	printf '%s' 'for(let P of t)ne.push("--add-dir",P)' > "$first"
	printf '%s' 'for(let Q of u)nx.push("--add-dir",Q)' > "$second"
	main_js="$main"

	run patch_asar_additional_dirs_guard
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'ambiguous candidates'* ]]
}

@test "asar adddir guard: fails closed when no sibling dispatch exists" {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$PATCH_DIR/config.sh"
	local main="$BUILD_DIR/index.chunk-main.js"
	local sibling="$BUILD_DIR/index.chunk-secondary.js"
	printf '%s' 'const mainChunk=true;' > "$main"
	printf '%s' 'const unrelated=true;' > "$sibling"
	main_js="$main"

	run patch_asar_additional_dirs_guard
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'FATAL:'* ]]
}

# =============================================================================
# _resolve_main_js: read-only / idempotent
# =============================================================================

@test "readonly: _resolve_main_js does not modify the stub" {
	local stub
	stub=$(write_stub 'require("./index.chunk-ro.js");')
	write_chunk "index.chunk-ro.js" 'var x=1;'
	local before
	before=$(sha256sum "$BUILD_DIR/index.js" | cut -d' ' -f1)
	_resolve_main_js "$BUILD_DIR/index.js" >/dev/null 2>&1 || true
	local after
	after=$(sha256sum "$BUILD_DIR/index.js" | cut -d' ' -f1)
	[[ "$before" == "$after" ]]
}

@test "readonly: _resolve_main_js does not modify the chunk" {
	local stub
	stub=$(write_stub 'require("./index.chunk-ro2.js");')
	local chunk
	chunk=$(write_chunk "index.chunk-ro2.js" 'var x=1;')
	local before
	before=$(sha256sum "$chunk" | cut -d' ' -f1)
	_resolve_main_js "$BUILD_DIR/index.js" >/dev/null 2>&1 || true
	local after
	after=$(sha256sum "$chunk" | cut -d' ' -f1)
	[[ "$before" == "$after" ]]
}
