#!/usr/bin/env bats
#
# @file verify-patches.bats
# @brief ビルド後の静的検査スクリプト scripts/verify-patches.sh のテスト
#
# このスクリプトは、出荷するindex.jsにパッチのマーカーが入っているかをgrepで確認する
# 既定の対象はcoworkで、issue #559 D6 / PR #555 に由来する
#
# テストも検証スクリプトも scripts/cowork-patch-markers.tsv からマーカー一覧を読む
# そのためマーカーを1つ足すだけで、下のテスト対象が自動的に広がる
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ
VERIFY_SH="$SCRIPT_DIR/../scripts/verify-patches.sh"            # 検証対象のビルド後検査スクリプト

#
# @brief テスト用の一時ディレクトリを用意し、検証スクリプトとマーカー一覧を読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global marker_names マーカーの名前の一覧 (本関数で設定する)
# @global marker_patterns マーカーを検出する正規表現の一覧 (本関数で設定する)
# @global marker_samples マーカーごとのサンプル文字列の一覧 (本関数で設定する)
# @note マーカー一覧はTSV由来なので、要素数は実行時に決まる
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# 検証スクリプトをライブラリとして読み込み、パーサーをそのまま使う
	# TSVの形式を変えたときに、テストとスクリプトの解釈がずれないようにするため
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/verify-patches.sh
	source "$VERIFY_SH"
	load_markers
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
# @note setupが途中で失敗してTEST_TMPが未定義でも失敗しないよう、存在を確認してから削除する
#
teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief すべてのサンプルを含む固定データのindex.jsを作る
# @param $1 省略するマーカーの名前
# @global TEST_TMP 固定データを作る一時ディレクトリ (参照のみ)
# @stdout 作ったindex.jsのパス
#
# マーカーが欠けた場合の異常系を作るために使う
write_fixture() {
	local omit="${1:-}"
	local fixture="$TEST_TMP/index.js"
	: > "$fixture"
	local i
	for i in "${!marker_names[@]}"; do
		if [[ ${marker_names[$i]} != "$omit" ]]; then
			printf '%s\n' "${marker_samples[$i]}" >> "$fixture"
		fi
	done
	printf '%s\n' "$fixture"
}

# マーカー定義ファイルの整合性

@test "markers file: every regex matches its sample" {
	local i
	for i in "${!marker_names[@]}"; do
		run grep -qP -- "${marker_patterns[$i]}" \
			<(printf '%s\n' "${marker_samples[$i]}")
		[[ "$status" -eq 0 ]] || {
			echo "regex did not match own sample: ${marker_names[$i]}"
			echo "pattern: ${marker_patterns[$i]}"
			echo "sample:  ${marker_samples[$i]}"
			return 1
		}
	done
}

@test "markers file: at least 9 markers loaded" {
	[[ "${#marker_names[@]}" -ge 9 ]] || {
		echo "expected >= 9 markers, got ${#marker_names[@]}"
		return 1
	}
}

#
# @brief 指定したマーカーのPCREを出力する
# @param $1 マーカーの名前
# @stdout マーカーを検出する正規表現
# @return 0 = 見つかった場合, 1 = 見つからなかった場合
#
marker_pattern() {
	local i
	for i in "${!marker_names[@]}"; do
		if [[ ${marker_names[$i]} == "$1" ]]; then
			printf '%s\n' "${marker_patterns[$i]}"
			return 0
		fi
	done
	return 1
}

# マーカーは、add-dir向けパッチが書き換えるすべての呼び出し形に追随する必要がある
# そのため上流の各形を実際のパッチに通して確かめる
# パッチが変わったのにマーカーが追随していなければ、リリースではなくこのテストで気づける
@test "markers file: asar-adddir-filter matches every shape the patcher writes" {
	local pattern
	pattern="$(marker_pattern asar-adddir-filter)"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$SCRIPT_DIR/../scripts/patches/config.sh"

	# shellcheck disable=SC2016 # JavaScriptのテンプレート文字列をそのまま扱う
	local -a shapes=(
		'function b(e,w){for(let t of e)w.push("--add-dir",t);return w}'
		'function b(e,w){e.forEach(t=>w.push("--add-dir",t));return w}'
		'function Y7(e,t){return`${e}=${t}`}function b(e,w){for(let t of e)w.push(Y7("--add-dir",t));return w}'
	)
	local shape n=0 main_js work
	for shape in "${shapes[@]}"; do
		n=$((n + 1))
		work="$TEST_TMP/shape$n"
		mkdir -p "$work"
		main_js="$work/index.js"
		printf '%s' 'require("./index.chunk-Main0001.js");' > "$main_js"
		printf '%s' "$shape" > "$work/index.chunk-Main0001.js"

		run grep -qP -- "$pattern" "$work/index.chunk-Main0001.js"
		[[ $status -ne 0 ]] || {
			echo "marker matched the unpatched shape: $shape"
			return 1
		}

		run patch_asar_additional_dirs_guard
		[[ $status -eq 0 ]] || {
			echo "patcher failed on: $shape"
			echo "$output"
			return 1
		}
		run grep -qP -- "$pattern" "$work/index.chunk-Main0001.js"
		[[ $status -eq 0 ]] || {
			echo "marker missed the patched shape:"
			cat "$work/index.chunk-Main0001.js"
			return 1
		}
	done
}

# 正常系 : すべてのサンプルを含む固定データはパスする

@test "verify: exits 0 when every marker present" {
	local fixture
	fixture="$(write_fixture)"

	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected a fully-marked fixture'
		echo "$output"
		return 1
	}

	run grep -c 'OK ' <<< "$output"
	[[ "$output" -eq "${#marker_names[@]}" ]] || {
		echo "expected ${#marker_names[@]} OK lines, got: $output"
		return 1
	}
}

# 異常系 : マーカーごとに1つだけ欠けた固定データ

@test "verify: exits 2 and names the missing marker (each)" {
	local name fixture failures=0
	for name in "${marker_names[@]}"; do
		fixture="$(write_fixture "$name")"

		run "$VERIFY_SH" "$fixture"
		if [[ "$status" -ne 2 ]]; then
			echo "missing $name should exit 2, got $status"
			echo "$output"
			failures=$((failures + 1))
		fi
		if ! grep -q "$name" <<< "$output"; then
			echo "missing $name not named in output"
			echo "$output"
			failures=$((failures + 1))
		fi
	done
	[[ "$failures" -eq 0 ]]
}

# 入力の形

@test "verify: accepts a directory containing the asar layout" {
	local layout="$TEST_TMP/staging/app.asar.contents/.vite/build"
	mkdir -p "$layout"
	: > "$layout/index.js"
	local sample
	for sample in "${marker_samples[@]}"; do
		printf '%s\n' "$sample" >> "$layout/index.js"
	done

	run "$VERIFY_SH" "$TEST_TMP/staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected directory-shaped input'
		echo "$output"
		return 1
	}
}

@test "verify: extracts an .asar through ASAR_BIN" {
	local fixture stub="$TEST_TMP/asar-stub"
	fixture="$(write_fixture)"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		# shellcheck disable=SC2016 # スタブスクリプトの文字列をそのまま扱う
		printf '%s\n' 'case "$1" in'
		printf '%s\n' '  --version) echo 4.3.0 ;;'
		# shellcheck disable=SC2016 # スタブスクリプトの文字列をそのまま扱う
		printf '  extract) mkdir -p "$3/.vite/build"; cp %q "$3/.vite/build/index.js" ;;\n' \
			"$fixture"
		printf '%s\n' '  *) exit 1 ;;' 'esac'
	} > "$stub"
	chmod +x "$stub"
	: > "$TEST_TMP/app.asar"
	export ASAR_BIN="$stub"

	run "$VERIFY_SH" "$TEST_TMP/app.asar"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected an asar extracted through ASAR_BIN'
		echo "$output"
		return 1
	}
	[[ "$output" == *'Using asar executable:'* ]]
}

@test "verify: accepts code-split directory layout (markers in chunk)" {
	local layout="$TEST_TMP/staging/app.asar.contents/.vite/build"
	mkdir -p "$layout"
	# index.jsはチャンクをrequire()するだけのスタブ
	printf '%s\n' 'require("./index.chunk-testHash.js");' \
		> "$layout/index.js"
	# マーカーはスタブではなくチャンク側にある
	: > "$layout/index.chunk-testHash.js"
	local sample
	for sample in "${marker_samples[@]}"; do
		printf '%s\n' "$sample" >> "$layout/index.chunk-testHash.js"
	done

	run "$VERIFY_SH" "$TEST_TMP/staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected code-split directory input'
		echo "$output"
		return 1
	}
}

@test "verify: finds markers in safe sibling chunks" {
	local layout="$TEST_TMP/staging/app.asar.contents/.vite/build"
	mkdir -p "$layout"
	printf '%s\n' 'require("./index.chunk-main.js");' > "$layout/index.js"
	: > "$layout/index.chunk-main.js"
	: > "$layout/index.chunk-secondary.js"
	local i
	for i in "${!marker_names[@]}"; do
		if [[ ${marker_names[$i]} == 'asar-adddir-filter' ]]; then
			printf '%s\n' "${marker_samples[$i]}" \
				>> "$layout/index.chunk-secondary.js"
		else
			printf '%s\n' "${marker_samples[$i]}" \
				>> "$layout/index.chunk-main.js"
		fi
	done

	run "$VERIFY_SH" "$TEST_TMP/staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected safe sibling marker layout'
		echo "$output"
		return 1
	}
}

@test "verify: rejects missing path with exit 1" {
	run "$VERIFY_SH" "$TEST_TMP/does-not-exist.js"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'not found'* ]]
}

@test "verify: rejects directory without expected layout" {
	mkdir -p "$TEST_TMP/empty"
	run "$VERIFY_SH" "$TEST_TMP/empty"
	[[ "$status" -eq 1 ]]
}

@test "verify: prints usage on no args and exits 1" {
	run "$VERIFY_SH"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'Usage:'* ]]
}

@test "verify: --help prints usage and exits 0" {
	run "$VERIFY_SH" --help
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'Usage:'* ]]
}
