#!/usr/bin/env bash
#
# @file external-harness.sh
# @brief SUSEの.rpmまたは.AppImageを通常のランチャーから起動し、L2の到達性だけを確認する
#
# 確認するのは、ファイルが配置されているか (file probe) と、
# ウィンドウやトレイが実際に観測できるか (L2) に限る
# Electronの内部、inspector、CDP、DevTools、リモートデバッグには触れない
#
# 使い方 : external-harness.sh --artifact PATH [--results PATH]
# 終了コード :
#   0  = すべてのprobeがPASS
#   1  = FAILがある、または引数と入力の不備
#   2  = [--help]による使い方の表示
#   77 = SKIPがある (環境が足りない場合、実装の不備とは区別する)
#
# 結果は1probe1行のJSON Linesで書き出し、ログは実行ごとに残す
# probe名、期待値、実測値、終了コード、ログのパスを後から追えるようにするため
#

readonly schema_version=1         # 出力するJSONの形式の版
readonly run_base='/tmp/opencode' # 実行時の作業領域を置く親ディレクトリ
artifact=''                       # 検証する.rpmまたは.AppImageのパス
artifact_count=0                  # [--artifact]の指定回数 (1回だけ許可する)
artifact_type=''                  # 成果物の種類 (rpm または appimage)
results_file=''                   # 結果のJSON Linesの書き出し先
run_root=''                       # 実行ごとに作る一時ディレクトリ
log_dir=''                        # 各probeのログを置くディレクトリ
retained_log_dir=''               # 実行後に残すログのディレクトリ
launcher=''                       # 起動に使うランチャーのパス
desktop_entry=''                  # .desktopファイルのパス
resources_dir=''                  # app.asarを置くresourcesディレクトリ
wm_class=''                       # 期待するウィンドウのWM_CLASS
launcher_class=''                 # 起動中のプロセスを見分けるクラス文字列
rpm_installed=false               # 同じNEVRAのRPMが導入済みか
app_pid=''                        # 起動したランチャーのPID
app_pgid=''                       # 起動時のプロセスグループID
pass_count=0                      # PASSしたprobeの数
fail_count=0                      # FAILしたprobeの数
skip_count=0                      # SKIPしたprobeの数

#
# @brief JSONの文字列リテラルに埋め込めるよう、値をエスケープする
# @param $1 エスケープする文字列
# @stdout エスケープした文字列
# @note 結果は行単位のJSONとして読ませるため、
#       バックスラッシュ、引用符、改行、復帰、タブを順に置き換える
#
json_escape() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '%s' "$value"
}

#
# @brief 現在時刻をミリ秒に直して返す
# @stdout エポックからの経過ミリ秒
# @note 各probeの所要時間を結果に残し、遅い箇所を後から見分けられるようにする
#
now_ms() {
	local nanoseconds
	nanoseconds=$(date +%s%N)
	printf '%d' $((nanoseconds / 1000000))
}

#
# @brief 1つのprobeの結果をJSON Linesとして追記する
# @param $1 probe_id (probeを識別する短い名前)
# @param $2 probe (probeの説明)
# @param $3 expected (期待値)
# @param $4 actual (実測値)
# @param $5 exit_code (実行したコマンドの終了コード)
# @param $6 status (PASS、FAIL、SKIP)
# @param $7 skip_reason (SKIPの理由)
# @param $8 log_path (ログのパス)
# @param $9 duration_ms (所要時間)
# @global pass_count、fail_count、skip_count (結果に応じて増やす)
# @global schema_version、results_file (参照のみ)
# @note 実測値は改行を空白に畳んで500文字までに切り、
#       長いログが1行のJSONを壊さないようにする
#
record() {
	local probe_id="$1" probe="$2" expected="$3" actual="$4"
	local exit_code="$5" status="$6" skip_reason="$7" log_path="$8"
	local duration_ms="$9" escaped
	escaped=$(printf '%s' "$actual" | tr '\n' ' ' | cut -c1-500)
	printf '{"schema_version":%d,"probe_id":"%s","probe":"%s","expected":"%s","actual":"%s","exit_code":%d,"status":"%s","skip_reason":"%s","log_path":"%s","timestamp":"%s","duration_ms":%d}\n' \
		"$schema_version" "$(json_escape "$probe_id")" "$(json_escape "$probe")" \
		"$(json_escape "$expected")" "$(json_escape "$escaped")" "$exit_code" \
		"$status" "$(json_escape "$skip_reason")" "$(json_escape "$log_path")" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$duration_ms" >> "$results_file"
	# 最後の要約で内訳を出すため、結果ごとの件数を数えておく
	case "$status" in
		PASS) ((pass_count++)) ;;
		FAIL) ((fail_count++)) ;;
		SKIP) ((skip_count++)) ;;
	esac
}

#
# @brief コマンドを実行し、その終了コードをprobeの合否として記録する
# @param $1 probe_id
# @param $2 probe
# @param $3 expected (期待値)
# @param $4 log_path (標準出力と標準エラーを書き出す先)
# @param $5- 実行するコマンドとその引数
# @note 終了コード0をPASS、それ以外をFAILとして扱う
#       実測値にはコマンドの出力をそのまま残す
#
probe_command() {
	local probe_id="$1" probe="$2" expected="$3" log_path="$4"
	shift 4
	local start end status exit_code actual
	start=$(now_ms)
	"$@" > "$log_path" 2>&1
	exit_code=$?
	end=$(now_ms)
	actual=$(<"$log_path")
	if ((exit_code == 0)); then status=PASS; else status=FAIL; fi
	record "$probe_id" "$probe" "$expected" "$actual" "$exit_code" \
		"$status" '' "$log_path" "$((end - start))"
}

#
# @brief 環境が足りないprobeをSKIPとして記録する
# @param $1 probe_id
# @param $2 probe
# @param $3 expected (期待値)
# @param $4 reason (SKIPの理由、そのままログにも書く)
# @global log_dir (参照のみ)
# @note 終了コードには77 (SKIPを表す値) を記録する
#       SKIPをFAILと混ぜないため、理由の文章を必ず残す
#
skip_probe() {
	local probe_id="$1" probe="$2" expected="$3" reason="$4"
	local log_path="$log_dir/$probe_id.log"
	printf '%s\n' "$reason" > "$log_path"
	record "$probe_id" "$probe" "$expected" "$reason" 77 SKIP "$reason" \
		"$log_path" 0
}

#
# @brief 使い方を標準エラーに表示する
# @stderr 引数の形式
#
usage() {
	printf 'Usage: %s --artifact PATH [--results PATH]\n' "$0" >&2
}

#
# @brief コマンドライン引数を解釈してグローバル変数に設定する
# @param $@ コマンドライン引数
# @global artifact、artifact_type、results_file、artifact_count (本関数で設定する)
# @return 0 = 解析成功、1 = 引数の誤り、2 = [--help]
# @note [--artifact]はちょうど1回だけ受け付ける
#       拡張子で.rpmと.AppImageを見分け、それ以外は受け付けない
#       パスは絶対パスに直し、後段が作業ディレクトリに左右されないようにする
#
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--artifact)
				# 値が続いていなければ、使い方だけ出して失敗する
				[[ $# -ge 2 ]] || { usage; return 1; }
				artifact="$2"
				((artifact_count++))
				shift 2
				;;
			--results)
				# 結果の保存先を差し替えたい場合に使う
				[[ $# -ge 2 ]] || { usage; return 1; }
				results_file="$2"
				shift 2
				;;
			--help|-h)
				# 使い方の表示だけを求められた場合は、成功とも失敗とも違う2を返す
				usage
				return 2
				;;
			*)
				# 知らない引数は黙って無視せず、使い方を出して失敗する
				usage
				return 1
				;;
		esac
	done
	[[ -n $artifact ]] || { usage; return 1; }
	[[ $artifact_count -eq 1 ]] || { printf 'Exactly one --artifact is required\n' >&2; return 1; }
	[[ -f $artifact ]] || { printf 'Artifact is not a file: %s\n' "$artifact" >&2; return 1; }
	case "$artifact" in
		*.rpm) artifact_type=rpm ;;
		*.AppImage) artifact_type=appimage ;;
		*) printf 'Artifact must end in .rpm or .AppImage\n' >&2; return 1 ;;
	esac
	artifact=$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")
	return 0
}

#
# @brief 実行ごとの一時ディレクトリを作り、HOMEとXDGをそこへ分離する
# @global run_root、log_dir、retained_log_dir、results_file (本関数で設定する)
# @return 0 = 準備成功、1 = 作成や書き込みに失敗
# @note 実ユーザーの~/.config/Claudeや既存のキャッシュを壊さないため、
#       HOMEとすべてのXDGディレクトリを一時領域へ向ける
#       XDG_RUNTIME_DIRは所有者だけが読めるよう0700にする
#
setup_isolation() {
	mkdir -p "$run_base" || return 1
	run_root=$(mktemp -d "$run_base/claude-desktop-suse-harness.XXXXXX") || return 1
	retained_log_dir="$run_base/claude-desktop-suse-logs.$$"
	log_dir="$retained_log_dir"
	mkdir -p "$log_dir" || return 1
	if [[ -z $results_file ]]; then
		results_file="$run_base/claude-desktop-suse-results.$$.jsonl"
	else
		mkdir -p "$(dirname "$results_file")" || return 1
	fi
	: > "$results_file" || return 1
	export HOME="$run_root/home"
	export XDG_CONFIG_HOME="$run_root/config"
	export XDG_CACHE_HOME="$run_root/cache"
	export XDG_DATA_HOME="$run_root/data"
	export XDG_STATE_HOME="$run_root/state"
	export XDG_RUNTIME_DIR="$run_root/runtime"
	mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" \
		"$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
	chmod 700 "$XDG_RUNTIME_DIR"
}

#
# @brief .desktopファイルを探し、期待するWM_CLASSを取り出す
# @global desktop_entry、wm_class (本関数で設定する)
# @global artifact_type、rpm_installed、run_root (参照のみ)
# @return 0 = 見つかった、1 = .desktopがない、またはStartupWMClassがない
# @note RPMを実際に導入した場合は、システムに置かれた.desktopを使う
#       展開しただけの場合は、展開先にある.desktopを探す
#
resolve_desktop_entry() {
	desktop_entry=''
	if [[ $artifact_type == rpm && $rpm_installed == true ]]; then
		desktop_entry='/usr/share/applications/claude-desktop.desktop'
	else
		desktop_entry=$(find "$run_root/extract" -type f -name '*.desktop' -print -quit 2>/dev/null)
	fi
	[[ -f $desktop_entry ]] || return 1
	wm_class=$(awk -F= '/^StartupWMClass=/{print $2; exit}' "$desktop_entry")
	[[ -n $wm_class ]]
}

#
# @brief ランチャーがElectron起動時に付けるクラス文字列を取り出す
# @global launcher_class (本関数で設定する)
# @global resources_dir (参照のみ)
# @return 0 = 見つかった、1 = launcher-common.shがない、または定義がない
# @note このクラスは、既に起動しているClaudeと取り違えないための目印になる
#       resourcesのパスからnode_modules以降を除いたディレクトリを起点に探す
#
resolve_launcher_class() {
	local launcher_common
	launcher_common=$(find "${resources_dir%%/node_modules/*}" -maxdepth 2 \
		-type f -name 'launcher-common.sh' -print -quit 2>/dev/null)
	[[ -f $launcher_common ]] || return 1
	launcher_class=$(sed -n "s/^readonly WM_CLASS='\([^']*\)'$/\1/p" \
		"$launcher_common" | head -n 1)
	[[ -n $launcher_class ]]
}

#
# @brief RPMを展開し、導入せずに中身を調べられるようにする
# @global artifact、run_root、log_dir (参照のみ)
# @return 0 = 展開成功、1 = rpm2cpioかcpioがない、または展開に失敗
# @note 導入前の成果物も検証できるようにするための経路である
#
extract_rpm() {
	mkdir -p "$run_root/extract"
	if ! command -v rpm2cpio >/dev/null 2>&1 || ! command -v cpio >/dev/null 2>&1; then
		return 1
	fi
	(rpm2cpio "$artifact" | (cd "$run_root/extract" && cpio -idm --quiet)) \
		> "$log_dir/rpm-extract.log" 2>&1
}

#
# @brief AppImageを展開し、中身を調べられるようにする
# @global artifact、run_root、log_dir (参照のみ)
# @return 0 = 展開成功、1 = 展開に失敗
# @note AppImage自身の--appimage-extractを使うため、追加のツールは要らない
#       結果はrun_root/extract/squashfs-rootに置かれる
#
extract_appimage() {
	mkdir -p "$run_root/extract"
	(cd "$run_root/extract" && "$artifact" --appimage-extract) \
		> "$log_dir/appimage-extract.log" 2>&1
}

#
# @brief 成果物の種類に応じて、ランチャーとresourcesの位置を決める
# @global launcher、resources_dir、rpm_installed (本関数で設定する)
# @global artifact、artifact_type、run_root、log_dir (参照のみ)
# @note 同じNEVRAのRPMが導入済みなら、システムのランチャーをそのまま使う
#       そうでなければ展開したツリーのランチャーを使う
#       NEVRAの一致まで確かめるのは、別の版が入っている場合に、
#       成果物ではなく既存のインストールを測ってしまうのを防ぐため
#
resolve_artifact() {
	if [[ $artifact_type == rpm ]]; then
		local package_name='claude-desktop' requested_nevra installed_nevra
		if command -v rpm >/dev/null 2>&1; then
			package_name=$(rpm -qp --qf '%{NAME}' "$artifact" 2>/dev/null) || package_name=claude-desktop
		fi
		if command -v rpm >/dev/null 2>&1 && rpm -q "$package_name" >/dev/null 2>&1 \
			&& [[ -x /usr/bin/claude-desktop ]]; then
			requested_nevra=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' \
				"$artifact" 2>/dev/null)
			installed_nevra=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' \
				"$package_name" 2>/dev/null)
			if [[ -n $requested_nevra && $requested_nevra == "$installed_nevra" ]]; then
				rpm_installed=true
				launcher='/usr/bin/claude-desktop'
				resources_dir='/usr/lib/claude-desktop/node_modules/electron/dist/resources'
			fi
		fi
		if [[ $rpm_installed != true ]]; then
			# ここに来た時点で導入済みではないため、明示して展開ツリー側に倒す
			rpm_installed=false
			if ! extract_rpm; then
				printf 'RPM extraction unavailable or failed\n' > "$log_dir/rpm-extract.log"
			fi
			launcher="$run_root/extract/usr/bin/claude-desktop"
			resources_dir="$run_root/extract/usr/lib/claude-desktop/node_modules/electron/dist/resources"
		fi
	else
		if ! extract_appimage; then
			printf 'AppImage extraction failed\n' > "$log_dir/appimage-extract.log"
		fi
		launcher="$artifact"
		resources_dir="$run_root/extract/squashfs-root/usr/lib/node_modules/electron/dist/resources"
	fi
	resolve_desktop_entry || true
	resolve_launcher_class || true
}

#
# @brief 成果物の中に必要なファイルが揃っているかを確認する
# @global launcher、desktop_entry、resources_dir、wm_class (参照のみ)
# @global log_dir (参照のみ)
# @note 無い場合はFAILとして、期待値と実測値を残す
#       .desktopやStartupWMClassは成果物の構成によっては存在しないため、
#       その場合はSKIPにしてFAILと区別する
#
file_probes() {
	local expected
	if [[ -x $launcher ]]; then
		probe_command launcher launcher 'launcher is executable' \
			"$log_dir/launcher.log" printf '%s' "$launcher"
	else
		probe_command launcher launcher 'launcher is executable' \
			"$log_dir/launcher.log" bash -c "printf 'missing or not executable: %s' \"\$1\"; exit 1" _ "$launcher"
	fi
	if [[ -f $desktop_entry ]]; then
		probe_command desktop_entry desktop_entry 'desktop entry exists' \
			"$log_dir/desktop-entry.log" cat "$desktop_entry"
	else
		skip_probe desktop_entry desktop_entry 'desktop entry exists' \
			'desktop entry unavailable in artifact layout'
	fi
	if [[ -f $resources_dir/app.asar ]]; then
		probe_command app_asar app_asar 'resources/app.asar exists' \
			"$log_dir/app-asar.log" stat -c '%s bytes %n' "$resources_dir/app.asar"
	else
		probe_command app_asar app_asar 'resources/app.asar exists' \
			"$log_dir/app-asar.log" bash -c "printf 'missing: %s' \"\$1\"; exit 1" _ \
			"$resources_dir/app.asar"
	fi
	if [[ -n $wm_class ]]; then
		probe_command desktop_wm_class desktop_wm_class 'StartupWMClass is present' \
			"$log_dir/wm-class.log" printf '%s' "$wm_class"
	else
		skip_probe desktop_wm_class desktop_wm_class \
			'StartupWMClass is present' 'desktop entry has no StartupWMClass'
	fi
}

#
# @brief L2のprobeをまとめてSKIPとして記録する
# @param $1 SKIPの理由
# @note 起動できない理由が1つ決まれば、関連する5つのprobeも同じ理由でSKIPになる
#
skip_l2() {
	skip_probe launch_process launch_process 'normal launcher reaches process state' "$1"
	skip_probe process_log_state process_log_state 'launcher log/process state is observable' "$1"
	skip_probe window_reachability window_reachability 'X11/XWayland window is reachable with xprop' "$1"
	skip_probe window_title window_title 'X11/XWayland title is readable with xprop' "$1"
	skip_probe tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' "$1"
}

#
# @brief 指定したPIDが、起動時に作ったプロセスグループに属するかを確かめる
# @param $1 確認するPID
# @global app_pgid (参照のみ)
# @return 0 = 同じグループ、1 = 違うグループかPIDが既にない
# @note ランチャーはElectronを子プロセスとして抱えたまま動き続ける
#       そのためウィンドウやトレイの項目を持つのは$app_pidではなく子孫である
#       それらはすべてsetsidが作ったプロセスグループに残るので、
#       グループIDが一致するかで自分の起動分かを見分けられる
#
pid_in_launch_group() {
	local pgid
	pgid=$(ps -o pgid= -p "$1" 2>/dev/null) || return 1
	[[ ${pgid//[[:space:]]/} == "$app_pgid" ]]
}

#
# @brief WM_CLASSが一致するウィンドウを探し、IDとタイトルとクラスを返す
# @global wm_class、app_pgid (参照のみ)
# @stdout ウィンドウID、_NET_WM_NAME、WM_CLASSを1行ずつ
# @return 0 = 見つかった、1 = 見つからない
# @note _NET_CLIENT_LISTに並ぶウィンドウのうち、
#       自分のプロセスグループに属し、WM_CLASSが一致するものだけを採る
#       別のインスタンスのウィンドウを拾わないための条件である
#
find_window() {
	local window_id pid_line title_line class_line
	local client_list
	client_list=$(xprop -root _NET_CLIENT_LIST 2>/dev/null) || return 1
	while read -r window_id; do
		[[ -n $window_id ]] || continue
		pid_line=$(xprop -id "$window_id" _NET_WM_PID 2>/dev/null) || continue
		[[ $pid_line =~ =[[:space:]]*([0-9]+)$ ]] || continue
		pid_in_launch_group "${BASH_REMATCH[1]}" || continue
		title_line=$(xprop -id "$window_id" _NET_WM_NAME 2>/dev/null) || true
		class_line=$(xprop -id "$window_id" WM_CLASS 2>/dev/null) || true
		[[ $class_line == *"\"$wm_class\""* ]] || continue
		[[ -n $title_line ]] || continue
		printf '%s\n%s\n%s\n' "$window_id" "$title_line" "$class_line"
		return 0
	done < <(printf '%s\n' "$client_list" | tr ',' ' ' | grep -oE '0x[0-9a-fA-F]+')
	return 1
}

#
# @brief 通常のランチャーでアプリを起動し、ウィンドウとトレイに到達できるか確かめる
# @global app_pid、app_pgid (本関数で設定する)
# @global launcher、wm_class、launcher_class (参照のみ)
# @global artifact_type、rpm_installed、log_dir (参照のみ)
# @note 前提が足りない場合はskip_l2で理由を残して戻る
#       既に同じクラスのClaudeが動いている場合は、
#       そのプロセスに干渉しないよう起動しない
#       起動はsetsidで新しいプロセスグループに切り離し、
#       cleanupでまとめて止められるようにする
#
launch_l2() {
	if [[ $artifact_type == rpm && $rpm_installed == false ]]; then
		skip_l2 'RPM is not installed; normal /usr/bin/claude-desktop launch is unavailable'
		return
	fi
	if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
		skip_l2 'no display session; L2 launch skipped'
		return
	fi
	if [[ -z ${DISPLAY:-} ]]; then
		skip_l2 'native Wayland: unsupported L2 window-query; xprop is X11-only'
		return
	fi
	if ! command -v xprop >/dev/null 2>&1 || ! xprop -help >/dev/null 2>&1; then
		skip_l2 'xprop unavailable; install X11 tools with zypper'
		return
	fi
	if [[ -z $wm_class ]]; then
		skip_l2 'StartupWMClass unavailable; window identity is not safe to infer'
		return
	fi
	if [[ -z $launcher_class ]]; then
		skip_l2 'launcher process fingerprint unavailable; cannot rule out a running instance'
		return
	fi
	if command -v pgrep >/dev/null 2>&1 && pgrep -u "$(id -u)" -f -- \
		"--class=$launcher_class( |$)" >/dev/null 2>&1; then
		skip_l2 'an existing Claude process owns the launcher class; refusing to interfere'
		return
	fi
	local start end actual window_data
	start=$(now_ms)
	setsid env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
		XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
		XDG_STATE_HOME="$XDG_STATE_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
		CLAUDE_PASSWORD_STORE=basic "$launcher" \
		> "$log_dir/launcher-process.log" 2>&1 &
	app_pid=$!
	app_pgid=$app_pid
	sleep 2                               # Electronが立ち上がりログを書き出すまでの猶予
	end=$(now_ms)
	if kill -0 "$app_pid" 2>/dev/null; then
		record launch_process launch_process 'normal launcher reaches process state' \
			"pid=$app_pid" 0 PASS '' "$log_dir/launcher-process.log" \
			"$((end - start))"
		if [[ -s $XDG_CACHE_HOME/claude-desktop-suse/launcher.log ]]; then
			cp "$XDG_CACHE_HOME/claude-desktop-suse/launcher.log" \
				"$log_dir/launcher.log" 2>/dev/null || true
			record process_log_state process_log_state \
				'launcher log exists while process is alive' 'launcher.log exists' \
				0 PASS '' "$log_dir/launcher.log" 0
		else
			skip_probe process_log_state process_log_state \
				'launcher log exists while process is alive' \
				'launcher log was not created before process probe'
		fi
	else
		actual=$(<"$log_dir/launcher-process.log")
		record launch_process launch_process 'normal launcher reaches process state' \
			"$actual" 1 FAIL '' "$log_dir/launcher-process.log" \
			"$((end - start))"
		return
	fi
	# ウィンドウが現れるまでの待ち時間は[HARNESS_WINDOW_TIMEOUT]で変えられる (既定30秒)
	local window_deadline=$((SECONDS + ${HARNESS_WINDOW_TIMEOUT:-30}))
	until window_data=$(find_window); do
		if ((SECONDS >= window_deadline)) || ! kill -0 "$app_pid" 2>/dev/null; then
			window_data=''
			break
		fi
		sleep 1
	done
	if [[ -n $window_data ]]; then
		printf '%s\n' "$window_data" > "$log_dir/window.log"
		record window_reachability window_reachability \
			'X11/XWayland window is reachable with xprop' "$window_data" 0 PASS '' \
			"$log_dir/window.log" 0
		record window_title window_title 'X11/XWayland title is readable with xprop' \
			"$(printf '%s\n' "$window_data" | sed -n '2p')" 0 PASS '' \
			"$log_dir/window.log" 0
	else
		record window_reachability window_reachability \
			'X11/XWayland window is reachable with xprop' \
			'No window owned by the launcher PID matched WM_CLASS' 1 FAIL '' \
			"$log_dir/window.log" 0
		record window_title window_title 'X11/XWayland title is readable with xprop' \
			'No non-empty title was available' 1 FAIL '' "$log_dir/window.log" 0
	fi
	if ! command -v dbus-send >/dev/null 2>&1; then
		skip_probe tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' \
			'dbus-1-tools missing; install with zypper'
	else
		if dbus-send --session --print-reply --dest=org.kde.StatusNotifierWatcher \
			/StatusNotifierWatcher org.freedesktop.DBus.Properties.Get \
			string:org.kde.StatusNotifierWatcher \
			string:RegisteredStatusNotifierItems > "$log_dir/tray.log" 2>&1; then
			local sni_pid tray_pid='' sni_name
			while read -r sni_pid; do
				if pid_in_launch_group "$sni_pid"; then
					tray_pid=$sni_pid
					break
				fi
			done < <(grep -oE 'StatusNotifierItem-[0-9]+-' "$log_dir/tray.log" \
				| grep -oE '[0-9]+' | sort -u)
			# Electron 45 (Chromium 156) は項目を一意バス名 (:1.N) で登録するため、
			# 所有PIDはバスデーモンへ問い合わせて照合する
			if [[ -z $tray_pid ]]; then
				while read -r sni_name; do
					sni_pid=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus \
						/org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID \
						"string:$sni_name" 2>/dev/null | awk '/uint32/ { print $2 }')
					printf 'owner %s pid=%s\n' "$sni_name" "${sni_pid:-unknown}" \
						>> "$log_dir/tray.log"
					if [[ $sni_pid =~ ^[0-9]+$ ]] && pid_in_launch_group "$sni_pid"; then
						tray_pid=$sni_pid
						break
					fi
				done < <(grep -oE '"(:[0-9]+\.[0-9]+)/StatusNotifierItem"' "$log_dir/tray.log" \
					| grep -oE ':[0-9]+\.[0-9]+' | sort -u)
			fi
			if [[ -n $tray_pid ]]; then
				record tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' \
					"StatusNotifierItem owned by PID $tray_pid is registered" 0 PASS '' "$log_dir/tray.log" 0
			else
				skip_probe tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' \
					'Watcher replied but no PID-owned StatusNotifierItem was observed'
			fi
		else
			skip_probe tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' \
				'StatusNotifierWatcher unavailable on the session bus'
		fi
	fi
}

#
# @brief 起動したプロセスを止め、ログを残してから一時ディレクトリを消す
# @global app_pgid、app_pid、log_dir、retained_log_dir、run_root (参照のみ)
# @note EXIT、INT、TERMから呼ばれる
#       まずTERMで穏やかに止め、反応しなければKILLで確実に止める
#       ログはrun_rootごと消える前にretained_log_dirへ複製する
#
cleanup() {
	if [[ -n $app_pgid ]]; then
		kill -TERM -- "-$app_pgid" 2>/dev/null || true
		sleep 1
		kill -KILL -- "-$app_pgid" 2>/dev/null || true
		wait "$app_pid" 2>/dev/null || true
	fi
	if [[ -n $log_dir && -d $log_dir ]]; then
		cp -a "$log_dir"/. "$retained_log_dir"/ 2>/dev/null || true
	fi
	rm -rf "$run_root"
}

#
# @brief 引数を解析し、probeを順に実行して終了コードを決める
# @param $@ コマンドライン引数
# @global pass_count、fail_count、skip_count (参照のみ)
# @global results_file、retained_log_dir (参照のみ)
# @stdout resultsとログの保存先
# @note FAILがあれば1、SKIPだけなら77、すべてPASSなら0を返す
#       実行の最後にrun_summaryを1件記録し、件数の内訳を残す
#
main() {
	parse_args "$@"
	local parse_status=$?
	[[ $parse_status -eq 0 ]] || return "$parse_status"
	setup_isolation || return 1
	trap cleanup EXIT INT TERM
	resolve_artifact
	file_probes
	launch_l2
	record run_summary run_summary 'structured probe run completes' \
		"pass=$pass_count fail=$fail_count skip=$skip_count results=$results_file" \
		0 PASS '' "$results_file" 0
	printf 'results=%s\nlogs=%s\n' "$results_file" "$retained_log_dir"
	if ((fail_count > 0)); then return 1; fi
	if ((skip_count > 0)); then return 77; fi
	return 0
}

# 直接実行されたときだけmainを動かし、sourceされた場合は関数だけを提供する
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
	exit $?
fi
