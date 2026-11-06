#!/usr/bin/env bats
#
# @file launcher-prelaunch-calls.bats
# @brief 生成されるランチャーが起動前の後片付け関数を呼び続けているかを確認する
#
# 各関数はscripts/launcher-common.shの定義に対して単体でテストされているが、
# ランチャー側が実際に呼んでいるかはどこでも確認していない
# scripts/packaging/{rpm,appimage}.shからその一連の呼び出しを消しても、
# 残りのテストは通ったままになる
# 特にbackup_user_configは影響が大きく、呼び出しを失っても
# 必要な場面でバックアップが無いことに気付くまで表に出ない
#
# ここは静的な確認だけを行う軽い層で、ビルドしたパッケージではなく
# パッケージ用スクリプトを読む
# そのため、出荷されるランチャーが実際の古い状態に対して動くことではなく、
# ランチャーのソースが正しい位置で呼んでいることを固定する
#
# 探す範囲を2つのパッケージ用スクリプトに限っているのは意図的
# scripts/launcher-common.shのcleanup_after_electron_exitがElectronの終了後に
# 同じ名前のいくつかを再び呼ぶため、リポジトリ全体を対象にすると
# ランチャーが何も呼んでいなくてもgrepが満たされてしまう
#
# awkは各スクリプトをヒアドキュメントの境界で区切る
# 何も拾えなかった
# 解析でも下の判定はすべて通ってしまうため、最初のテストで解析結果の
# 形そのものを確認する
#
# 上流のclaude-desktop-debianから移植した
# SUSEの呼び出し一覧は
# cleanup_stale_cowork_socketを残している (SUSEのデーモンが今もその
# ソケットを使うため)
# ポータル用の項目とVMバンドル用の関数は無い

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PACKAGING_DIR="${SCRIPT_DIR}/../scripts/packaging"

readonly PACKAGING_SCRIPTS=(
	rpm.sh
	appimage.sh
)

# 起動前に走る一連の呼び出しを、ランチャーが実行する順に並べたもの
# 2つの形式で1つの配列を共有しているのは意図的で、
# 片方のランチャーだけに追加して他方で忘れると、ここで落ちる
readonly PRELAUNCH_CALLS=(
	cleanup_replaced_desktop_ui
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
	heal_autostart_entry
	heal_file_manager_entries
	backup_user_config
)

# ランチャーがコマンド位置で実行してよい外部プログラム
# 今のところRPM版ランチャーの「Electronが無い」ダイアログだけで、
# 増やすときは意図して足す
readonly ALLOWED_EXTERNAL=(
	zenity
	kdialog
)

#
# @brief パッケージ用スクリプトのランチャー用ヒアドキュメント本体を、行番号付きで返す
# @param $1 パッケージ用スクリプト名
# @stdout 行番号と本文をコロンで区切った行 (grep -nと同じ形なので、cut -d: -f1で番号を戻せる)
#
# 行頭のcat > ... << EOFと、行頭だけのEOFの組を手掛かりに切り出し、
# ランチャーのsetup_logging呼び出しを含む1つの範囲に絞る
# rpmの<< SPECEOFは開始と見なさず、終端も^EOF$ではないため、
# 範囲がつながることはない
launcher_heredoc() {
	awk -v q="'" '
		!inhd && $0 ~ ("^cat > .*<<[[:space:]]*" q "?EOF" q \
			"?[[:space:]]*$") {
			inhd = 1
			body = ""
			next
		}
		inhd && /^EOF[[:space:]]*$/ {
			inhd = 0
			if (body ~ /setup_logging/) printf "%s", body
			next
		}
		inhd { body = body NR ":" $0 "\n" }
	' "${PACKAGING_DIR}/$1"
}

#
# @brief 標準入力の行番号付きの行から、指定した関数の呼び出し行の番号だけを返す
# @param $1 関数名
# @stdout 呼び出し行の行番号
#
# ランチャーの行頭に関数名があり、行末か空白が続く行を呼び出しと見なす
# コメント行は先に落とすため、後で判定を緩めてもコメント中の記述は数えない
call_lines() {
	grep -vE '^[0-9]+:[[:space:]]*#' \
		| grep -E "^[0-9]+:$1([[:space:]]|\$)" \
		| cut -d: -f1
}

#
# @brief ランチャーのヒアドキュメントから、コメント行を落として行番号も外した本文を返す
# @param $1 パッケージ用スクリプト名
# @stdout 行全体の一致で判定できるよう、行番号を外した本文
#
uncommented_launcher() {
	launcher_heredoc "$1" | grep -vE '^[0-9]+:[[:space:]]*#' \
		| cut -d: -f2- || true
}

#
# @brief スクリプト全体で、行頭の指定した関数への呼び出しが何回あるかを数える
# @param $1 パッケージ用スクリプト名
# @param $2 関数名
# @stdout 呼び出しの回数 (ヒアドキュメントの内外を問わない)
#
file_calls() {
	grep -vE '^[[:space:]]*#' "${PACKAGING_DIR}/$1" \
		| grep -cE "^$2([[:space:]]|\$)" || true
}

#
# @brief heal_autostart_entryへ渡す引数を、各形式の記述どおりの文字列で返す
# @param $1 パッケージ用スクリプト名
# @stdout 期待する呼び出しの文字列
#
# RPM版のヒアドキュメントは引用符なしなので、$install_prefixと$package_nameは
# ビルド時に展開される
# AppImage版のヒアドキュメントは引用符付きなので、${APPIMAGE:-}は
# 実行時に展開される文字列としてそのまま残る
heal_call() {
	case "$1" in
	rpm.sh)
		printf '%s' \
			"heal_autostart_entry '/usr/bin/\$package_name'"
		;;
	appimage.sh)
		# shellcheck disable=SC2016  # AppRunに書く文字列そのもので、展開は実行時になるため
		printf '%s' 'heal_autostart_entry "${APPIMAGE:-}"'
		;;
	*)
		return 1
		;;
	esac
}

@test "the launcher-heredoc parser sees the expected shape" {
	local script body rows
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		[[ -s "${PACKAGING_DIR}/${script}" ]]

		body=$(launcher_heredoc "$script")
		[[ -n "$body" ]]

		rows=$(grep -c '' <<<"$body")
		[[ "$rows" -ge 30 ]]

		# 残ったランチャーの範囲が1つだけで、順序の目印を両方含んでいる
		[[ $(grep -cE '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body") -eq 1 ]]
		[[ $(grep -cE '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body") -eq 1 ]]

		# 範囲は自分のEOFで終わり、続く.desktopのヒアドキュメントへはみ出さない
		[[ "$body" != *'[Desktop Entry]'* ]]
	done
}

@test "the call anchor rejects comments, prefixes and prose mentions" {
	local fixture hits
	fixture=$(cat <<-'FIXTURE'
		10:# cleanup_stale_lock
		11:  # cleanup_stale_lock
		12:cleanup_stale_lock_extra
		13:log_message 'ran cleanup_stale_lock'
		14:  cleanup_stale_lock
		15:cleanup_stale_lock
		16:# heal_autostart_entry "${APPIMAGE:-}"
		17:heal_autostart_entry "${APPIMAGE:-}"
	FIXTURE
	)

	hits=$(call_lines cleanup_stale_lock <<<"$fixture")
	[[ "$hits" == '15' ]]

	hits=$(call_lines heal_autostart_entry <<<"$fixture")
	[[ "$hits" == '17' ]]
}

@test "every pre-launch call appears exactly once in every launcher" {
	local script body call count offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			count=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			[[ "$count" -eq 1 ]] && continue
			offenders+="${script}: ${call}:"
			offenders+=" ${count} call site(s), want 1"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call missing or duplicated:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "pre-launch calls run in order after setup_logging, before Electron" {
	# Electronの後に走る後片付けは起動前の後片付けではない
	# また、log_messageはsetup_loggingが先に走っていないと使えない
	local script body start end call line prev offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		start=$(grep -E '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body" | head -1 | cut -d: -f1)
		end=$(grep -E '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body" | head -1 | cut -d: -f1)

		[[ -n "$start" && -n "$end" ]] || {
			offenders+="${script}: no setup_logging/exec landmark"
			offenders+=$'\n'
			continue
		}

		prev=$start
		for call in "${PRELAUNCH_CALLS[@]}"; do
			line=$(call_lines "$call" <<<"$body" | head -1)
			[[ -n "$line" ]] || {
				offenders+="${script}: ${call}: no call site"$'\n'
				continue
			}
			if [[ "$line" -gt "$prev" && "$line" -lt "$end" ]]; then
				prev=$line
				continue
			fi
			offenders+="${script}: ${call}: line ${line} not in"
			offenders+=" (${prev}, ${end})"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call out of order or window:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "no pre-launch call site sits outside the launcher heredoc" {
	# cat >のすぐ横に書いた呼び出しは、起動時ではなくビルド時に走ってしまう
	local script body call inside in_file offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			inside=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			in_file=$(file_calls "$script" "$call")
			[[ "$inside" -eq "$in_file" ]] && continue
			offenders+="${script}: ${call}: ${in_file} in file,"
			offenders+=" ${inside} in the launcher"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call outside the launcher heredoc:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "each launcher carries only its own heal_autostart_entry argument" {
	local script other body want foreign offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script")
		want=$(heal_call "$script")

		[[ $(grep -cFx -- "$want" <<<"$body" || true) -eq 1 ]] || {
			offenders+="${script}: want exactly one: ${want}"$'\n'
		}

		for other in "${PACKAGING_SCRIPTS[@]}"; do
			foreign=$(heal_call "$other")
			[[ "$foreign" == "$want" ]] && continue
			grep -qFx -- "$foreign" <<<"$body" || continue
			offenders+="${script}: carries ${other}'s argument:"
			offenders+=" ${foreign}"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'wrong heal_autostart_entry argument:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "each launcher passes its launcher path and icon to heal_file_manager_entries" {
	local script body want offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script" \
			| sed -e ':a' -e '/\\$/{N;s/[[:space:]]*\\\n[[:space:]]*/ /;ba' -e '}')
		case "$script" in
		rpm.sh)
			want="heal_file_manager_entries '/usr/bin/\$package_name'"
			want+=" '/usr/share/icons/hicolor/256x256/apps/claude-desktop.png'"
			;;
		appimage.sh)
			want="heal_file_manager_entries \"\${APPIMAGE:-}\""
			want+=" \"\$appdir/usr/share/icons/hicolor/256x256/apps/io.github.presire.claude-desktop-suse.png\""
			;;
		esac
		[[ $(grep -cFx -- "$want" <<<"$body" || true) -eq 1 ]] &&
			continue
		offenders+="${script}: want exactly one: ${want}"$'\n'
	done

	[[ -z "$offenders" ]] || {
		printf 'wrong heal_file_manager_entries call:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "ensure_portal_app_id_entry follows detect_display_backend with the asar desktopName" {
	# この別名を書くのはネイティブWaylandのときだけで、そのためには
	# 先にバックエンドの判定が要る
	# また、app-asar.shがpackage.jsonへ書くdesktopNameと一致していないと、
	# ポータルは受け付けない
	local script body detect ensure end call want offenders=''
	local asar_sh="${PACKAGING_DIR}/../patches/app-asar.sh"
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		detect=$(call_lines detect_display_backend <<<"$body")
		ensure=$(call_lines ensure_portal_app_id_entry <<<"$body")
		end=$(grep -E '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body" | cut -d: -f1)

		if [[ $(grep -c . <<<"$ensure") -ne 1 ||
			$(grep -c . <<<"$detect") -ne 1 ]]; then
			offenders+="${script}: want one detect and one ensure call"
			offenders+=$'\n'
			continue
		fi
		[[ $ensure -gt $detect && $ensure -lt $end ]] || {
			offenders+="${script}: ensure at ${ensure}, detect at"
			offenders+=" ${detect}, Electron at ${end}"$'\n'
		}

		call=$(uncommented_launcher "$script" \
			| sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' \
			| grep -E '^ensure_portal_app_id_entry ')
		case "$script" in
		rpm.sh) want="claude-desktop.desktop" ;;
		appimage.sh) want="io.github.presire.claude-desktop-suse.desktop" ;;
		esac
		grep -qF "'${want}'" "$asar_sh" || {
			offenders+="app-asar.sh: no desktopName ${want}"$'\n'
		}
		[[ $call == *" '${want%.desktop}' "* ]] || {
			offenders+="${script}: app id is not ${want%.desktop}:"
			offenders+=" ${call}"$'\n'
		}
	done

	[[ -z "$offenders" ]] || {
		printf 'portal app-id entry call is wrong:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "both launchers hand Electron to run_electron_and_cleanup, not exec" {
	# 単独のexecはランチャーを置き換えてしまうため、出力の絞り込みも
	# 終了後のCoworkとヘルパーの後片付けも走らなくなる
	local script body offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script")
		grep -qE '^[[:space:]]*exec[[:space:]]' <<<"$body" || continue
		offenders+="${script}: launcher still execs"$'\n'
	done

	[[ -z "$offenders" ]] || {
		printf '%s' "$offenders" >&2
		false
	}
}

@test "the bundled Electron is not handed app.asar on argv (#696/#700)" {
	# Electronはresources/app.asarを自動で読み込むため、argvに余分な項目を
	# 渡すとアプリには開くべきファイルとして届く
	# rpm版はPATH上のelectronを使う場合に限ってこれを残している
	local body appimage_hits rpm_hits
	body=$(uncommented_launcher appimage.sh)
	appimage_hits=$(grep -c 'app\.asar' <<<"$body" || true)
	[[ $appimage_hits -eq 0 ]]

	body=$(uncommented_launcher rpm.sh)
	rpm_hits=$(grep -c 'app\.asar' <<<"$body" || true)
	[[ $rpm_hits -eq 1 ]]
	grep -B2 'app\.asar' <<<"$body" \
		| grep -qF "if [[ \\\$electron_exec == 'electron' ]]; then"
	run ! grep -qF 'app_path' <<<"$body"
}

#
# @brief ランチャーのヒアドキュメントから、コマンド位置に現れる語を1行1つで返す
# @param $1 パッケージ用スクリプト名
# @stdout コマンド位置の語
#
# コマンド位置とは、行頭、または;、&&、||、|、単独の{、!、そして
# if、elif、then、else、while、until、doの直後を指す
#
# 先にバックスラッシュで継続する行をつなぐため、継続行のオプションが
# コマンドとして読まれることはない
# 続いて引用符で囲まれた文字列、[[ ... ]]の判定、${...}の展開を落とすため、
# その中の語もコマンドとして読まれることはない
command_words() {
	uncommented_launcher "$1" \
		| sed -E -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' \
		| sed -E -e "s/'[^']*'//g" -e 's/"[^"]*"//g' \
			-e 's/\[\[[^]]*\]\]//g' -e 's/\$\{[^}]*\}//g' \
		| sed -E -e 's/(;|&&|\|\||\||!)/\n/g' \
			-e 's/\<case[[:space:]]+([^[:space:]]+[[:space:]]+)?in\>/\n/g' \
			-e 's/(^|[[:space:]])\{([[:space:]]|$)/\n/g' \
			-e 's/\<(if|elif|then|else|while|until|do)\>/\n/g' \
		| awk '{ w = 1; if ($1 ~ /\)$/) w = 2 } NF >= w { print $w }'
}

@test "every launcher command is a builtin or a launcher-common function" {
	# launcher-common.shから関数が消えたり名前が変わったりしても、
	# ランチャーが呼んでいればbashは止まらない
	# 単に「command not found」をログに出して処理を続ける
	local common="${SCRIPT_DIR}/../scripts/launcher-common.sh"
	local -A shell_words=() provided=()
	local word script checked=0 offenders=''
	while read -r word; do
		shell_words[$word]=1
	done < <(compgen -k; compgen -b)
	for word in "${ALLOWED_EXTERNAL[@]}"; do
		shell_words[$word]=1
	done
	# shellcheck disable=SC2016  # 内側のシェルが$1を展開するため
	while read -r _ _ word; do
		provided[$word]=1
	done < <(env -i HOME="$HOME" PATH="$PATH" \
		bash --noprofile --norc -c \
		'source "$1" >/dev/null 2>&1; declare -F' _ "$common")
	((${#provided[@]} > 0)) || {
		printf 'sourcing %s defined no functions\n' "$common" >&2
		false
	}

	for script in "${PACKAGING_SCRIPTS[@]}"; do
		while read -r word; do
			[[ $word =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]] && continue
			[[ -n ${shell_words[$word]:-} ]] && continue
			checked=$((checked + 1))
			[[ -n ${provided[$word]:-} ]] && continue
			offenders+="${script}: ${word}"$'\n'
		done < <(command_words "$script")
	done

	((checked >= ${#PRELAUNCH_CALLS[@]} * ${#PACKAGING_SCRIPTS[@]})) || {
		printf 'checked only %d commands\n' "$checked" >&2
		false
	}
	[[ -z "$offenders" ]] || {
		printf '%s %s\n%s' 'not a shell builtin or keyword,' \
			'and not a function launcher-common.sh provides:' \
			"$offenders" >&2
		false
	}
}
