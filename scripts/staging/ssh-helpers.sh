#
# @file ssh-helpers.sh
# @brief アーキテクチャ別のclaude-sshバイナリをElectronのresourcesへ複製する
#
# claude-sshはSSH接続を扱う補助バイナリで、アプリはresources配下から起動する
# 上流のバンドルに同梱されている場合だけ複製する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : claude_extract_dir, electron_resources_dest,
#   architecture
# 変更するグローバル変数 : なし
#

#
# @brief claude-ssh一式をアーキテクチャに合わせてresourcesへ複製する
# @global claude_extract_dir (参照のみ) SSH補助バイナリの取得元
# @global electron_resources_dest (参照のみ) 複製先のresourcesディレクトリ
# @global architecture (参照のみ) 複製するバイナリの名前を決める
# @note 複製に失敗した場合はexit 1で中断する
#       補助バイナリが同梱されていない版では警告だけで続行する
#
copy_ssh_helpers() {
	section_header 'SSH Helpers'

	local ssh_src="$claude_extract_dir/lib/net45/resources/claude-ssh"
	local ssh_dest="$electron_resources_dest/claude-ssh"
	local binary_name="claude-ssh-linux-$architecture"

	if [[ ! -d "$ssh_src" ]]; then
		echo "Warning: SSH helpers not found at $ssh_src"
		section_footer 'SSH Helpers'
		return
	fi

	mkdir -p "$ssh_dest" || exit 1
	cp "$ssh_src/version.txt" "$ssh_dest/" || exit 1
	cp "$ssh_src/$binary_name" "$ssh_dest/" || exit 1
	chmod +x "$ssh_dest/$binary_name"

	echo "Copied SSH helper files:"
	echo "  version.txt"
	echo "  $binary_name"

	section_footer 'SSH Helpers'
}
