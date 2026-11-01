#!/usr/bin/env bash
#
# @file verify-patches.sh
# @brief パッチ適用後のメインプロセスJSにマーカーが揃っているかを静的に確認する
#
# マーカーの一覧はTSVで与え、既定ではscripts/cowork-patch-markers.tsvを読む
# ひとつでも見つからなければ異常終了し、欠けているマーカー名を出力する
# 目的は、パッチが半分だけ当たったまま黙って完成扱いになるのを防ぐこと
# (issue #559 D6、PR #555)
# 同じ形のTSVを第2引数で渡せば、cowork以外のパッチ群にも使える
#
# 使い方 : verify-patches.sh <path> [markers-tsv]
#
# [path]には次のいずれかを渡す
#   * JavaScriptファイル (index.jsのスタブ、チャンク、分割前のメインプロセスバンドル)
#   * .asarアーカイブ (手元にあるasar CLIで展開して調べる、解決方法はresolve_asar_binを参照)
#   * app.asar.contents/.vite/build/index.jsを含むディレクトリ
#
# コード分割されたバンドル (上流1.19367.0以降) は自動で解決する
# index.jsがスタブでindex.chunk-<hash>.jsをrequire()している場合は、
# チャンク側を検索対象にして、チャンクにあるマーカーを取りこぼさない
#
# 終了コード :
#   0 = すべてのマーカーが見つかった
#   1 = 引数の誤り、または入力が見つからない
#   2 = 見つからないマーカーがある (名前は標準エラーに出力する)
#

set -u                 # 未定義の変数を参照した時点で止め、設定漏れを早く見つける
IFS=$'\n\t'            # 単語分割を改行とタブだけに絞り、空白を含むパスを壊さない

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # このスクリプトのあるディレクトリ
project_root="$(cd "$script_dir/.." && pwd)"                # リポジトリのルート
default_markers_tsv="$script_dir/cowork-patch-markers.tsv"  # 既定のマーカー一覧
markers_tsv="$default_markers_tsv"                          # 実際に読むマーカー一覧 (第2引数で差し替える)

# チャンクの解決 (_resolve_main_js) を使うため、パッチ用の共通関数を読み込む
# ビルド時にパッチを当てるスクリプトと同じ解決処理を使うことで、
# 検証とビルドの判定が食い違わないようにする
patches_common="$script_dir/patches/_common.sh"
if [[ -f $patches_common ]]; then
	# shellcheck source=/dev/null  # パスは実行時に$patches_commonで決まるため静的に解決できない
	source "$patches_common"
fi

#
# @brief 使い方を標準エラーに表示する
# @stderr [path]と[markers-tsv]の意味、確認する内容、asarの解決方法
# @note 引数の誤りと[-h]の両方から呼ばれる
#
usage() {
	cat <<-EOF >&2
		Usage: $(basename "$0") <path> [markers-tsv]

		<path> may be a .js file, an .asar archive, or a directory
		containing app.asar.contents/.vite/build/index.js. The script
		greps for patch markers (default: cowork, PR #555 / issue #559
		D6) and exits non-zero if any are missing.

		[markers-tsv] overrides the default TSV so the same script can
		verify other patch sets.

		An .asar input is extracted with the first runnable asar found
		in ASAR_BIN, build/node_modules/.bin/asar, or PATH. Nothing is
		downloaded.
	EOF
}

#
# @brief マーカー一覧のTSVを3つの配列に読み込む
# @global markers_tsv (参照のみ)
# @global marker_names、marker_patterns、marker_samples (本関数で設定する)
# @stderr ファイルがない場合と行の形式が崩れている場合のメッセージ
# @return 0 = 読み込み成功、1 = ファイルがないか有効な行がない
# @note コメント行と空行は読み飛ばす
#       検証本体とBatsテストの両方がこの関数を使うため、
#       解析処理を1か所にまとめて両者のずれを防いでいる
#
load_markers() {
	marker_names=()
	marker_patterns=()
	marker_samples=()

	if [[ ! -f $markers_tsv ]]; then
		echo "verify-patches: marker file not found:" \
			"$markers_tsv" >&2
		return 1
	fi

	local name pattern sample
	while IFS=$'\t' read -r name pattern sample; do
		[[ -z $name || $name == '#'* ]] && continue
		if [[ -z ${pattern:-} || -z ${sample:-} ]]; then
			echo "verify-patches: malformed row '$name'" \
				'in markers file' >&2
			return 1
		fi
		marker_names+=("$name")
		marker_patterns+=("$pattern")
		marker_samples+=("$sample")
	done < "$markers_tsv"

	if [[ ${#marker_names[@]} -eq 0 ]]; then
		echo 'verify-patches: no markers loaded' >&2
		return 1
	fi
}

# .asarを展開する一時ディレクトリ
# サブシェルではなくメインのシェルで持つのは、EXITトラップから確実に消すため
tmp_extract_dir=''
#
# @brief 展開用の一時ディレクトリが残っていれば削除する
# @global tmp_extract_dir (参照のみ)
# @note EXITトラップから呼ばれるため、失敗しても終了コードを変えない
#
cleanup_tmp() {
	if [[ -n $tmp_extract_dir && -d $tmp_extract_dir ]]; then
		rm -rf "$tmp_extract_dir"
	fi
}
trap cleanup_tmp EXIT

# ---------------------------------------------------------------------
# asarの解決
#
# 本スクリプトはbuild.shの外からも使うため、
# ビルド時のnode_modulesが残っているとは限らない
# ネットワークにも出ない
# 以前はnpx --yes @electron/asarで
# 版を固定していないパッケージを取得していたため、
# オフラインやNodeが古い環境では原因の分かりにくい展開エラーになっていた
#
# 解決の順序 :
#   1. [ASAR_BIN]が設定されていればそれを使う (明示指定は黙って無視しない)
#   2. setup_electron_asarが配置した<build>/node_modules/.bin/asar
#   3. PATH上のasar
#   4. どれも使えなければ理由を示して失敗する (ダウンロードはしない)
#
# 実行ファイルがあることと動くことは別である
# @electron/asar 4.xはengines.node >=22.12.0を宣言し、
# それ未満では実行を拒否するが、npmは警告を出すだけでラッパーを入れてしまう (#839)
# そのため--versionを実行し、終了コード0かつバージョン形式の出力が
# 得られた候補だけを受け入れる
asar_bin=''            # 採用したasarの実行ファイルパス
_asar_probe_report=''  # _asar_probeが残す出力 (失敗理由の表示に使う)
_asar_probe_version='' # 受け入れたasarのバージョン文字列

#
# @brief asarの候補が実行できてバージョンを返すかを確かめる
# @param $1 確認する実行ファイルのパス
# @global _asar_probe_report (本関数で設定する)
# @global _asar_probe_version (本関数で設定する)
# @return 0 = 実行できてバージョン形式の出力がある、1 = それ以外
# @note 失敗しても終了せず、理由を_asar_probe_reportに残して呼び出し元に返す
#
_asar_probe() {
	local candidate="$1"
	_asar_probe_report=''
	_asar_probe_version=''

	if [[ ! -x $candidate ]]; then
		_asar_probe_report="asar is not executable: $candidate"
		return 1
	fi

	local probe_status
	_asar_probe_report=$("$candidate" --version 2>&1)
	probe_status=$?
	_asar_probe_version=$("$candidate" --version 2>/dev/null)

	if (( probe_status != 0 )) \
		|| [[ ! $_asar_probe_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
		return 1
	fi
}

#
# @brief asarが動かない原因がNode.jsの版にあることを案内する
# @stderr 必要なNode.jsの版、このホストの版、対処方法
# @note 呼び出し元が失敗を確定させるための補足で、単体では終了しない
#
_asar_node_floor_hint() {
	echo 'verify-patches: @electron/asar 4.x needs Node.js v22.12.0+;' \
		"this host has $(node --version 2>/dev/null || echo 'no node')." \
		'Run ./build.sh once to stage a local asar, set ASAR_BIN, or' \
		'upgrade Node.js (for example with zypper).' >&2
}

#
# @brief 実行できるasarを探して$asar_binに設定する
# @param $1 ビルド用の作業ディレクトリ (省略時は<project_root>/build)
# @global ASAR_BIN (参照のみ)
# @global asar_bin (本関数で設定する)
# @stdout 採用したasarのパスとバージョン
# @stderr 候補が動かない理由と対処方法
# @return 0 = 見つかった、1 = 見つからない
# @note 第1引数はBatsテストがfixtureのディレクトリを指すために使う
#
resolve_asar_bin() {
	local build_dir="${1:-$project_root/build}"
	asar_bin=''

	if [[ -n ${ASAR_BIN:-} ]]; then
		if ! _asar_probe "$ASAR_BIN"; then
			echo "verify-patches: ASAR_BIN='$ASAR_BIN' is not a" \
				'runnable asar:' >&2
			echo "$_asar_probe_report" >&2
			_asar_node_floor_hint
			return 1
		fi
		asar_bin="$ASAR_BIN"
		echo "Using asar executable: $asar_bin ($_asar_probe_version)"
		return 0
	fi

	local local_asar="$build_dir/node_modules/.bin/asar"
	# システムのNodeが下限未満のとき、build.shはbuild/nodeに自前のNodeを置く
	# そのPATHの変更はbuild.shの終了とともに失われるため、
	# ここでも同じNodeを使ってローカルのasarを動かす
	local local_node_bin="$build_dir/node/bin"
	local local_path="$PATH"
	if [[ -x $local_node_bin/node ]]; then
		local_path="$local_node_bin:$PATH"
	fi
	if [[ -e $local_asar || -L $local_asar ]]; then
		if PATH="$local_path" _asar_probe "$local_asar"; then
			export PATH="$local_path"
			asar_bin="$local_asar"
			echo "Using asar executable: $asar_bin ($_asar_probe_version)"
			return 0
		fi
		echo "verify-patches: asar at '$local_asar' will not run:" >&2
		echo "$_asar_probe_report" >&2
	fi

	local path_asar
	if path_asar="$(command -v asar)"; then
		if _asar_probe "$path_asar"; then
			asar_bin="$path_asar"
			echo "Using asar executable: $asar_bin ($_asar_probe_version)"
			return 0
		fi
		echo "verify-patches: asar at '$path_asar' will not run:" >&2
		echo "$_asar_probe_report" >&2
	fi

	echo 'verify-patches: no runnable asar found.' >&2
	echo "  Tried ASAR_BIN, $local_asar, and asar on PATH." >&2
	_asar_node_floor_hint
	return 1
}

#
# @brief 入力から実際に検索するメインプロセスJSを決めてグローバル変数に設定する
# @param $1 入力のパス (.jsファイル、.asar、ディレクトリのいずれか)
# @global resolved_main_js (本関数で設定する)
# @global marker_files (本関数で設定する)
# @global tmp_extract_dir (本関数で設定する)
# @stderr 入力の不備や展開の失敗を知らせる
# @return 0 = 解決できた、1 = 入力がないか展開に失敗した
# @note .asarの入力は一時ディレクトリに展開し、cleanup_tmpで後始末する
#       展開後は_resolve_main_jsでコード分割されたチャンクも追いかける
#       これによりindex.jsがスタブでもチャンク側のマーカーを見つけられる
#       ディレクトリと.asarの入力では同じ階層のチャンクも検索対象にする
#       上流がパッチ対象を内容ハッシュ付きのファイルに分けることがあるため
#       呼び出し側はコマンド置換を使わず直接呼ぶ
#       tmp_extract_dirをメインのシェルに残し、EXITトラップで消すため
#
resolved_main_js=''
marker_files=()
resolve_index_js() {
	local input="$1"
	resolved_main_js=''
	marker_files=()

	if [[ ! -e $input ]]; then
		echo "verify-patches: not found: $input" >&2
		return 1
	fi

	local raw_index_js=''

	if [[ -d $input ]]; then
		raw_index_js="$input/app.asar.contents/.vite/build/index.js"
		if [[ ! -f $raw_index_js ]]; then
			echo "verify-patches: directory does not contain" \
				"app.asar.contents/.vite/build/index.js:" \
				"$input" >&2
			return 1
		fi
	elif [[ $input == *.asar ]]; then
		if ! resolve_asar_bin "$project_root/build"; then
			return 1
		fi
		tmp_extract_dir="$(mktemp -d)"
		if ! "$asar_bin" extract "$input" \
			"$tmp_extract_dir" > /dev/null 2>&1; then
			echo "verify-patches: asar extraction failed:" \
				"$input" >&2
			return 1
		fi
		raw_index_js="$tmp_extract_dir/.vite/build/index.js"
		if [[ ! -f $raw_index_js ]]; then
			echo 'verify-patches: extracted asar lacks' \
				'.vite/build/index.js' >&2
			return 1
		fi
	else
		# JSファイルとして扱い、内容が妥当かはgrepの結果に任せる
		raw_index_js="$input"
	fi

	# コード分割されたチャンクの解決も行う
	# _resolve_main_jsは一時ディレクトリを作らず副作用もないため、
	# コマンド置換で呼んでも安全である
	# 診断メッセージは標準エラーに出し、標準出力には解決したパスだけを流す
	local chunk_resolved
	if ! chunk_resolved="$(_resolve_main_js "$raw_index_js")"; then
		return 1
	fi
	resolved_main_js="$chunk_resolved"
	marker_files=("$resolved_main_js")
	if [[ -d $input || $input == *.asar ]]; then
		local marker_dir candidate
		marker_dir="$(dirname "$resolved_main_js")"
		for candidate in "$marker_dir"/index.chunk-*.js; do
			[[ -f $candidate ]] || continue
			if [[ $candidate != "$resolved_main_js" ]]; then
				marker_files+=("$candidate")
			fi
		done
	fi
	return 0
}

#
# @brief 引数を解釈し、マーカーが揃っているかを検証して結果を返す
# @param $1 検証する入力のパス
# @param $2 マーカー一覧のTSV (省略時は既定のTSV)
# @global markers_tsv (参照と設定、第2引数があれば本関数で上書きする)
# @stdout 検証対象、マーカーの出所、各マーカーの有無、結果の要約
# @stderr 見つからなかったマーカー名
# @return 0 = すべてある、1 = 引数の誤りか入力の不備、2 = マーカーが欠けている
#
main() {
	if [[ $# -lt 1 || $# -gt 2 ]]; then
		usage
		return 1
	fi

	case "$1" in
		-h | --help)  # 使い方を表示して正常終了する
			usage
			return 0
			;;
	esac

	if [[ $# -eq 2 ]]; then
		markers_tsv="$2"
	fi

	# コマンド置換を使わないのは、resolved_main_jsとtmp_extract_dirを
	# このシェルに残し、EXITトラップで後始末できるようにするため
	if ! resolve_index_js "$1"; then
		return 1
	fi

	if ! load_markers; then
		return 1
	fi

	echo "Verifying patch markers in: ${marker_files[*]}"
	echo "Marker source: $markers_tsv"

	local i marker_file found missing_names=()
	for i in "${!marker_names[@]}"; do
		found=false
		for marker_file in "${marker_files[@]}"; do
			if grep -qP -- "${marker_patterns[$i]}" "$marker_file"; then
				found=true
				break
			fi
			done
		if [[ $found == true ]]; then
			printf '  OK   %s\n' "${marker_names[$i]}"
		else
			printf '  MISS %s\n' "${marker_names[$i]}" >&2
			missing_names+=("${marker_names[$i]}")
		fi
	done

	if [[ ${#missing_names[@]} -gt 0 ]]; then
		local joined
		joined="$(IFS=','; printf '%s' "${missing_names[*]}")"
		printf '\nverify-patches: %d/%d markers missing: %s\n' \
			"${#missing_names[@]}" "${#marker_names[@]}" "$joined" >&2
		return 2
	fi

	printf '\nAll %d patch markers present.\n' \
		"${#marker_names[@]}"
	return 0
}

# sourceされたとき (Batsテスト) はmainを実行せず、
# load_markersとmarkers_tsvだけを公開する
#
# @brief このスクリプトがsourceされているかを判定する
# @return 0 = sourceされている、1 = 直接実行されている
#
_is_sourced() {
	[[ ${BASH_SOURCE[0]} != "${0}" ]]
}

if ! _is_sourced; then
	main "$@"
fi
