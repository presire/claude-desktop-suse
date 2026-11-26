#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file updater-d001.bats
# @brief Linuxで自動更新と更新メタデータの取得を止めるパッチ (D-001) の検証
#
# 7.37095.0のバンドルには、自動更新の有効判定、更新チェックの入口、
# 更新メタデータの取得という3つの経路がある。Linuxには更新経路が無いため、
# すべてを早期returnで塞ぐ。1つでも塞ぎ漏らすと、起動時や手動チェックで
# net.fetchが走る。
#
# 確認する性質は次のとおり
#
#   * 3か所すべてを、minifyされた識別子に依存せずに適用する
#   * どれか1か所でもアンカーが無い、または曖昧なら、何も書き換えずに失敗する
#   * 2回目の実行でバイト列が変わらない
#   * 適用後のコードを実行すると、Oz()はfalse、Hki()は"skipped"、
#     gki()は{status:204,ok:false}を返し、net.fetchは一度も呼ばれない
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルのディレクトリ
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"           # パッチ共通の補助関数
APP_ASAR_SH="$SCRIPT_DIR/../scripts/patches/app-asar.sh"        # パッチ段階の実行補助
UPDATER_SH="$SCRIPT_DIR/../scripts/patches/updater.sh"          # 検証対象の更新向けパッチ
REAL_BUNDLE_DIR="${CLAUDE_DESKTOP_737095_DIR:-/tmp/opencode/probe-7.37095.0/asar_out}/.vite/build"

#
# @brief テスト用の一時ディレクトリを用意し、パッチを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメイン側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/app-asar.sh
	source "$APP_ASAR_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/updater.sh
	source "$UPDATER_SH"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief 3つの更新経路を持つ最小のバンドルを書く
# @global TEST_TMP 書き込み先の一時ディレクトリ (参照のみ)
# @global main_js 書き込むファイル (参照のみ)
# @note 識別子は実際のminify名ではなく、パッチが構造だけで対象を決めることを示す
#
write_updater_fixture() {
	cat > "$main_js" << 'FIXTURE'
const tz={forceInstalled:!1};const u={app:{isPackaged:!0,getPath:()=>"/app"},net:{fetch:()=>{throw new Error("NET_FETCH_CALLED")}}};const n={default:{dirname:()=>"/app",resolve:()=>"/app/update.exe"}};const a={default:{existsSync:()=>!0}};function la(){return!1}
function tgi(){return N.info("[updater] App is not installed, not enabling auto-updates"),Z("desktop_update_disabled",{reason:"not_installed"})}
function Zz(){if(tz.forceInstalled)return!0;if(process.platform!=="win32")return u.app.isPackaged;if(!u.app.isPackaged)return!1;if(la())return!0;let e=n.default.dirname(u.app.getPath("exe")),t=n.default.resolve(e,"..","update.exe");return a.default.existsSync(t)}
async function Wq(){let e=!Tz.isManualCheck&&await BCi();if(kz)return N.info("[updater] Skipping update check: held for the move to the modern installer"),"skipped";if(J().autoUpdate.disabled)return N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy"),Nki(),"skipped";return"checked"}
async function Vk(e){return u.net.fetch(dki(qOi,"msix",e))}
FIXTURE
}

@test "applies the three Linux updater guards without minified identifiers" {
	write_updater_fixture
	run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	[[ $output == *'Oz(): Linux returns false'* ]]
	[[ $output == *'Hki(): Linux returns'* ]]
	[[ $output == *'gki(): Linux returns {status:204,ok:false}'* ]]
	grep -qF 'function Zz(){if(process.platform==="linux")return!1;if(tz.forceInstalled)' "$main_js"
	grep -qF 'async function Wq(){if(process.platform==="linux")return"skipped";' "$main_js"
	grep -qF 'async function Vk(e){if(process.platform==="linux")return{status:204,ok:!1};return' "$main_js"
}

@test "second run keeps the bundle byte-identical" {
	write_updater_fixture
	patch_disable_auto_updater > /dev/null
	cp "$main_js" "$TEST_TMP/once.js"
	run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	[[ $output == *'already'* ]]
	cmp "$main_js" "$TEST_TMP/once.js"
}

@test "a missing Oz anchor fails closed without writing" {
	write_updater_fixture
	sed -i 's/process\.platform!=="win32")return u\.app\.isPackaged/process.platform!=="linux")return u.app.isPackaged/' "$main_js"
	cp "$main_js" "$TEST_TMP/before.js"
	run patch_disable_auto_updater
	[[ $status -ne 0 ]]
	[[ $output == *'Oz() auto-update gate'* ]]
	cmp "$main_js" "$TEST_TMP/before.js"
}

@test "a missing Hki anchor fails closed without writing" {
	write_updater_fixture
	sed -i 's/auto-updates disabled by enterprise policy/enterprise policy/' "$main_js"
	cp "$main_js" "$TEST_TMP/before.js"
	run patch_disable_auto_updater
	[[ $status -ne 0 ]]
	[[ $output == *'Hki() update-check entry'* ]]
	cmp "$main_js" "$TEST_TMP/before.js"
}

@test "an ambiguous Hki anchor fails closed without writing" {
	write_updater_fixture
	printf '%s\n' 'async function Other(){return N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy"),"skipped"}' >> "$main_js"
	cp "$main_js" "$TEST_TMP/before.js"
	run patch_disable_auto_updater
	[[ $status -ne 0 ]]
	[[ $output == *'ambiguous: 2 sites'* ]]
	cmp "$main_js" "$TEST_TMP/before.js"
}

# Oracle MAJOR #4 : 一意なアンカーを含む関数を波括弧の対応で特定する
# 直前に閉じた零引数のasync function(Vki)へガードを入れてはいけない
@test "Hki with parameters after a closed zero-arg async function patches the enclosing function" {
	printf '%s' \
		'function la(){return!1}function tgi(){return N.info("[updater] App is not installed, not enabling auto-updates"),Z("desktop_update_disabled")}function Zz(){if(tz.forceInstalled)return!0;if(process.platform!=="win32")return u.app.isPackaged;if(!u.app.isPackaged)return!1;return!0}async function Vki(){return"vki"}async function Hki(a,b){if(a)return N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy"),"skipped";return b?"checked":"none"}async function Vk(e){return u.net.fetch(dki(qOi,"msix",e))}' \
		> "$main_js"
	run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	grep -qF 'function Zz(){if(process.platform==="linux")return!1;if(tz.forceInstalled)' "$main_js"
	grep -qF 'async function Hki(a,b){if(process.platform==="linux")return"skipped";' "$main_js"
	grep -qF 'async function Vki(){return"vki"}' "$main_js"
	[[ $(grep -o 'process.platform==="linux"' "$main_js" | wc -l) -eq 3 ]]
}

# Oracle round-2 MAJOR #2 : コメント内の偽の async function 見出しや
# コメント化したログ文字列に釣られて、本物の Hki() を未ガードのまま
# 成功にしてはいけない。Acornが無い隔離環境でも同じ結果にする。
@test "a commented-out function head cannot shadow the real Hki anchor" {
	write_updater_fixture
	sed -i 's|async function Wq(){|/* N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy") *//* async function fake() { */async function Wq(){|' "$main_js"

	run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	[[ $output == *'Hki(): Linux returns "skipped" at the entry point (fn: Wq)'* ]]
	grep -qF 'async function Wq(){if(process.platform==="linux")return"skipped";' "$main_js"
	grep -qF '/* async function fake() { */async function Wq(){' "$main_js"
	[[ $(grep -o 'process.platform==="linux"' "$main_js" | wc -l) -eq 3 ]]
	node --check "$main_js"

	# Acornを解決できない隔離環境では、コメントと文字列を伏せた
	# トークン走査へ落ちる。同じ入力から同じガード位置にする。
	write_updater_fixture
	sed -i 's|async function Wq(){|/* N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy") *//* async function fake() { */async function Wq(){|' "$main_js"
	NODE_PATH='' PATCH_WORK_DIR='' run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	grep -qF 'async function Wq(){if(process.platform==="linux")return"skipped";' "$main_js"
	[[ $(grep -o 'process.platform==="linux"' "$main_js" | wc -l) -eq 3 ]]
	node --check "$main_js"
}

# Oracle MAJOR #4 : アンカーを内包するasync functionが無ければ、
# 手前の閉じた関数を流用せずに失敗する
@test "Hki with no enclosing async function fails closed without writing" {
	printf '%s' \
		'function la(){return!1}function tgi(){return N.info("[updater] App is not installed, not enabling auto-updates"),Z("desktop_update_disabled")}function Zz(){if(tz.forceInstalled)return!0;if(process.platform!=="win32")return u.app.isPackaged;if(!u.app.isPackaged)return!1;return!0}async function Vki(){return"vki"}function Hki(){return N.info("[updater] Skipping update check: auto-updates disabled by enterprise policy"),"skipped"}async function Vk(e){return u.net.fetch(dki(qOi,"msix",e))}' \
		> "$main_js"
	cp "$main_js" "$TEST_TMP/before.js"
	run patch_disable_auto_updater
	[[ $status -ne 0 ]]
	[[ $output == *'Hki() update-check entry (no enclosing async function)'* ]]
	cmp "$main_js" "$TEST_TMP/before.js"
}

@test "a missing gki anchor fails closed without writing" {
	write_updater_fixture
	sed -i 's/"msix"/"msix-v2"/' "$main_js"
	cp "$main_js" "$TEST_TMP/before.js"
	run patch_disable_auto_updater
	[[ $status -ne 0 ]]
	[[ $output == *'gki() update-metadata fetch'* ]]
	cmp "$main_js" "$TEST_TMP/before.js"
}

@test "runtime: Oz is false even with forceInstalled, Hki is skipped, gki is 204 and net.fetch is never called" {
	write_updater_fixture
	patch_disable_auto_updater > /dev/null
	run env FIXTURE="$main_js" node << 'RUNTIME'
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.env.FIXTURE, 'utf8');

function extract(name) {
    let start = src.indexOf('function ' + name + '(');
    if (start < 0) {
        throw new Error('missing function ' + name);
    }
    if (src.slice(Math.max(0, start - 6), start) === 'async ') {
        start -= 6;
    }
    let depth = 0;
    let i = src.indexOf('{', start);
    for (; i < src.length; i += 1) {
        if (src[i] === '{') {
            depth += 1;
        } else if (src[i] === '}') {
            depth -= 1;
            if (depth === 0) {
                i += 1;
                break;
            }
        }
    }
    return src.slice(start, i);
}

const sandbox = {
    process: { platform: 'linux', env: {} },
    console,
    tz: { forceInstalled: true },
    Tz: { isManualCheck: true },
    kz: false,
    BCi: async () => false,
    N: { info: () => undefined },
    Nki: () => undefined,
    J: () => ({ autoUpdate: { disabled: false } }),
    dki: () => 'https://example.invalid/update',
    qOi: '/base',
    u: {
        app: { isPackaged: true, getPath: () => '/app' },
        net: { fetch: () => { throw new Error('NET_FETCH_CALLED'); } }
    },
    n: { default: { dirname: () => '/app', resolve: () => '/app/update.exe' } },
    a: { default: { existsSync: () => true } },
    la: () => false
};
sandbox.global = sandbox;

const code = '(async () => {' +
    extract('Zz') + ';' +
    extract('Wq') + ';' +
    extract('Vk') + ';' +
    'return { oz: Zz(), hki: await Wq(), gki: await Vk({}) };' +
    '})()';

vm.runInNewContext(code, sandbox)
    .then((result) => { console.log(JSON.stringify(result)); })
    .catch((error) => { console.error(error.message); process.exit(1); });
RUNTIME
	[[ $status -eq 0 ]]
	[[ $output == '{"oz":false,"hki":"skipped","gki":{"status":204,"ok":false}}' ]]
}

@test "real 7.37095.0 updater sites are patched" {
	local real_main
	real_main=$(grep -lF '[updater] App is not installed, not enabling auto-updates' "$REAL_BUNDLE_DIR"/index.chunk-*.js 2>/dev/null | head -n 1)
	if [[ -z $real_main ]]; then
		skip "7.37095.0 bundle is not available at $REAL_BUNDLE_DIR"
	fi
	cp "$real_main" "$main_js"
	run patch_disable_auto_updater
	[[ $status -eq 0 ]]
	grep -qF 'if(process.platform==="linux")return!1;' "$main_js"
	grep -qF 'return"skipped";' "$main_js"
	grep -qF 'return{status:204,ok:!1};' "$main_js"
}

@test "effect check accepts the patch and the second pass is byte-identical" {
	mkdir -p "$TEST_TMP/app.asar.contents/.vite/build"
	main_js="$TEST_TMP/app.asar.contents/.vite/build/index.js"
	write_updater_fixture
	cd "$TEST_TMP" || return 1
	run _run_suse_patch_function patch_disable_auto_updater check
	[[ $status -eq 0 ]]
	local before
	before=$(_patch_bundle_digest)
	run _run_suse_patch_function patch_disable_auto_updater no-check
	[[ $status -eq 0 ]]
	_check_patch_stage_idempotent "$before" "$(_patch_bundle_digest)"
}
