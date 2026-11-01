#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2154 # 文字列リテラルのスタブスクリプト、ASAR_BINとasar_binは読み込んだ解決処理とやり取りする
#
# @file asar-resolve.bats
# @brief scripts/verify-patches.shのresolve_asar_binがasar実行ファイルを解決する様子を確認する
#
# 防ぎたいのはasarが無いことではなく、asarはあるのに起動できない状態である
# @electron/asar 4.xはengines.node >=22.12.0を宣言しており、それ未満では起動を拒否する
# npmはその制約をEBADENGINEの警告に格下げするため、ラッパーはそのままディスクに残る
# 呼び出し側は、ツリーを作れなかった解凍処理で失敗する (#839)
#
# verify-patches.shはオフラインでも動く必要がある
# 以前の npx --yes @electron/asar は.asarを扱うたびにネットワークからバージョン未固定のパッケージを解決していた
# その置き換え後の全テストは、ネットワークを使わずに実行する
#
# 検証する解決順はASAR_BIN、<build>/node_modules/.bin/asar、PATH上のasarの順で、
# どれも使えない場合はNodeの下限バージョンに言及した失敗メッセージを出す
#

#
# @brief テスト専用のPATH・ビルドディレクトリ・出力先を用意し、verify-patches.shを読み込む
# @global stub_bin PATHの先頭に置くスタブ用ディレクトリ (本関数で設定する)
# @global build_dir asarの解決対象になるビルドディレクトリ (本関数で設定する)
# @global out 解決処理の出力を書き出すファイル (本関数で設定する)
# @global orig_path 元のPATH (テスト内でPATHを差し替えた後に戻す)
# @note ASAR_BINはテストごとに未設定から始めるため、ここでunsetする
#
setup() {
	# shellcheck source=scripts/verify-patches.sh
	source "$BATS_TEST_DIRNAME/../scripts/verify-patches.sh"

	stub_bin="$BATS_TEST_TMPDIR/bin"
	build_dir="$BATS_TEST_TMPDIR/build"
	out="$BATS_TEST_TMPDIR/output"
	mkdir -p "$stub_bin" "$build_dir"
	orig_path="$PATH"
	PATH="$stub_bin:$PATH"
	export PATH
	unset ASAR_BIN
}

# @brief 指定したパスにasarのスタブスクリプトを設置する
# @param $1 設置するパス
# @param $2 shebangに続けて書き込む本体
# @param $3 'noexec'を渡すと実行権限を付けない (省略時は実行可能)
# @note 親ディレクトリが無ければ作成する
#
_make_asar() {
	local path="$1" body="$2" mode="${3:-exec}"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' '#!/usr/bin/env bash' "$body" > "$path"
	if [[ $mode == 'exec' ]]; then
		chmod +x "$path"
	fi
}

#
# @brief 正常に起動できるasarラッパーの本体を出力する
# @stdout バージョン問い合わせにだけ応答するシェルスクリプトの本体
#
_working_body() {
	printf '%s\n' 'case "$1" in' \
		'  --version) echo "4.3.0" ;;' \
		'  *) exit 1 ;;' \
		'esac'
}

#
# @brief Nodeの下限を理由に起動を拒否するasarラッパーの本体を出力する
# @stdout 標準エラーへ警告を出して失敗するシェルスクリプトの本体
#
_refusal_body() {
	printf '%s\n' 'echo "CANNOT RUN WITH NODE 20.19.2" >&2' \
		'exit 1'
}

# @brief 解決処理を実行し、終了コードと出力を変数に残す
# @global build_dir 走査対象のビルドディレクトリ (参照のみ)
# @global rc 解決処理の終了コード (本関数で設定する)
# @global output 解決処理の出力 (標準エラーも含む)
# @note 解決処理が失敗してもテストを中断しないよう、終了コードを変数に退避してから呼び出す
#
_run_resolve() {
	rc=0
	resolve_asar_bin "$build_dir" >"$out" 2>&1 || rc=$?
	output=$(<"$out")
}

@test "resolve: ASAR_BIN wins over the build copy and PATH" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_working_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"
	_make_asar "$override" "$(_working_body)"

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$override" ]]
	[[ $output == *'Using asar executable:'* ]]
}

@test "resolve: a dead ASAR_BIN fails instead of being ignored" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_working_body)"
	_make_asar "$override" "$(_refusal_body)"

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *"ASAR_BIN='$override'"* ]]
	[[ $output == *'22.12.0'* ]]
}

@test "resolve: ASAR_BIN must be executable" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$override" "$(_working_body)" noexec

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'not executable'* ]]
}

@test "resolve: the build's node_modules/.bin/asar beats PATH" {
	local local_asar="$build_dir/node_modules/.bin/asar"
	_make_asar "$local_asar" "$(_working_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$local_asar" ]]
}

@test "resolve: a dead build asar falls through to a working PATH asar" {
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_refusal_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$stub_bin/asar" ]]
	[[ $output == *"will not run"* ]]
}

@test "resolve: PATH is the last working source" {
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$stub_bin/asar" ]]
}

@test "resolve: a refusal that exits zero is still rejected" {
	_make_asar "$stub_bin/asar" 'echo "CANNOT RUN WITH NODE 20.19.2"'

	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
}

@test "resolve: a non-executable PATH asar is rejected" {
	_make_asar "$stub_bin/asar" "$(_working_body)" noexec

	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
}

@test "resolve: no asar anywhere names the Node floor and zypper" {
	PATH="$stub_bin"
	export PATH

	_run_resolve

	PATH="$orig_path"
	export PATH

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
	[[ $output == *'22.12.0'* ]]
	[[ $output == *'zypper'* ]]
	[[ $output == *"$build_dir/node_modules/.bin/asar"* ]]
}

@test "resolve: the build's asar runs under build/node when system Node is too old" {
	# システムのNodeが下限未満の状態
	# build.shが自前のNodeをbuild/nodeへ用意したホストと同じ
	printf '%s\n' '#!/usr/bin/env bash' 'echo v20.19.2' > "$stub_bin/node"
	chmod +x "$stub_bin/node"
	mkdir -p "$build_dir/node/bin"
	printf '%s\n' '#!/usr/bin/env bash' 'echo v22.23.2' > "$build_dir/node/bin/node"
	chmod +x "$build_dir/node/bin/node"
	# ラッパーは、見つけたNodeが下限を満たさない限り起動しない
	_make_asar "$build_dir/node_modules/.bin/asar" \
		'[[ $(node --version) == v22.23.2 ]] || { echo "CANNOT RUN WITH NODE $(node --version)" >&2; exit 1; }
echo 4.3.0'

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$build_dir/node_modules/.bin/asar" ]]
	# 解凍はこのシェルで後から実行するため、ローカルのNodeが先頭に残っている必要がある
	[[ $(command -v node) == "$build_dir/node/bin/node" ]]
}
