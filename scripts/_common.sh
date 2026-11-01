#
# @file _common.sh
# @brief ビルド処理の各段階で共通して使う小さな関数をまとめる
#
# コマンドの存在確認、処理段階の見出し表示、
# ダウンロードしたファイルのチェックサム検証を提供する
# 実行用のスクリプトではなく、他のスクリプトからsourceして使う
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : なし
# 変更するグローバル変数 : なし
#

#
# @brief 指定したコマンドがPATH上に存在するかを確認する
# @param $1 確認するコマンド名
# @stdout 確認結果 ("<コマンド名> found" または "<コマンド名> not found")
# @return 0 = 存在する、1 = 存在しない
#
check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 not found"
		return 1
	else
		echo "$1 found"
		return 0
	fi
}

#
# @brief ビルドログの区切りとして、処理段階の見出しを色付きで表示する
# @param $1 見出しに表示する処理段階の名前
# @stdout シアン色の見出し行
#
section_header() {
	echo -e "\033[1;36m--- $1 ---\033[0m"
}

#
# @brief section_headerで始めた処理段階の終わりを色付きで表示する
# @param $1 終了する処理段階の名前 (section_headerに渡した名前と同じもの)
# @stdout シアン色の終了行
#
section_footer() {
	echo -e "\033[1;36m--- End $1 ---\033[0m"
}

#
# @brief ファイルのSHA-256が期待値と一致することを確認する
# @param $1 検証するファイルのパス
# @param $2 期待するSHA-256 (16進数文字列、大文字と小文字は区別しない)
# @param $3 ログに表示するファイルの説明 (省略時は "file")
# @stdout 検証の開始と成功のメッセージ
# @stderr 期待値が空の場合の警告、または不一致時の期待値と実測値
# @return 0 = 一致した、または期待値が空のため検証を省略した、1 = 不一致
# @note 期待値が空の場合は検証を省略して成功扱いにするため、
#       検証を必須にしたい場合は呼び出し側で期待値の有無を確認する必要がある
#
verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	# 上流のメタデータにはUTF-8のBOMや末尾の空白が含まれることがあり、
	# そのまま比較すると値が正しくても不一致と判定されてしまう
	# そのため、16進数として使える文字以外を全て取り除いてから比較する
	expected_hash=$(printf '%s' "$expected_hash" | tr -cd '0-9a-fA-F')

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-256 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")
	actual_hash=$(printf '%s' "$actual_hash" | tr -cd '0-9a-fA-F')

	if [[ ${actual_hash,,} != "${expected_hash,,}" ]]; then
		echo "SHA-256 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-256 verified: ${label}"
}

#
# @brief ファイルのSHA-1が期待値と一致することを確認する
# @param $1 検証するファイルのパス
# @param $2 期待するSHA-1 (16進数文字列、大文字と小文字は区別しない)
# @param $3 ログに表示するファイルの説明 (省略時は "file")
# @stdout 検証の開始と成功のメッセージ
# @stderr 期待値が空の場合の警告、または不一致時の期待値と実測値
# @return 0 = 一致した、または期待値が空のため検証を省略した、1 = 不一致
# @note 上流のRELEASESファイルに記載されたSHA-1との照合に使う
#
verify_sha1() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	# 上流のメタデータにはUTF-8のBOMや末尾の空白が含まれることがあり、
	# そのまま比較すると値が正しくても不一致と判定されてしまう
	# そのため、16進数として使える文字以外を全て取り除いてから比較する
	expected_hash=$(printf '%s' "$expected_hash" | tr -cd '0-9a-fA-F')

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-1 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-1 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha1sum "$file_path")
	actual_hash=$(printf '%s' "$actual_hash" | tr -cd '0-9a-fA-F')

	# RELEASESファイルのSHA-1は大文字で書かれているため、両方を小文字にそろえて比較する
	if [[ ${actual_hash,,} != "${expected_hash,,}" ]]; then
		echo "SHA-1 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-1 verified: ${label}"
}
