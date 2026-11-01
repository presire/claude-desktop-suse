# shellcheck shell=bash
#
# @file virtiofsd-probe.sh
# @brief CoworkのKVM実行に使うvirtiofsdの解決処理から、同梱バイナリを
#        使えなくしている条件を取り除く
#
# 公式クライアントは/usr/libexec/virtiofsdと/usr/bin/virtiofsdの
# 2つの絶対パスだけを探し、どちらも無い場合に限り
# 同梱のresources/virtiofsdへフォールバックする
# ただしそのフォールバックは/etc/os-releaseがID=ubuntuで
# VERSION_IDが22.xのときにしか働かない
# openSUSE、Arch、Debian、Ubuntuの派生はこの判定に当てはまらず
# virtiofsdPathがnullになり、KVM関連が揃っていても
# サポート判定が"Cowork requires QEMU"を返してしまう (#771, #772)
#
# そこで最小限の修正として、同梱バイナリのフォールバックから
# os-releaseの条件だけを外す
# システム側のパスは引き続き優先し、Anthropicがバージョンを揃えて
# 同梱しているバイナリがそれ以外の環境を支える
# 探索パスの配列は、意図的にディストリビューション固有のパスで
# 拡張しない
# qemu 8未満のホストでは/usr/lib/qemu/virtiofsdが旧C実装のことがあり
# クライアントがRust実装のvirtiofsdを起動するときのCLIと
# 互換でないため
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js (app-asar.shの_resolve_main_jsが解決する)、
#                          app_staging_dir (呼び出し元のcdで基準ディレクトリになる)
# 変更するグローバル変数 : なし
#

#
# @brief virtiofsdの解決処理から、同梱バイナリ側のos-release条件を外す
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @stdout 適用またはスキップのメッセージ
# @note アンカーが無い場合はパッチ不要と判断して_declare_patch_noopを呼び、
#       ビルドを失敗させずに戻る
#
patch_virtiofsd_probe() {
	echo 'Patching virtiofsd resolution (bundled fallback un-gate)...'
	# shellcheck disable=SC2154  # main_jsはapp-asar.shが設定するsource共有のグローバル変数
	local index_js="$main_js"

	# 探索パスの配列リテラルをアンカーにする
	# パス文字列はminify後も残るため、位置の特定に使える
	# 条件の書き換えは配列の直後の限られた範囲で行い
	# 形の一致が無関係な箇所へ及ばないようにする
	# アンカーが無い場合は警告を出すがビルドは失敗させない
	# SUSE版はWindows版インストーラ由来のバンドルを使っており
	# Coworkの部分が公式Linux版.debと異なることがあるため
	# 不在がそのまま不具合とは限らない
	# 配列が複数見つかった場合も同様に警告して適用をやめ
	# どの箇所か決められないまま書き換えることはしない
	#
	# 引用符クラスは新しいバンドルが文字列リテラルを
	# バッククォートのテンプレートで再出力するため
	# 二重引用符だけのアンカーでは一致しない (Debian #820)
	local arr_anchor_re="\\[\\s*${_ANCHOR_Q}/usr/libexec/virtiofsd${_ANCHOR_Q}"
	arr_anchor_re+="\\s*,\\s*${_ANCHOR_Q}/usr/bin/virtiofsd${_ANCHOR_Q}\\s*\\]"
	# アンカーの診断メッセージは表示せずに受け取る
	# 後述の不要な形に当てはまる場合、警告と情報提供のスキップが
	# 並ぶと、スキップの意味が伝わらないため
	# 想定外の形だった場合だけ、受け取った診断をそのまま出す
	local anchor_diag anchor_ok
	anchor_diag=$(_assert_single_anchor_match "$index_js" \
		"$arr_anchor_re" 'virtiofsd probe array' 2>&1)
	anchor_ok=$?
	if [[ $anchor_ok -eq 0 ]]; then
		: # 探索パスの配列が1箇所だけ見つかったので
		  # この後ろの条件除去へ進む
	elif grep -qF 'Missing HCS services' "$index_js" \
		&& ! grep -rq 'virtiofsd' "${index_js%/*}"; then
		# このバンドル系統(2.37337.1の形)では不要
		# ここのCoworkサポート判定はwin32(HCS、
		# "Missing HCS services: ... unsupportedCode:
		# hcs_not_available")とdarwinだけを条件にし
		# そのまま{status:"supported"}へ落ちる
		# このパッチが条件を外すLinuxのKVM判定は存在しない
		# (qemuPath、firmwarePath、virtiofsdPathがいずれも無く
		# 1.44121.4と2.37337.1の両方で無いことを確認済み)
		# これらWindows由来のバンドルには最初から組み込まれておらず
		# LinuxのCoworkはSUSE自身のpatch_cowork_linuxと
		# cowork-vm-service.jsの仕組みが受け持っている
		# バイナリ名はそのまま意味を持つため、探索や起動の箇所は
		# 必ずvirtiofsdと綴る
		# ビルドツリー全体にこの名前が無いことは
		# 外すべき条件が無いことの証拠になる
		# これは警告ではなく情報提供のスキップであり
		# この系統ではアンカー不在が想定どおりの形である
		echo '  Upstream evaluator is win32/darwin-gated with no' \
			'virtiofsd probe in this bundle — patch not needed, skipping'
		_declare_patch_noop
		echo '##############################################################'
		return
	else
		if [[ -n $anchor_diag ]]; then
			printf '%s\n' "$anchor_diag" >&2
		fi
		echo 'virtiofsd probe patch skipped (anchor not present' \
			'unambiguously in this bundle)'
		echo '##############################################################'
		return
	fi
	if INDEX_JS="$index_js" node << 'VIRTIOFSD_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
if (!fs.existsSync(indexJs)) {
    console.log('  SKIP: ' + indexJs + ' not found');
    process.exit(2);
}
let code = fs.readFileSync(indexJs, 'utf8');

// q(): match a literal under any delimiter. Newer bundles re-emit
// nearly every string as a backtick template, so a bare " here
// matches nothing (Debian #820).
const q = s => '[`"\']' + s + '[`"\']';

// The client's virtiofsd probe-path array, whitespace-tolerant for
// beautified bundles:
//   [`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`]
const arrRe = new RegExp(
    '\\[\\s*' + q('\\/usr\\/libexec\\/virtiofsd') + '\\s*,\\s*' +
    q('\\/usr\\/bin\\/virtiofsd') + '\\s*\\]', 'g');
const arrMatches = [...code.matchAll(arrRe)];
if (arrMatches.length === 0) {
    console.log('  SKIP: virtiofsd probe-path array not found in bundle');
    process.exit(2);
}
if (arrMatches.length !== 1) {
    console.log('  WARNING: expected 1 virtiofsd probe-path array, found ' +
        arrMatches.length);
    process.exit(1);
}

const start = arrMatches[0].index + arrMatches[0][0].length;
const region = code.substring(start, start + 1200);

// Gated resolver tail (minified):
//   older:  return t||(e?loe(Won,Y.constants.X_OK):null)
//   newer:  return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)
// The left operand is the system-path hit. It used to be a bare
// identifier holding an already-awaited result; newer bundles inline
// the call, so it is now an `await F(x)` expression. Accept either
// shape — anything else here would be a different code path, not a
// re-minified one. The middle operand is the distro check and the
// captured call is the bundled copy. Identifiers are captured, not
// hardcoded, since they change every release.
const lhs = String.raw`(await\s+[\w$]+\(\s*[\w$]*\s*\)|[\w$]+)`;
const bundled =
    String.raw`([\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\))`;
const gatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*\\(\\s*[\\w$]+\\s*\\?\\s*` +
    `${bundled}\\s*:\\s*null\\s*\\)`);
const ungatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*` +
    String.raw`[\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\)`);

const gated = region.match(gatedRe);
if (gated) {
    const abs = start + gated.index;
    const replacement = 'return ' + gated[1] + '||' + gated[2];
    code = code.substring(0, abs) + replacement +
        code.substring(abs + gated[0].length);
    fs.writeFileSync(indexJs, code);
    console.log('  Un-gated bundled virtiofsd fallback: ' + gated[2]);
} else if (ungatedRe.test(region)) {
    console.log('  Bundled virtiofsd fallback already un-gated');
} else {
    console.log('  WARNING: bundled-fallback gate not found near the ' +
        'probe array — upstream reshaped the resolver');
    process.exit(1);
}
VIRTIOFSD_PATCH
	then
		echo 'virtiofsd probe patch applied'
	elif [[ $? -eq 2 ]]
	then
		echo 'virtiofsd probe patch skipped (anchor not present in this bundle)'
	else
		echo 'WARNING: virtiofsd probe patch failed. Cowork may report' \
			'"requires QEMU" on non-Ubuntu hosts with a complete KVM' \
			'stack (#771, #772).' >&2
	fi
	echo '##############################################################'
}
