#!/usr/bin/env bash
#
# @file test-artifact-common.sh
# @brief 成果物を検証するテストが共通して使う検査関数をまとめる
#
# 実行するスクリプトではなく、tests/test-artifact-rpm.shと
# tests/test-artifact-appimage.shからsourceして使う
# 合否とスキップを数え、最後にprint_summaryで内訳を出す
#
# 読み込み元 : tests/test-artifact-rpm.sh、tests/test-artifact-appimage.sh
# 終了コード : このファイル自身は終了せず、print_summaryが1で終わる
#

_pass_count=0 # 合格した検査の数
_fail_count=0 # 失敗した検査の数
_skip_count=0 # 環境が足りずスキップした検査の数

#
# @brief 検査に合格したことを表示し、合格数を1つ増やす
# @param $* 何が合格したかの説明
#
pass() {
	printf '[PASS] %s\n' "$*"
	((_pass_count++))
}

#
# @brief 検査に失敗したことを標準エラーに表示し、失敗数を1つ増やす
# @param $* 何が失敗したかの説明
#
fail() {
	printf '[FAIL] %s\n' "$*" >&2
	((_fail_count++))
}

#
# @brief 検査できなかったことを表示し、スキップ数を1つ増やす
# @param $* 何をスキップしたかの説明
# @note 呼び出し側がreturnで抜けられるよう、必ず0を返す
#
skip() {
	printf '[SKIP] %s\n' "$*"
	((_skip_count++))
	return 0
}

#
# @brief 指定したパスが通常ファイルとして存在するかを記録する
# @param $1 確認するパス
#
assert_file_exists() {
	if [[ -f $1 ]]; then
		pass "File exists: $1"
	else
		fail "File missing: $1"
	fi
}

#
# @brief 指定したパスがディレクトリとして存在するかを記録する
# @param $1 確認するパス
#
assert_dir_exists() {
	if [[ -d $1 ]]; then
		pass "Directory exists: $1"
	else
		fail "Directory missing: $1"
	fi
}

#
# @brief 指定したパスが実行できるかを記録する
# @param $1 確認するパス
#
assert_executable() {
	if [[ -x $1 ]]; then
		pass "Executable: $1"
	else
		fail "Not executable: $1"
	fi
}

#
# @brief 指定したパスにsetuidビットが立っているかを記録する
# @param $1 確認するパス
# @note chrome-sandboxのようにrootで動くヘルパーは、
#       このビットがないとサンドボックスを初期化できない
#
assert_setuid() {
	if [[ -u $1 ]]; then
		pass "Setuid bit set: $1"
	else
		fail "Setuid bit not set: $1"
	fi
}

#
# @brief ファイルの中に探したい文字列があるかを記録する
# @param $1 調べるファイル
# @param $2 探す正規表現 (grepにそのまま渡す)
# @param $3 表示する説明 (省略時はファイル名とパターンから作る)
#
assert_contains() {
	local file="$1" pattern="$2" desc="${3:-}"
	if grep -q "$pattern" "$file" 2>/dev/null; then
		pass "${desc:-"$file contains '$pattern'"}"
	else
		fail "${desc:-"$file does not contain '$pattern'"}"
	fi
}

#
# @brief コマンドが終了コード0で終わるかを記録する
# @param $1 表示する説明
# @param $2- 実行するコマンドとその引数
# @note 出力は表示せず、成否だけを見る
#
assert_command_succeeds() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit code: $?)"
	fi
}

#
# @brief 展開されたモジュールにWindowsのPE形式が残っていないか調べる
# @param $1 調べるディレクトリ (app.asar.unpacked)
# @note ビルドはnupkgに含まれるWindows向けの.nodeを削除する
#       (conpty、claude-nativeのbinding、msal-node-runtime)
#       Linuxでは読み込めないためである
#       判定はDOSのMZヘッダで行い、どのアーキテクチャのELFも合格させる
#
assert_no_pe_native_modules() {
	local dir="$1"
	local -a found=() pe_files=()
	local file magic list
	if [[ ! -d $dir ]]; then
		fail "Cannot scan for Windows PE .node files, missing: $dir"
		return 0
	fi
	# 一覧はNUL区切りのファイル経由で受け取る
	# プロセス置換ではfindの終了コードが隠れ、一覧の取得に失敗してもPASSになってしまうため
	if ! list=$(mktemp); then
		fail "Cannot scan for Windows PE .node files: mktemp failed"
		return 0
	fi
	if ! find "$dir" -type f -name '*.node' -print0 > "$list"; then
		rm -f -- "$list"
		fail "Cannot list .node files under $dir"
		return 0
	fi
	mapfile -d '' -t found < "$list"
	rm -f -- "$list"
	for file in "${found[@]}"; do
		if ! magic=$(set -o pipefail
			LC_ALL=C head -c 2 -- "$file" | tr -d '\0'); then
			fail "Cannot read .node header: $file"
			return 0
		fi
		[[ $magic == 'MZ' ]] && pe_files+=("${file#"$dir/"}") # MZはWindows実行形式の先頭2バイト
	done
	if (( ${#pe_files[@]} == 0 )); then
		pass "No Windows PE .node files in $dir"
	else
		fail "Windows PE .node files shipped: ${pe_files[*]}"
	fi
}

#
# @brief Electronのresourcesディレクトリの中身が期待どおりかを一通り確認する
# @param $1 app.asarを含むresourcesディレクトリ
# @param $2 StartupWMClassを照合する.desktopファイル (省略可)
# @note asarを展開できない場合は、何も読めないまま緑になるのを避けるためFAILにする
#
validate_app_contents() {
	local resources_dir="$1"
	local desktop_file="${2:-}"

	assert_file_exists "$resources_dir/app.asar"
	assert_dir_exists "$resources_dir/app.asar.unpacked"

	# 展開しなくても見られるapp.asar.unpackedの中身から確認する
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js"
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/cowork-vm-service.js"

	# ここから先は展開したツリーを見るため、先にasarを解決して展開する
	# PATH上のasarは起動できるところまで確かめる
	# npmのグローバルに入れた4系はNode 22.12未満を受け付けないためである
	# フォールバックのnpxは@electron/asar@3に固定する
	# アーカイブの読み出しはメジャーが違っても同じで、
	# 3系はビルドが受け付けるどのNodeでも動く
	local extract_dir
	extract_dir=$(mktemp -d)

	local -a asar_cmd=()
	if command -v asar &>/dev/null \
		&& asar --version &>/dev/null; then
		asar_cmd=(asar)
	elif command -v npx &>/dev/null \
		&& npx --yes @electron/asar@3 --version &>/dev/null; then
		asar_cmd=(npx --yes @electron/asar@3)
	fi

	local extracted=false
	if (( ${#asar_cmd[@]} == 0 )); then
		fail "Could not resolve a runnable asar (asar or npx @electron/asar@3)"
	elif "${asar_cmd[@]}" extract "$resources_dir/app.asar" \
		"$extract_dir/app"; then
		pass "app.asar extracted with ${asar_cmd[*]}"
		extracted=true
	else
		fail "asar extract failed on $resources_dir/app.asar"
	fi

	if [[ $extracted == true ]]; then
		# 枠なしウィンドウ用のパッチが入れたファイルが残っているか
		assert_file_exists "$extract_dir/app/frame-fix-wrapper.js"
		assert_file_exists "$extract_dir/app/frame-fix-menu.js"
		assert_file_exists "$extract_dir/app/frame-fix-autostart.js"
		assert_file_exists "$extract_dir/app/frame-fix-entry.js"

		# mainはフレーム修正の入口を指している必要がある
		assert_contains "$extract_dir/app/package.json" \
			'frame-fix-entry.js' \
			"package.json main field references frame-fix-entry.js"

		# メインプロセスのコードが同梱されているか
		assert_file_exists "$extract_dir/app/.vite/build/index.js"

		# claude-nativeのスタブはasarの中にも入っている必要がある
		assert_file_exists \
			"$extract_dir/app/node_modules/@ant/claude-native/index.js"

		# CoworkのVMサービスのコードもasarの中に入っている必要がある
		assert_file_exists "$extract_dir/app/cowork-vm-service.js"

		# 入口がフレーム修正のラッパーを読み込む作りになっているか
		assert_contains "$extract_dir/app/frame-fix-entry.js" \
			'frame-fix-wrapper' \
			"frame-fix-entry.js loads wrapper"

		# StartupWMClassは、asarのdesktopNameから.desktopの拡張子を除いた値と一致する必要がある
		# Chromiumはこの値から実行時のウィンドウクラスを決める
		# ずれると#779が再発し、GNOMEやKDEでタスクバーのアイコンが
		# 重複したり汎用のアイコンになったりする
		if [[ -n $desktop_file ]]; then
			local desktop_name wm_class
			desktop_name=$(sed -n \
				's/.*"desktopName": *"\([^"]*\)".*/\1/p' \
				"$extract_dir/app/package.json" | head -n 1)
			wm_class="${desktop_name%.desktop}"
			if [[ $desktop_name != *.desktop ]]; then
				fail "asar desktopName '$desktop_name' is missing or has no .desktop suffix"
			elif grep -qx "StartupWMClass=$wm_class" "$desktop_file"; then
				pass "StartupWMClass matches asar desktopName ($wm_class)"
			else
				fail "StartupWMClass in $desktop_file does not match asar desktopName-derived '$wm_class'"
			fi
		fi

		# トレイのアイコンがresourcesに入っているか
		local tray_count
		tray_count=$(find "$extract_dir/app/resources/" \
			-name 'Tray*' 2>/dev/null | wc -l)
		if [[ $tray_count -gt 0 ]]; then
			pass "Tray icons present ($tray_count files)"
		else
			fail "No tray icons found in app resources"
		fi
	fi

	rm -rf "$extract_dir"
}

#
# @brief ランチャーの[--version]が即座に版を出して終わるかを確かめる
# @param $1 表示に使うラベル
# @param $2 期待する出力の前半 (パッケージ名とバージョン)
# @param $3 パッケージ方針 (rpmならリリースの接尾辞を許す)
# @param $4- 実行するコマンドとその引数
# @note 期待する出力が空、または空白を含む場合は版の部分が取れていないため、
#       比較せずにFAILにする
#       この経路は起動もログの切り替えもサンドボックスの処理も通らないため、
#       ディスプレイもD-Busも特権も要らない
#
run_version_flag_test() {
	local label="$1" expected="$2" policy="$3"
	shift 3
	if [[ -z $expected || $expected == *' ' ]]; then
		fail "$label --version: expected prefix '$expected' has no" \
			'version component (metadata query returned empty?)'
		return
	fi
	local out rc
	out=$("$@" --version 2>&1)
	rc=$?
	local matches=false
	if [[ $out == "$expected" ]]; then
		matches=true
	elif [[ $policy == rpm && $out == "$expected"-* ]]; then
		local suffix="${out#"$expected"-}"
		[[ $suffix =~ ^[0-9]+(\.[0-9]+)*$ ]] && matches=true
	fi
	if (( rc == 0 )) && [[ $matches == true ]]; then
		pass "$label --version prints '$out' (exit 0)"
	else
		fail "$label --version: rc=$rc output='$out'" \
			"(want prefix '$expected')"
	fi
}

# 途中で中断されたときに、呼び出し側のtrapから起動を片付けられるよう状態を持つ
_smoke_launch_pid='' # 起動したランナーのPID
_smoke_group_pid=''  # 実際に片付ける対象のプロセスグループID
_smoke_cache_root='' # 実行ごとの隔離ディレクトリ (終了時に消す)
_smoke_xvfb_log=''   # Xvfbの出力を書いたファイル (終了時に消す)

#
# @brief 中断された起動を強制的に止め、実行ごとの一時ファイルを消す
# @global _smoke_launch_pid、_smoke_group_pid (参照のみ)
# @global _smoke_cache_root、_smoke_xvfb_log (参照のみ)
# @note runuserで別ユーザーに落とした場合は、
#       ランナー自身とそのプロセスグループが別物になるため、両方を止める
#
_launch_smoke_cleanup() {
	if [[ -n $_smoke_launch_pid ]]; then
		kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null
	fi
	if [[ -n $_smoke_group_pid && $_smoke_group_pid != "$_smoke_launch_pid" ]]; then
		kill -KILL -- "-$_smoke_group_pid" 2>/dev/null
	fi
	[[ -n $_smoke_cache_root ]] && rm -rf "$_smoke_cache_root"
	[[ -n $_smoke_xvfb_log ]] && rm -rf "$_smoke_xvfb_log"
}

#
# @brief ログにサンドボックス初期化の拒否を示す痕跡があるか調べる
# @param $* 調べるログファイル
# @return 0 = 痕跡がある、1 = ない
# @note コンテナがuser名前空間やPID名前空間の作成を禁じている場合、
#       Chromiumはこの形で失敗する
#       環境の制約を実装の不具合と混同しないために使う
#
_smoke_sandbox_denied() {
	local log
	for log in "$@"; do
		[[ -f $log ]] || continue
		grep -qE 'Failed to move to new namespace|zygote_host_impl_linux' \
			"$log" && return 0
		grep -q 'Operation not permitted' "$log" \
			&& grep -q 'namespace' "$log" && return 0
	done
	return 1
}

#
# @brief パッケージ済みのアプリをXvfbとD-Busの下で起動し、起動できるかを確かめる
# @param $1 表示に使うラベル
# @param $2 実行ユーザーを落とす先 (空ならそのまま実行する)
# @param $3- 実行するコマンドとその引数
# @note 判定は、ランチャーがElectronをexecする直前に書くExecuting:の行を待ち、
#       そのあと猶予の時間だけプロセスグループが生き残ることで行う
#       SUSE向けに、HOMEと4つのXDG (CONFIG、CACHE、DATA、STATE) を
#       実行ごとの一時ディレクトリへ分離し、
#       ログはclaude-desktop-suseの名前空間に置く
#       xvfb-run、dbus-run-session、setsidがない場合はSKIPにする
#
run_launch_smoke_test() {
	local label="$1" run_as="$2"
	shift 2

	local skip="Skipping launch smoke test for $label"
	local -a missing_tools=()
	local tool
	for tool in xvfb-run dbus-run-session setsid; do
		command -v "$tool" &>/dev/null || missing_tools+=("$tool")
	done
	if (( ${#missing_tools[@]} > 0 )); then
		skip "$skip (missing: ${missing_tools[*]})"
		return
	fi
	if [[ -n $run_as ]] && ! command -v runuser &>/dev/null; then
		skip "$skip (runuser missing)"
		return
	fi

	local cache_root xvfb_log launcher_log
	cache_root=$(mktemp -d)
	xvfb_log=$(mktemp)
	local pgid_file="$cache_root/launch.pgid"
	launcher_log="$cache_root/claude-desktop-suse/launcher.log"
	_smoke_cache_root="$cache_root"
	_smoke_xvfb_log="$xvfb_log"

	local -a runner=(setsid)
	if [[ -n $run_as ]]; then
		if [[ $(id -u) -eq 0 ]]; then
			if ! chown "$run_as" "$cache_root"; then
				skip "$skip (cannot transfer smoke root ownership)"
				rm -rf "$cache_root" "$xvfb_log"
			_smoke_cache_root=''
			_smoke_xvfb_log=''
			return
			fi
		else
			chmod 0777 "$cache_root"
		fi
		# shellcheck disable=SC2016  # 意図どおり: $$ $1 $@ は内側のbash -cで展開させる
		runner+=(runuser -u "$run_as" -- setsid bash -c
			'printf "%s\\n" "$$" > "$1"; shift; exec "$@"'
			smoke-runner "$pgid_file")
	fi
	# 4つのXDGとHOMEをcache_rootの下に閉じ込める
	# ランチャーのログをテストが所有でき、実ユーザーの状態には触れない
	runner+=(env
		"HOME=$cache_root"
		"XDG_CONFIG_HOME=$cache_root/config"
		"XDG_CACHE_HOME=$cache_root"
		"XDG_DATA_HOME=$cache_root/share"
		"XDG_STATE_HOME=$cache_root/state"
		xvfb-run -a -s '-screen 0 1280x720x24'
		dbus-run-session -- "$@")

	"${runner[@]}" >"$xvfb_log" 2>&1 &
	_smoke_launch_pid=$!
	_smoke_group_pid="$_smoke_launch_pid"
	if [[ -n $run_as ]]; then
		# 外側のPIDと、runuserの内側で作られるプロセスグループIDは別物である
		# 内側から書き出してもらい、確かめてから片付けの対象にする
		local pgid_deadline=$((SECONDS + 5))
		while ((SECONDS < pgid_deadline)) && [[ ! -s $pgid_file ]]; do
			sleep 0.1
		done
		if [[ -s $pgid_file ]]; then
			local candidate_group_pid run_as_uid
			read -r candidate_group_pid <"$pgid_file"
			run_as_uid=$(id -u "$run_as" 2>/dev/null) || run_as_uid=''
			if [[ $candidate_group_pid =~ ^[1-9][0-9]*$ \
				&& -n $run_as_uid \
				&& $(stat -c '%u' "/proc/$candidate_group_pid" \
					2>/dev/null) == "$run_as_uid" ]]; then
				_smoke_group_pid="$candidate_group_pid"
			fi
		fi
		if [[ $_smoke_group_pid == "$_smoke_launch_pid" ]]; then
			kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null || true
			wait "$_smoke_launch_pid" 2>/dev/null || true
			skip "$skip (inner runuser process group could not be verified)"
			rm -rf "$cache_root" "$xvfb_log"
			_smoke_launch_pid=''
			_smoke_group_pid=''
			_smoke_cache_root=''
			_smoke_xvfb_log=''
			return
		fi
	fi
	local smoke_pid="$_smoke_group_pid"

	local readiness_marker='Executing: ' # ブート完了を示すランチャーのログ行
	local readiness_timeout=30 grace=8 deadline saw_marker=0
	deadline=$((SECONDS + readiness_timeout))
	while ((SECONDS < deadline)); do
		if [[ -f $launcher_log ]] \
			&& grep -qF "$readiness_marker" "$launcher_log"; then
			saw_marker=1
			break
		fi
		kill -0 "$smoke_pid" 2>/dev/null || break
		sleep 0.5
	done

	# 起動直後に落ちていないか、猶予の間だけ様子を見る
	if ((saw_marker == 1)); then
		deadline=$((SECONDS + grace))
		while ((SECONDS < deadline)); do
			if [[ -f $launcher_log ]] && grep -qF \
				'Electron exited with code:' "$launcher_log"; then
				saw_marker=0
				break
			fi
			if ! kill -0 "$smoke_pid" 2>/dev/null; then
				saw_marker=0
				break
			fi
			sleep 0.5
		done
	fi

	if ((saw_marker == 1)); then
		pass "$label reached ready state under Xvfb"
	else
		local detail exit_code
		if kill -0 "$smoke_pid" 2>/dev/null; then
			detail="$label did not reach ready state within"
			detail+=" ${readiness_timeout}s"
		else
			wait "$_smoke_launch_pid" 2>/dev/null
			exit_code=$?
			detail="$label exited before reaching ready state"
			detail+=" (exit: $exit_code)"
		fi
		if [[ -f $launcher_log ]]; then
			echo '--- launcher.log (last 40 lines) ---' >&2
			tail -40 "$launcher_log" >&2
			echo '------------------------------------' >&2
		fi
		if [[ -s $xvfb_log ]]; then
			echo '--- xvfb-run stderr (last 20 lines) ---' >&2
			tail -20 "$xvfb_log" >&2
			echo '---------------------------------------' >&2
		fi
		if _smoke_sandbox_denied "$launcher_log" "$xvfb_log"; then
			skip "$label: Chromium sandbox cannot initialize in this container (namespace creation denied by seccomp/userns policy)"
		else
			fail "$detail"
		fi
	fi

	kill -TERM -- "-$_smoke_launch_pid" 2>/dev/null || true
	if [[ -n $_smoke_group_pid && $_smoke_group_pid != "$_smoke_launch_pid" ]]; then
		kill -TERM -- "-$_smoke_group_pid" 2>/dev/null || true
	fi
	sleep 1
	kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null || true
	if [[ -n $_smoke_group_pid && $_smoke_group_pid != "$_smoke_launch_pid" ]]; then
		kill -KILL -- "-$_smoke_group_pid" 2>/dev/null || true
	fi
	wait "$_smoke_launch_pid" 2>/dev/null || true
	rm -rf "$cache_root" "$xvfb_log"
	_smoke_launch_pid=''
	_smoke_group_pid=''
	_smoke_cache_root=''
	_smoke_xvfb_log=''
}

#
# @brief 検査結果の内訳を表示し、失敗があれば終了コード1で終わる
# @global _pass_count、_fail_count、_skip_count (参照のみ)
# @note CIではARTIFACT_FAIL_ON_SKIP=1を設定する
#       ツールやデバイスが足りずにSKIPになった検査が残ったまま、
#       ジョブが緑になるのを防ぐため
#
print_summary() {
	echo
	echo '================================'
	printf 'Results: %d passed, %d failed\n' "$_pass_count" "$_fail_count"
	printf 'Skipped: %d\n' "$_skip_count"
	echo '================================'
	if [[ $_fail_count -gt 0 ]]; then
		exit 1
	fi
	if [[ ${ARTIFACT_FAIL_ON_SKIP:-0} == '1' && $_skip_count -gt 0 ]]; then
		printf '[FAIL] %d check(s) skipped and ARTIFACT_FAIL_ON_SKIP=1\n' \
			"$_skip_count" >&2
		exit 1
	fi
}
