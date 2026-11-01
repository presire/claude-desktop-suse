# shellcheck shell=bash
#===============================================================================
# @file doctor.sh
# @brief Claude Desktopの動作環境を診断し、問題の原因と対処を表示する
#
# run_doctorがclaude-desktop --doctorの入口となり
# 診断を順に呼び出して結果をまとめる
# launcher-common.shから読み込まれて動くため
# ランチャーが読んだ設定と同じ環境を前提にする
# 単体で読み込んだ場合はlauncher-common.shの関数がないため
# それらを必要としない診断だけを実行する
#
# 診断を追加するときは _check_<名前> という内部関数を作り
# run_doctorの適切な節から呼び出す
# 結果は _pass / _fail / _warn / _info で表示する
# _failはrun_doctorの _doctor_failures を増やし、その数が終了コードになる
#
# 読み込み元 : scripts/launcher-common.sh
#              (rpmとAppImageのランチャーが読み込む)
# 参照するグローバル変数 : WM_CLASS
#              (launcher-common.shの先頭で定義され、ビルド時に置換される)
# 変更するグローバル変数 : なし
#===============================================================================

#
# @brief 診断結果の表示に使う色のエスケープシーケンスを設定する
# @note 標準出力が端末でない場合は色を付けない
#        ログやパイプに制御文字が混ざらないようにするため
#
_doctor_colors() {
	if [[ -t 1 ]]; then
		_green='\033[0;32m'
		_red='\033[0;31m'
		_yellow='\033[0;33m'
		_bold='\033[1m'
		_reset='\033[0m'
	else
		_green='' _red='' _yellow='' _bold='' _reset=''
	fi
}

#
# @brief /etc/os-releaseのIDからディストリビューション名を取り出す
# @stdout ディストリビューションのID (読めない場合はunknown)
#
_cowork_distro_id() {
	local id='unknown'
	if [[ -f /etc/os-release ]]; then
		local line
		while IFS= read -r line; do
			if [[ $line == ID=* ]]; then
				id="${line#ID=}"
				id="${id//\"/}"
				break
			fi
		done < /etc/os-release
	fi
	printf '%s' "$id"
}

#
# @brief Coworkで使うツールの導入コマンドをディストリビューション別に組み立てる
# @param $1 ディストリビューションのID
# @param $2 導入するツール名
# @stdout パッケージマネージャーのコマンドとパッケージ名
# @note 対応するパッケージマネージャーがない場合は一般的な案内文を返す
#
_cowork_pkg_hint() {
	local distro="$1"
	local tool="$2"
	local pkg_cmd

	# パッケージマネージャーのコマンドをディストリビューション別に決める
	case "$distro" in
		# Debian系はaptを使う
		debian|ubuntu) pkg_cmd='sudo apt install' ;;
		# Fedora系はdnfを使う
		fedora)        pkg_cmd='sudo dnf install' ;;
		# Arch系はpacmanを使う
		arch)          pkg_cmd='sudo pacman -S' ;;
		# openSUSEとSLEはzypperを使う
		opensuse*|sles|sled) pkg_cmd='sudo zypper install' ;;
		# 対応するパッケージマネージャーがないため、導入は利用者に任せる
		*)
			printf '%s' "Install $tool using your package manager"
			return
			;;
	esac

	# ツール名をディストリビューションごとのパッケージ名に読み替える
	local pkg
	case "$tool" in
		# QEMUのパッケージ名はディストリビューションごとに異なる
		qemu)
			case "$distro" in
				debian|ubuntu) pkg='qemu-system-x86 qemu-utils' ;;
				fedora)        pkg='qemu-kvm qemu-img' ;;
				arch)          pkg='qemu-full' ;;
				opensuse*|sles|sled) pkg='qemu-x86 qemu-tools' ;;
			esac
			;;
		ibus-gtk3)
			# ArchはGTK3のimmoduleをibus本体に含めている
			# それ以外のディストリビューションではibus-gtk3を別に導入する
			case "$distro" in
				arch) pkg='ibus' ;;
				*)    pkg='ibus-gtk3' ;;
			esac
			;;
		# 名前がそのままパッケージ名になるツール
		*) pkg="$tool" ;;
	esac

	printf '%s' "$pkg_cmd $pkg"
}

#
# @brief パッケージの導入状態を確認する
# @param $1 ディストリビューションのID
# @param $2 確認するパッケージ名
# @return 0 = 導入済み、1 = 未導入、2 = 確認できない
# @note 2は対応するパッケージマネージャーがない場合に返す
#       呼び出し側は2を警告にしない (未対応のディストリビューションで誤検知しないため)
#
_pkg_installed() {
	local distro="$1"
	local pkg="$2"
	case "$distro" in
		# dpkgのデータベースで状態がinstalledになっているかを見る
		debian|ubuntu)
			command -v dpkg-query &>/dev/null || return 2
			dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
				| grep -q 'install ok installed'
			;;
		# openSUSEとSLEもrpmで問い合わせる (zypperの下はrpm)
		fedora|opensuse*|sles|sled)
			command -v rpm &>/dev/null || return 2
			rpm -q "$pkg" &>/dev/null
			;;
		# pacmanのデータベースに登録があるかを見る
		arch)
			command -v pacman &>/dev/null || return 2
			pacman -Q "$pkg" &>/dev/null
			;;
		# 対応するパッケージマネージャーがない
		*) return 2 ;;
	esac
}

#
# @brief 入力メソッドの設定を調べ、キー入力が効かなくなる原因を特定する (#550)
# @param $1 ディストリビューションのID
# @note CLAUDE_GTK_IM_MODULEによる上書きがあれば表示する
#        WaylandセッションでXWayland経由で動く場合
#        IBusの経路がXIMになり、一部のIMEで入力が欠けることを伝える
#        GTK_IM_MODULE=ibusなのにibus-gtk3がない場合と
#        immodulesのキャッシュが古い場合も報告する
#
_doctor_check_im_modules() {
	local distro="$1"
	local active_im="${CLAUDE_GTK_IM_MODULE:-${GTK_IM_MODULE:-}}"

	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		_info "CLAUDE_GTK_IM_MODULE=$CLAUDE_GTK_IM_MODULE" \
			"(overrides GTK_IM_MODULE for Electron)"
	fi

	if [[ ${XDG_SESSION_TYPE:-} == 'wayland' \
		&& -z ${CLAUDE_USE_WAYLAND:-} ]]; then
		_info \
			'IME note: Wayland session, Electron via XWayland —' \
			'IBus path goes through XIM (lossy for some IMEs).'
		_info \
			'Tip: CLAUDE_USE_WAYLAND=1 enables native Wayland IME' \
			'(loses global hotkeys).'
	fi

	# 有効な入力メソッドがなければ、これ以上調べることはない
	[[ -n $active_im ]] || return 0

	# 入力メソッドがibusのときだけibus-gtk3の有無を調べる
	# 戻り値1は未導入なので警告する
	# 戻り値2は未対応のディストリビューションなので黙って素通りする
	# 警告したらここで終える
	# パッケージを導入するとimmodulesのキャッシュも更新され
	# 後続のキャッシュ確認が無意味な警告になるため
	if [[ $active_im == 'ibus' ]]; then
		_pkg_installed "$distro" ibus-gtk3
		case $? in
			# 未導入なので、そのディストリビューション向けの導入コマンドを案内する
			1)
				_warn \
					"GTK_IM_MODULE=ibus but ibus-gtk3 is not installed"
				_info "Fix: $(_cowork_pkg_hint "$distro" ibus-gtk3)"
				return 0
				;;
		esac
	fi

	# GTKのimmodulesキャッシュに有効な入力メソッドが載っているかを確認する
	# gtk-query-immodules-3.0がない環境ではGTK 3を使っていないとみなし
	# 警告せずに素通りする (このコマンドを含むパッケージ名は環境によって異なる)
	command -v gtk-query-immodules-3.0 &>/dev/null || return 0

	if ! gtk-query-immodules-3.0 2>/dev/null \
		| grep -q "\"$active_im\""; then
		_warn \
			"GTK immodules: '$active_im' not listed by" \
			"gtk-query-immodules-3.0 (cache may be stale)"
		_info \
			'Fix: sudo gtk-query-immodules-3.0 --update-cache'
	fi
}

#
# @brief Electronのバイナリと同じ場所にあるversionファイルからバージョンを読む
# @param $1 Electronバイナリのパス
# @stdout バージョン文字列 (読めない場合は何も出力しない)
#
_electron_version() {
	local version_file
	version_file="$(dirname "$1")/version"
	[[ -r $version_file ]] && printf '%s' "$(< "$version_file")"
}

#
# @brief 診断結果を緑色の [PASS] 付きで表示する
# @param $* 表示するメッセージ
#
_pass() { echo -e "${_green}[PASS]${_reset} $*"; }
#
# @brief 診断結果を赤色の [FAIL] 付きで表示し、失敗数を1つ増やす
# @param $* 表示するメッセージ
# @note 増えた失敗数はrun_doctorの終了コードになる
#
_fail() {
	echo -e "${_red}[FAIL]${_reset} $*"
	_doctor_failures=$((_doctor_failures + 1))
}
#
# @brief 診断結果を黄色の [WARN] 付きで表示する
# @param $* 表示するメッセージ
#
_warn() { echo -e "${_yellow}[WARN]${_reset} $*"; }
#
# @brief 判定を伴わない補足情報を、結果の行より字下げして表示する
# @param $* 表示するメッセージ
#
_info() { echo -e "       $*"; }

#
# @brief COWORK_VM_BACKENDに解釈できない値が設定されていることを警告する
# @note デーモン(cowork-vm-service.js)は不正な値を無視して自動判定に進む (#442)
#        そのため深刻度を決める箇所と最後のまとめの両方から呼び
#        どちらでも同じ警告が出るようにしている
#
_warn_unknown_backend() {
	_warn "Unknown COWORK_VM_BACKEND: '${COWORK_VM_BACKEND}'"
	_info 'Valid values: kvm, bwrap, host'
}

#
# @brief virtiofsdの実行ファイルを探す
# @stdout 見つかったパス (見つからない場合は何も出力しない)
# @return 0 = 見つかった、1 = 見つからない
# @note ディストリビューションによってはPATHの外に置かれる
#        そのためPATHを探したあと、既知の場所も順に確認する
#        _COWORK_VFSD_PATHS (コロン区切り)で探索先を差し替えられる
#        名前空間付きの変数名はテスト専用のフックであり、利用者が設定する項目ではない
#        デーモン(cowork-vm-service.js)と同じ探索順を使い
#        doctorの診断とデーモンの実際の判断が食い違わないようにする
#
_find_virtiofsd() {
	local bin
	bin=$(command -v virtiofsd 2>/dev/null)
	if [[ -n $bin ]]; then
		printf '%s' "$bin"
		return 0
	fi

	local fallback_paths="${_COWORK_VFSD_PATHS:-}"
	if [[ -z $fallback_paths ]]; then
		fallback_paths='/usr/libexec/virtiofsd'
		fallback_paths+=':/usr/lib/qemu/virtiofsd'
		fallback_paths+=':/usr/lib/virtiofsd'
	fi

	local fallback
	local IFS=:
	for fallback in $fallback_paths; do
		if [[ -x $fallback ]]; then
			printf '%s' "$fallback"
			return 0
		fi
	done
	return 1
}

#
# @brief 設定に書かれたbwrapの追加マウントを読み、内容と危険な点を表示する
# @note 設定がない場合やJSONを読む手段がない場合は何も表示しない
#        追加マウントが既定のマウントを覆い隠す場合に警告する
#
_doctor_check_bwrap_mounts() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local config_file="$config_dir/claude_desktop_linux_config.json"

	[[ -f $config_file ]] || return 0

	local parser=''
	if command -v python3 &>/dev/null; then
		parser='python3'
	elif command -v node &>/dev/null; then
		parser='node'
	else
		return 0
	fi

	local mounts_json=''
	if [[ $parser == 'python3' ]]; then
		mounts_json=$(python3 - "$config_file" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    mounts = cfg.get('preferences', {}).get('coworkBwrapMounts', {})
    if mounts:
        print(json.dumps(mounts))
except Exception:
    pass
PYEOF
)
	else
		mounts_json=$(node - "$config_file" 2>/dev/null <<'JSEOF'
try {
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const m = (cfg.preferences || {}).coworkBwrapMounts || {};
    if (Object.keys(m).length > 0)
        process.stdout.write(JSON.stringify(m));
} catch (_) {}
JSEOF
)
	fi

	if [[ -z $mounts_json ]]; then
		_info 'Bwrap mounts: default (no custom configuration)'
		return 0
	fi

	_info 'Bwrap custom mount configuration detected:'

	local parsed_output=''
	if [[ $parser == 'python3' ]]; then
		parsed_output=$(python3 - "$mounts_json" 2>/dev/null <<'PYEOF'
import json, sys
def fmt(p):
    if isinstance(p, str):
        return p
    if isinstance(p, dict) and isinstance(p.get('src'), str) \
            and isinstance(p.get('dst'), str):
        return p['src'] + ' -> ' + p['dst']
    return None
m = json.loads(sys.argv[1])
for p in m.get('additionalROBinds', []):
    s = fmt(p)
    if s is not None:
        print(s)
print('---')
for p in m.get('additionalBinds', []):
    s = fmt(p)
    if s is not None:
        print(s)
print('---')
for p in m.get('disabledDefaultBinds', []):
    if isinstance(p, str):
        print(p)
PYEOF
)
	else
		parsed_output=$(node - "$mounts_json" 2>/dev/null <<'JSEOF'
function fmt(p) {
    if (typeof p === 'string') return p;
    if (p && typeof p === 'object'
        && typeof p.src === 'string' && typeof p.dst === 'string') {
        return p.src + ' -> ' + p.dst;
    }
    return null;
}
const m = JSON.parse(process.argv[1]);
(m.additionalROBinds || []).forEach(p => {
    const s = fmt(p);
    if (s !== null) console.log(s);
});
console.log('---');
(m.additionalBinds || []).forEach(p => {
    const s = fmt(p);
    if (s !== null) console.log(s);
});
console.log('---');
(m.disabledDefaultBinds || []).forEach(p => {
    if (typeof p === 'string') console.log(p);
});
JSEOF
)
	fi

	local ro_binds='' rw_binds='' disabled_binds=''
	local section=0
	while IFS= read -r line; do
		if [[ $line == '---' ]]; then
			((section++))
			continue
		fi
		case $section in
			# 読み取り専用の追加マウント
			0) ro_binds+="${line}"$'\n' ;;
			# 読み書き可能な追加マウント
			1) rw_binds+="${line}"$'\n' ;;
			# 無効にした既定のマウント
			2) disabled_binds+="${line}"$'\n' ;;
		esac
	done <<< "$parsed_output"
	ro_binds=${ro_binds%$'\n'}
	rw_binds=${rw_binds%$'\n'}
	disabled_binds=${disabled_binds%$'\n'}

	if [[ -n $ro_binds ]]; then
		_info '  Read-only mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$ro_binds"
	fi

	if [[ -n $rw_binds ]]; then
		_info '  Read-write mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$rw_binds"
	fi

	# 追加マウントのコピー先が既定の読み取り専用マウントと重なると
	# bwrapは後から指定したマウントを優先するため
	# サンドボックス内のシステムパスが黙って置き換わる
	# {src, dst}形式だけがこの状態になりうる
	# 文字列形式はsrc=dstとなり、additionalBindsはsrcがHOME配下に限られるため
	# 既定の読み取り専用マウントとは重ならない
	local shadow_input=''
	[[ -n $ro_binds ]] && shadow_input+="${ro_binds}"$'\n'
	[[ -n $rw_binds ]] && shadow_input+="${rw_binds}"$'\n'
	shadow_input=${shadow_input%$'\n'}
	local shadow_line shadow_dst
	if [[ -n $shadow_input ]]; then
		while IFS= read -r shadow_line; do
			[[ $shadow_line == *' -> '* ]] || continue
			shadow_dst=${shadow_line##* -> }
			# 列挙が長くなるため1行に収める (STYLEGUIDEの80桁例外)
			case $shadow_dst in
				/usr|/usr/*|/etc|/etc/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*)
					# 主要なパスを覆い隠すと、サンドボックス内のコマンドが動かなくなる
					_warn \
						"Mount dst '${shadow_dst}' shadows a default sandbox mount" \
						'(may break system tools inside the sandbox)'
					;;
			esac
		done <<< "$shadow_input"
	fi

	local critical_warned=false
	if [[ -n $disabled_binds ]]; then
		while IFS= read -r bind_path; do
			case "$bind_path" in
				# /usrと/etcは無効にするとサンドボックス内のコマンドが動かなくなる
				/usr|/etc)
					_warn \
						"Disabled default mount: $bind_path" \
						'(may break system tools!)'
					critical_warned=true
					;;
				# それ以外は記録だけして知らせる
				*)
					_info "  Disabled default mount: $bind_path"
					;;
			esac
		done <<< "$disabled_binds"
		if [[ $critical_warned == true ]]; then
			_info \
				'  Disabling /usr or /etc may cause commands' \
				'to fail inside the sandbox.'
			_info \
				'  Restart the daemon after config changes:' \
				'pkill -f cowork-vm-service'
		fi
	fi

	if [[ $critical_warned != true ]]; then
		_info \
			'  Note: Restart daemon for config changes:' \
			'pkill -f cowork-vm-service'
	fi
}

#
# @brief ファイル名の長さ制限が短いファイルシステムを検出する (#590)
# @note Coworkのセッション開始時に、Claude Codeが
#        ~/.claude/projects/配下へセッションごとのディレクトリを作る
#        その名前はホスト側の作業ディレクトリを平坦化したもので
#        Coworkでは約180文字になる
#        eCryptfsのようにNAME_MAXが短い環境 (暗号化の都合で143) では
#        mkdirがENAMETOOLONGで失敗し、セッションが始まらない
#        ext4/btrfs/xfs/zfsは255まで使えるため問題にならない
#
_doctor_check_filename_limit() {
	# 導入直後でディレクトリがまだない場合に備え
	# ~/.claude/projectsから親へたどり、最初に存在する場所を調べる
	# HOMEより上 (/など) には進まない
	local probe_dir="$HOME/.claude/projects"
	while [[ ! -d $probe_dir ]]; do
		probe_dir=$(dirname "$probe_dir")
		[[ $probe_dir == "$HOME" || $probe_dir == / ]] && break
	done
	[[ -d $probe_dir ]] || return 0

	local name_max
	name_max=$(getconf NAME_MAX "$probe_dir" 2>/dev/null) || return 0
	[[ $name_max =~ ^[0-9]+$ ]] || return 0
	# 先頭が0でも8進数と解釈されないよう、10進数として計算する
	name_max=$((10#$name_max))

	((name_max >= 200)) && return 0

	_warn "Filename limit: NAME_MAX=$name_max on $probe_dir (< 200)"
	_info \
		'Cowork sessions create project-dir names up to ~180 chars' \
		'under ~/.claude/projects/; short limits cause ENAMETOOLONG'
	_info 'when Claude Code initializes a session inside cowork (#590).'

	local fs_type
	fs_type=$(df --output=fstype "$probe_dir" 2>/dev/null \
		| awk 'NR==2 {print $1}')
	if [[ $fs_type == 'ecryptfs' ]]; then
		_info \
			'Detected eCryptfs (legacy Ubuntu/Mint encrypted home,' \
			'NAME_MAX=143 due to filename-encryption overhead).'
		_info \
			'Workaround: move ~/.config/Claude onto a separate' \
			'LUKS-encrypted ext4 volume (NAME_MAX=255) and symlink it'
		_info \
			'back. See docs/troubleshooting.md "Cowork: ENAMETOOLONG' \
			'on encrypted home (eCryptfs)" for the worked steps.'
	fi
}

#
# @brief systemd-coredumpに残った最近のElectronのクラッシュを数えて警告する
# @param $1 Electronバイナリのパス (省略可)
# @note Linuxで最も多い原因はGPUプロセスのFATALで、#583で追跡している
#        影響を受ける環境ではアプリの設定でハードウェアアクセラレーションを切るか
#        画面なしで使い続ける場合はCLAUDE_DISABLE_GPU=1を設定する
#        引数のパスが一致する項目があればその件数だけを数え
#        一致しない場合 (AppImageのマウント先は一時的) はElectron全体の件数を使う
#
_doctor_check_recent_crashes() {
	local electron_path="${1:-}"
	command -v coredumpctl &>/dev/null || return 0

	# coredumpctl list electronはCOMM=electronで絞り込む
	# 引数のパスがEXE列に一致する項目があれば、その件数を優先する
	# 一致しなければElectron全体の件数を使う
	local listing total_count path_count
	listing=$(coredumpctl list electron \
		--since='7 days ago' --no-pager 2>/dev/null) || return 0
	[[ -n $listing ]] || return 0

	# 見出し行を除いて残りの行を数える
	# COMM=electronの絞り込みでは再起動の区切り行が混ざらない前提で数えている
	# パスで絞る側はindex($0, p)で判定するため、この前提が崩れても影響を受けない
	# 将来systemdが区切り行を出すようになったら、この件数の数え方を見直す
	total_count=$(awk 'NR>1 && NF>0' <<< "$listing" | wc -l)
	((total_count == 0)) && return 0

	if [[ -n $electron_path ]]; then
		path_count=$(awk -v p="$electron_path" \
			'NR>1 && index($0, p)' <<< "$listing" | wc -l)
	else
		path_count=0
	fi

	# パスが一致した件数があればそれを使い、なければ全体の件数に注記を添える
	# 注記は、他のElectronアプリ (SlackやVSCodeなど) の分が混ざりうることを伝えるため
	local count footnote=''
	if ((path_count > 0)); then
		count=$path_count
	else
		count=$total_count
		footnote=' (some entries may be from other Electron apps)'
	fi

	# しきい値は#583の再現環境 (7日間で約10回) を基準に決めた
	# 調子の悪い環境でも週に3回程度は超えるため
	# 対処方法を案内する下限を3回としている
	if ((count >= 3)); then
		_warn "Recent Electron crashes: $count in last 7 days$footnote"
		_info \
			'Most common cause: Chromium GPU process FATAL (#583).' \
			'Try one of:'
		_info '  Settings → toggle hardware acceleration off → restart'
		_info '  or set CLAUDE_DISABLE_GPU=1 in the environment'
		_info \
			'Tracking:' \
			'https://github.com/aaddrick/claude-desktop-debian/issues/583'
	elif ((count > 0)); then
		_info "Recent Electron crashes: $count in last 7 days$footnote"
	fi
}

#
# @brief Chromiumが使うパスワードストアの種類を表示する
# @note launcher-common.shの_detect_password_storeを呼び
#        safeStorageとCookieの暗号化にどのキーリングを使うかを示す
#        basicは有効な設定だが、トークンがファイルの権限だけで守られるため
#        その旨を補足する
#        結果が空なら検出自体が失敗しているため
#        値が空のままPASSを出さず警告する
#
_doctor_check_password_store() {
	local store
	store=$(_detect_password_store)
	if [[ -z $store ]]; then
		_warn 'Password store: unable to detect backend'
		return
	fi
	_pass "Password store: $store"
	if [[ $store == 'basic' ]]; then
		_info \
			'  → using fixed-key fallback;' \
			'tokens are protected by filesystem permissions only'
	fi
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		_info \
			"  → overridden by CLAUDE_PASSWORD_STORE=${CLAUDE_PASSWORD_STORE}"
	fi
}

#
# @brief 起動時に使われるトレイアイコンを表示する
#        (claude-desktop-debianの#604から移植)
# @note 表示のみで、判定はしない
#        自動判定はランチャーのsetup_tray_icon_envをそのまま呼び
#        doctorと実際の起動で結果が食い違わないようにする
#        launcher-common.shがない環境 (doctor.batsでの単体読み込み) では
#        declare -Fで関数の有無を確かめてから呼ぶ
#
_doctor_check_tray_icon() {
	if [[ -n ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]; then
		if [[ $CLAUDE_TRAY_USE_DARK_ICON == [01] ]]; then
			_info "Tray icon: CLAUDE_TRAY_USE_DARK_ICON=$CLAUDE_TRAY_USE_DARK_ICON" \
				'(preset; overrides Cinnamon auto-detect)'
		else
			_warn "Tray icon: CLAUDE_TRAY_USE_DARK_ICON=$CLAUDE_TRAY_USE_DARK_ICON" \
				'is not 0/1 — the app ignores it, and it suppresses' \
				'Cinnamon auto-detect'
		fi
		return 0
	fi
	declare -F setup_tray_icon_env > /dev/null || return 0
	setup_tray_icon_env
	if [[ -n ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]; then
		_info 'Tray icon: Cinnamon dark panel auto-detected' \
			'(CLAUDE_TRAY_USE_DARK_ICON=1, TrayIconLinux-Dark.png)'
	else
		_info 'Tray icon: upstream selection (no override)'
	fi
}

#
# @brief セッションのD-Bus上でSecret ServiceかKWalletが使えるかを調べる
# @stdout 見つかったサービス名
# @return 0 = 見つかった、1 = 見つからない、2 = 確認できない
# @note _DOCTOR_SECRET_BACKENDが設定されていれば
#        実際に問い合わせずにその値で結果を決める (テスト用のフック)
#
_secret_backend_reachable() {
	case "${_DOCTOR_SECRET_BACKEND:-}" in
		# テスト用に「見つかった」結果を固定する
		present)
			echo 'org.freedesktop.secrets'
			return 0
			;;
		# テスト用に「見つからない」結果を固定する
		absent)
			return 1
			;;
	esac

	local bus_sock="${XDG_RUNTIME_DIR:-/nonexistent}/bus"
	if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && ! -S $bus_sock ]]; then
		return 2
	fi

	local names=''
	if command -v busctl &>/dev/null; then
		names=$(busctl --user --no-pager --no-legend list \
			2>/dev/null)
	elif command -v gdbus &>/dev/null; then
		local method
		for method in ListNames ListActivatableNames; do
			names+=$(gdbus call --session \
				--dest org.freedesktop.DBus \
				--object-path /org/freedesktop/DBus \
				--method "org.freedesktop.DBus.$method" \
				2>/dev/null)
		done
	else
		return 2
	fi
	[[ -n $names ]] || return 2

	local name
	for name in org.freedesktop.secrets \
		org.kde.kwalletd6 org.kde.kwalletd5; do
		if [[ $names == *"$name"* ]]; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

#
# @brief ログイン情報が暗号化されて保存されるかを確認する
# @note CLAUDE_PASSWORD_STORE=basicを明示すると、トークンは暗号化されずに残る
#        キーリングが使えない場合も、ログインはできるが
#        トークンが平文のbasicバックエンドで保存されることを伝える
#
_doctor_check_keyring_persistence() {
	local forced="${CLAUDE_PASSWORD_STORE:-}"
	if [[ -n $forced && $forced != 'basic' ]]; then
		return 0
	fi
	if [[ $forced == 'basic' ]]; then
		_warn 'Keyring: CLAUDE_PASSWORD_STORE=basic —' \
			'login token stored unencrypted at rest'
		return 0
	fi

	local backend rc
	backend=$(_secret_backend_reachable)
	rc=$?
	case $rc in
		# キーリングに到達できたので、暗号化された保存が使える
		0)
			_pass "Keyring: $backend reachable for" \
				'credential encryption'
			;;
		# キーリングはあるが、必要なサービスがバスに登録されていない
		1)
			_warn 'Keyring: no Secret Service or KWallet' \
				'on the session bus'
			_info 'Login still works, but the token' \
				"persists via Chromium's plaintext" \
				"'basic' backend"
			_info '(unencrypted at rest under' \
				"${XDG_CONFIG_HOME:-$HOME/.config}/Claude)."
			_info 'Fix: install/enable a keyring' \
				'(gnome-keyring or kwalletd), or ignore' \
				'if acceptable for this machine.'
			;;
		# バスを調べる手段がない、またはセッションのバスがない
		*)
			_info 'Keyring: unable to probe the session bus' \
				'(no busctl/gdbus or no session bus)'
			;;
	esac
}

#
# @brief Claudeの設定ディレクトリがあるパーティションの空き容量を確認する
# @param $1 確認する設定ディレクトリ
# @note dfが使えない、または数値が取れない場合は確認を省略してその旨を表示する
#        実行していない確認をPASSとして扱わないため
#
_doctor_check_disk_space() {
	local config_dir="$1"
	local avail
	avail=$(df -BM --output=avail "$config_dir" 2>/dev/null \
		| tail -1 | tr -d ' M') || true
	if [[ ! $avail =~ ^[0-9]+$ ]]; then
		_info 'Disk space: unable to read (df)'
		return 0
	fi
	# 先頭が0の値 ("0099"など) を8進数と解釈させないよう、10進数として計算する
	# 8進数として解釈されると計算に失敗し、PASSの分岐に落ちてしまう
	avail=$((10#$avail))
	if ((avail < 100)); then
		_fail "Disk space: ${avail}MB free on config partition"
		_info 'Fix: Free up disk space'
	elif ((avail < 500)); then
		_warn "Disk space: ${avail}MB free" \
			"on config partition (low)"
	else
		_pass "Disk space: ${avail}MB free"
	fi
}

#
# @brief 実際に導入されているclaude-desktopのバージョンをrpmから調べる (#711)
# @param $1 Electronバイナリのパス (省略可)
# @param $2 パッケージの種類 (rpmまたはappimage、省略時はrpm)
# @note rpm -qfにElectronバイナリのパスを渡すため
#        名前で探すのではなく、そのファイルを導入したパッケージから答えを得られる
#        AppImageはマウント先をどのパッケージも持たないためrpmには問い合わせず
#        同梱のdesktopエントリに書かれたバージョンを表示する
#        rpmがない環境では何も表示しない
#
_doctor_check_pkg_version() {
	local electron_path="${1:-}"
	local package_type="${2:-rpm}"
	local probe_path="$electron_path"
	local pkg_version=''

	if [[ $package_type == 'appimage' ]]; then
		_doctor_check_appimage_version "$electron_path"
		return 0
	fi

	if [[ -z $probe_path ]]; then
		probe_path='/usr/lib/claude-desktop'
		probe_path+='/node_modules/electron/dist/electron'
	fi

	command -v rpm &>/dev/null || return 0
	pkg_version=$(rpm -qf --qf '%{VERSION}-%{RELEASE}' \
		"$probe_path" 2>/dev/null) || pkg_version=''
	if [[ -n $pkg_version ]]; then
		_pass "Installed version: $pkg_version"
		return 0
	fi
	_warn 'claude-desktop not found via rpm (AppImage?)'
}

#
# @brief AppImageのバージョンを、同梱のdesktopエントリから読み取る
# @param $1 Electronバイナリのパス
# @note appimage.shがAppDir直下のdesktopエントリにX-AppImage-Versionとして
#        パッケージのバージョンを書き込む (--versionが表示する値と同じ)
#        AppRunはusr/lib/node_modules/electron/dist/electronのパスをrun_doctorへ渡す
#        そのためそのパスからAppDirの位置を求めて読みに行く
#
_doctor_check_appimage_version() {
	local electron_path="${1:-}"
	local appdir="${electron_path%/usr/lib/node_modules/electron/dist/electron}"
	local entry version=''

	if [[ -n $electron_path && $appdir != "$electron_path" ]]; then
		for entry in "$appdir"/*.desktop; do
			[[ -f $entry ]] || continue
			version=$(grep -m1 -oP '^X-AppImage-Version=\K\S+' \
				"$entry" 2>/dev/null) && break
		done
	fi

	if [[ -z $version ]]; then
		_info 'Installed version: unknown (AppImage desktop entry' \
			'has no X-AppImage-Version)'
		return 0
	fi
	_pass "Installed version: $version (AppImage)"
}

#
# @brief 使用中のディスプレイサーバー (Wayland/X11) と動作モードを表示する
# @note Waylandのときはデスクトップと
#        CLAUDE_USE_WAYLAND=1によるネイティブWaylandか
#        既定のXWayland経由かも示す
#        ネイティブWaylandではクイックウィンドウのグローバルホットキーを
#        XDG GlobalShortcutsポータル経由で登録する (build_electron_args参照)
#        そのためGNOMEとKDEでは初回の許可ダイアログのあと使える
#        GlobalShortcutsを実装しないwlroots系のコンポジタでは使えない
#        DISPLAYもWAYLAND_DISPLAYも未設定の場合 (TTYや壊れたセッション) は失敗にする
#
_doctor_check_display_server() {
	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		_pass "Display server: Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
		local desktop="${XDG_CURRENT_DESKTOP:-unknown}"
		_info "Desktop: $desktop"
		if [[ "${CLAUDE_USE_WAYLAND:-}" == '1' ]]; then
			_info 'Mode: native Wayland (CLAUDE_USE_WAYLAND=1)'
		else
			_info 'Mode: X11 via XWayland (default)'
			_info 'Tip: Set CLAUDE_USE_WAYLAND=1 for native Wayland'
			_info '     (global hotkey via the GlobalShortcuts portal on' \
				'GNOME/KDE; lost on wlroots compositors)'
		fi
	elif [[ -n "${DISPLAY:-}" ]]; then
		_pass "Display server: X11 (DISPLAY=$DISPLAY)"
	else
		_fail "No display server detected" \
			"(DISPLAY and WAYLAND_DISPLAY are unset)"
		_info 'Fix: Run from within an X11 or Wayland session, not a TTY'
	fi
}

#
# @brief 実際に起動するElectronの隣にある、setuid付きのchrome-sandboxを確認する
# @param $1 Electronバイナリのパス (省略時はrpmの導入先)
# @param $2 パッケージの種類 (appimageの場合は確認しない)
# @note AppImageは対象外とする
#        FUSEのマウントではsetuidビットが落ち、所有者も実行ユーザーになるため
#        権限の確認は必ず失敗し、一時的な読み取り専用パスに対して
#        実行できないchownの案内を出すことになる
#        AppImageは代わりにユーザー名前空間のサンドボックスを使う
#        実際に有効かどうかは後続の実行時サンドボックス確認で表示する
#
_doctor_check_chrome_sandbox() {
	local electron_path="${1:-}"
	local package_type="${2:-}"
	local sandbox_path
	if [[ $package_type == 'appimage' ]]; then
		_info 'Chrome sandbox: not used' \
			'(setuid helper unavailable on nosuid FUSE mount)'
		return 0
	fi
	if [[ -n $electron_path ]]; then
		sandbox_path="$(dirname "$electron_path")/chrome-sandbox"
	else
		sandbox_path='/usr/lib/claude-desktop'
		sandbox_path+='/node_modules/electron/dist/chrome-sandbox'
	fi
	if [[ -f $sandbox_path ]]; then
		local sandbox_perms sandbox_owner
		sandbox_perms=$(stat -c '%a' "$sandbox_path" 2>/dev/null) || true
		sandbox_owner=$(stat -c '%U' "$sandbox_path" 2>/dev/null) || true
		if [[ $sandbox_perms == '4755' && $sandbox_owner == 'root' ]]; then
			_pass "Chrome sandbox: permissions OK ($sandbox_path)"
		else
			_fail "Chrome sandbox: perms=${sandbox_perms:-?},\
 owner=${sandbox_owner:-?}"
			_info "Fix: sudo chown root:root $sandbox_path"
			_info "     sudo chmod 4755 $sandbox_path"
		fi
	else
		_warn "Chrome sandbox not found at $sandbox_path"
	fi
}

#
# @brief 実行時にサンドボックスが無効になっているかを判定する
# @param $1 パッケージの種類 (rpmまたはappimage)
# @note setuidヘルパーの権限ではなく、実際に渡される引数で判断する
#        WaylandではCLAUDE_FORCE_SANDBOX=1でない限り
#        rpmのランチャーが--no-sandboxを渡すため
#        上の権限確認がPASSでも起動と同時にサンドボックスは無効になる
#        AppImageはユーザー名前空間が使えない場合を除いて名前空間サンドボックスを保つ
#        そのため引数から求めた同じ答えで両方を扱える
#        引数はbuild_electron_argsで組み立て、判定規則を二重に持たない
#        build_electron_argsがない単体読み込みの場合は何も表示しない
#        is_waylandとuse_x11_on_waylandは事前のdetect_display_backend呼び出しで設定される
#
_doctor_check_effective_sandbox() {
	local package_type="${1:-rpm}"
	declare -F build_electron_args > /dev/null || return 0

	local electron_args
	build_electron_args "$package_type"

	local arg has_no_sandbox=false
	for arg in "${electron_args[@]}"; do
		[[ $arg == '--no-sandbox' ]] && has_no_sandbox=true
	done

	if [[ $package_type == 'appimage' ]]; then
		local reason=''
		declare -F _userns_sandbox_block_reason > /dev/null \
			&& reason=$(_userns_sandbox_block_reason)
		if [[ $has_no_sandbox == true ]]; then
			_warn 'Chrome sandbox: disabled at runtime' \
				"(AppImage: ${reason:-user namespaces unavailable})"
			_info 'The AppImage cannot use the setuid chrome-sandbox'
			_info 'helper (FUSE mounts are nosuid), so Chromium needs'
			_info 'unprivileged user namespaces to sandbox without it.'
			_info 'Fix: run with CLAUDE_FORCE_SANDBOX=1 only if user'
			_info '     namespaces start working on this host.'
		elif [[ -n $reason ]]; then
			_warn 'Chrome sandbox: CLAUDE_FORCE_SANDBOX=1 despite' \
				"blocked user namespaces ($reason)"
			_info 'Chromium may abort on launch (credentials.cc FATAL).'
			_info 'Fix: unset CLAUDE_FORCE_SANDBOX so the launcher can'
			_info '     fall back to --no-sandbox.'
		else
			_pass 'Chrome sandbox: enabled at runtime' \
				'(AppImage user-namespace sandbox)'
		fi
		return 0
	fi

	if [[ $has_no_sandbox == true ]]; then
		_warn 'Chrome sandbox: disabled at runtime (--no-sandbox on Wayland)'
		_info 'Regardless of the file-permission result above, the'
		_info 'sandbox is not engaged for this session.'
		_info 'Fix: set CLAUDE_FORCE_SANDBOX=1 if your system does not'
		_info '     need this workaround.'
	else
		_pass 'Chrome sandbox: enabled at runtime'
	fi
}

#
# @brief SingletonLockの状態から、前回の終了が正常だったかを判断する
# @param $1 設定ディレクトリ (省略時はClaudeの設定ディレクトリ)
# @note ElectronはSingletonLockをホスト名とPIDからなるシンボリックリンクとして作る
#        プロセスが終了しただけの古いリンクはChromiumが自分で片付ける
#        起動を妨げるのはシンボリックリンクではなく通常のファイルになった場合で
#        正常でない更新のあとに起こりうる
#        ロックの解析に失敗し、symlinkの再試行がEEXISTで失敗して
#        次の起動で終了してしまうため、ロックファイルなしと報告してはいけない
#
_doctor_check_singleton_lock() {
	local config_dir="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/Claude}"
	local lock_file="$config_dir/SingletonLock"
	if [[ -L $lock_file ]]; then
		local lock_target lock_pid
		lock_target="$(readlink "$lock_file" 2>/dev/null)" || true
		lock_pid="${lock_target##*-}"
		if [[ $lock_pid =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
			# シグナルを送れるだけではPASSにしない
			# 同じユーザーの別プロセスがPIDを使い回していると
			# 生きている持ち主のように見えてしまうため
			# 持ち主を特定できなくても古いロックとは断定しない
			# Claude Desktopの可能性があり、PIDが使い回されたロックは
			# 次の起動時にChromiumが自分で削除する
			# launcher-common.shがない単体読み込みでは、シグナルの確認だけにとどめる
			if ! declare -F _pid_is_claude_desktop > /dev/null \
				|| _pid_is_claude_desktop "$lock_pid"; then
				_pass "SingletonLock: held by running process" \
					"(PID $lock_pid)"
			else
				_info "SingletonLock: held by PID $lock_pid," \
					'not recognized as Claude Desktop (Electron' \
					'clears it on start if the PID was recycled)'
			fi
		else
			_warn "SingletonLock: stale lock found" \
				"(PID $lock_pid is not running)"
			_info "Fix: rm '$lock_file'"
		fi
	elif [[ -e $lock_file ]]; then
		_warn 'SingletonLock: present but not a symlink (unexpected)'
		_info "Fix: rm '$lock_file'"
	else
		_pass 'SingletonLock: no lock file (OK)'
	fi
}

#
# @brief デバイス登録ファイルを見て、Coworkのクラウドタスクが使える状態かを表示する
# @param $1 設定ディレクトリ
# @note Coworkのクラウドタスクは、remote-toolsのブリッジがこのマシンを証明できるよう
#        ハードウェアに保護されたデバイスキーを必要とする
#        このビルドは@ant/claude-nativeをJSのスタブに置き換えているため
#        Linuxにはそのキーがなく、ant-device-registry.jsonには
#        "none:<ts>"の行だけが並ぶ
#        登録済み機器の"pk1:<fp>:<rowpk>"にはならず
#        "pku1:"はサーバー側の確認がまだ済んでいないキーを表す
#        新しいクラウドタスクが"Not linked to a computer"になる理由がこれである
#        (上流の未対応、Debian #780)
#        ファイルは行の接頭辞を照合するだけで、中身は表示しない (アカウントIDを含むため)
#        書き換えもせず、警告や失敗にもしない
#        ファイルがなければCoworkをまだ使っていないだけなので何も表示しない
#
_doctor_check_device_registry() {
	local registry="$1/ant-device-registry.json"

	[[ -f $registry && -r $registry ]] || return 0

	if grep -q '"pk1:' "$registry" 2>/dev/null; then
		_info 'Device registry: registered (device key present)'
	elif grep -q '"pku1:' "$registry" 2>/dev/null; then
		_info 'Device registry: device key not yet confirmed by the server'
	elif grep -q '"none:' "$registry" 2>/dev/null; then
		_info 'Device registry: not registered — Linux has no' \
			'hardware-backed device key (upstream gap)'
		_info '  New Cowork cloud tasks show "Not linked to a' \
			'computer"; existing on-device sessions are unaffected.'
	fi
	return 0
}

#
# @brief 親を失ったcowork-vm-serviceのデーモンが残っていないかを確認する
# @note 判定には後片付け処理と同じ_cowork_fallback_daemon_pidsを使うため
#        スクリプト名を含むだけのプロセス (エディタやtail -fなど) は対象にならない
#        デーモンを起動できるのは自分たちのUIだけであり
#        同じプロファイルを使う別のClaude Desktopがある間は後片付けも止まる
#        そのため、そのビルドが終了したあとの次の起動で片付けられる
#        launcher-common.shがない単体読み込みでは何も表示しない
#
_doctor_check_cowork_daemon() {
	declare -F _cowork_fallback_daemon_pids > /dev/null || return 0

	local -a pids
	mapfile -t pids < <(_cowork_fallback_daemon_pids)
	[[ ${#pids[@]} -gt 0 ]] || return 0

	if _claude_desktop_own_ui_is_alive; then
		_pass 'Cowork daemon: running (parent alive)'
		return 0
	fi
	_warn 'Cowork daemon: orphaned' "(PIDs: ${pids[*]})"
	if _claude_desktop_any_main_is_alive; then
		_info 'Fix: Quit the other running Claude Desktop' \
			'(the next claude-desktop launch cleans it up)'
		return 0
	fi
	_info 'Fix: Restart Claude Desktop' \
		'(daemon will be cleaned up automatically)'
}

#
# @brief すべての診断を順に実行して結果を表示する
# @param $1 Electronバイナリのパス (省略可、パッケージ固有の確認に使う)
# @param $2 パッケージの種類 (rpmまたはappimage、省略時はrpm)
# @return 失敗した診断の数
#
run_doctor() {
	local electron_path="${1:-}"
	local package_type="${2:-rpm}"
	local _doctor_failures=0

	# 起動時と同じ環境を見るため、利用者ごとの環境設定ファイルを読み込む
	# 下で調べる変数がそこに書かれていることがある
	# launcher-common.shがない単体読み込みでは読み込まない
	declare -F load_launcher_config > /dev/null && load_launcher_config
	_doctor_colors

	# ディストリビューションのIDは入力メソッドの確認 (#550) と
	# 後半のCowork Modeの節の両方で使うため、ここで一度だけ求める
	local _distro_id
	_distro_id=$(_cowork_distro_id)

	echo -e "${_bold}Claude Desktop Diagnostics${_reset}"
	echo '================================'
	echo

	# -- 導入済みパッケージのバージョン --
	_doctor_check_pkg_version "$electron_path" "$package_type"

	# -- ディスプレイサーバー --
	_doctor_check_display_server

	# -- 入力メソッド (IBus / GTK) --
	_doctor_check_im_modules "$_distro_id"

	# -- メニューバーの表示モード --
	local menu_bar_mode="${CLAUDE_MENU_BAR:-}"
	if [[ -n $menu_bar_mode ]]; then
		local resolved_mode="${menu_bar_mode,,}"
		# 1/true/yes/onなどの別名を実際の値に読み替える
		case "$resolved_mode" in
			# 表示する
			1|true|yes|on) resolved_mode='visible' ;;
			# 隠す
			0|false|no|off) resolved_mode='hidden' ;;
		esac
		case "$resolved_mode" in
			# 正しい値はそのまま採用する
			auto|visible|hidden)
				_pass "Menu bar mode: $resolved_mode" \
					"(CLAUDE_MENU_BAR=$menu_bar_mode)"
				;;
			# 解釈できない値は既定のautoで動く
			*)
				_warn "Unknown CLAUDE_MENU_BAR: '$menu_bar_mode'"
				_info 'Will fall back to auto'
				_info 'Valid values: auto, visible, hidden' \
					'(or 0/1/true/false/yes/no/on/off)'
				;;
		esac
	else
		_info 'Menu bar mode: auto (default, Alt toggles visibility)'
	fi

	# -- タイトルバーの表示方法 --
	local titlebar_style="${CLAUDE_TITLEBAR_STYLE:-}"
	if [[ -n $titlebar_style ]]; then
		local resolved_style="${titlebar_style,,}"
		case "$resolved_style" in
			# 枠とアプリ内のトップバーを組み合わせる
			hybrid|native)
				_pass "Titlebar style: $resolved_style" \
					"(CLAUDE_TITLEBAR_STYLE=$titlebar_style)"
				;;
			# 枠を消すとLinuxではトップバーをクリックできなくなる
			hidden)
				_warn "Titlebar style: hidden — topbar clicks unresponsive on Linux (both X11 and Wayland)"
				_info 'Use hybrid (default) or native for clickable buttons'
				;;
			# 解釈できない値は既定のhybridで動く
			*)
				_warn "Unknown CLAUDE_TITLEBAR_STYLE: '$titlebar_style'"
				_info 'Will fall back to hybrid'
				_info 'Valid values: hybrid, native, hidden'
				;;
		esac
	else
		_info 'Titlebar style: hybrid (default, native frame + in-app topbar)'
	fi

	# -- スリープの抑止設定 --
	local keep_awake="${CLAUDE_KEEP_AWAKE:-}"
	if [[ $keep_awake == '0' ]]; then
		_pass 'Keep awake: suppressed (CLAUDE_KEEP_AWAKE=0)'
	elif [[ -n $keep_awake ]]; then
		_info "Keep awake: CLAUDE_KEEP_AWAKE=$keep_awake (default behavior)"
	fi

	# -- Electronバイナリ --
	# バージョンはバイナリの隣のファイルから読む
	# Electronを起動すると固まることがあるため (#371)
	if [[ -n $electron_path && -x $electron_path ]]; then
		local ver
		ver=$(_electron_version "$electron_path")
		if [[ $ver =~ ^v?[0-9]+\.[0-9]+ ]]; then
			_pass "Electron: v${ver#v} ($electron_path)"
		else
			_pass "Electron: found at $electron_path"
		fi
	elif [[ -n $electron_path ]]; then
		_fail "Electron binary not found at $electron_path"
		_info 'Fix: Reinstall claude-desktop package'
	elif command -v electron &>/dev/null; then
		local ver
		ver=$(_electron_version "$(command -v electron)")
		_pass "Electron: ${ver:+v${ver#v} }(system)"
	else
		_fail 'Electron binary not found'
		_info 'Fix: Reinstall claude-desktop package'
	fi

	# -- サンドボックスの権限 --
	_doctor_check_chrome_sandbox "$electron_path" "$package_type"

	# detect_display_backendはis_waylandとuse_x11_on_waylandを設定する
	# 実行時サンドボックス確認のbuild_electron_argsがその値を使う
	declare -F detect_display_backend > /dev/null && detect_display_backend
	_doctor_check_effective_sandbox "$package_type"

	# -- ユーザー名前空間のサンドボックス (Ubuntu 24.04以降のAppArmor) --
	# Ubuntu 24.04以降はapparmor_restrict_unprivileged_userns=1により
	# Chromiumのサンドボックスが必要とするユーザー名前空間が使えず
	# 起動時に終了する (credentials.cc FATAL、終了コード133)
	# Claude専用に絞ったAppArmorプロファイルがあれば許可できる
	# 制限が実際に有効な場合だけ報告する
	# 他のディストリビューションでは設定自体がなく、何も表示しない
	local _userns_path='/proc/sys/kernel/apparmor_restrict_unprivileged_userns'
	local _userns_val=''
	[[ -r $_userns_path ]] && _userns_val=$(<"$_userns_path")
	# 判定にはelectron_path (診断を実行しているビルドのバイナリ) ではなく
	# パッケージが導入したElectronを使う
	# プロファイルは特定のパスだけを許可するため、その導入先だけが対象になる
	# AppImageは名前空間サンドボックスを使い、マウント先を固定できないため
	# 上の実行時サンドボックス確認で報告する
	local _deb_electron='/usr/lib/claude-desktop'
	_deb_electron+='/node_modules/electron/dist/electron'
	if [[ $_userns_val == 1 && -e $_deb_electron ]]; then
		# プロファイル名はdeb.shの/etc/apparmor.d/$package_nameと一致させる
		# (build.shのPACKAGE_NAME)
		local _aa_profile='/etc/apparmor.d/claude-desktop'
		local _aa_loaded='/sys/kernel/security/apparmor/profiles'
		# securityfsはこのファイルを誰でも読める (0444) と示すが
		# 実際の読み取りはCAP_MAC_ADMINがないと拒否される
		# そのため-rの判定は非rootでも通り、読み取り結果は空になる
		# 読み取りを試し、データが得られたかで判断する
		local _loaded_set=''
		_loaded_set=$(cat "$_aa_loaded" 2>/dev/null)
		if [[ -n $_loaded_set ]]; then
			# カーネルが保持するプロファイル一覧を実際に読めた (rootが必要)
			# そのため読み込み状態をそのまま報告する
			# ファイルが存在するかどうかでは判断しない
			if printf '%s\n' "$_loaded_set" | grep -q '^claude-desktop '; then
				_pass 'User namespaces: restricted, AppArmor profile loaded'
			else
				_warn 'User namespaces: restricted by AppArmor,' \
					'Claude profile not loaded'
				if [[ -e $_aa_profile ]]; then
					_info '  Profile is on disk but not loaded. Load it:'
					_info "  sudo apparmor_parser -r $_aa_profile"
				else
					_info '  No profile found. See docs/troubleshooting.md'
					_info '  "Claude Desktop crashes immediately on launch".'
				fi
			fi
		elif [[ -e $_aa_profile ]]; then
			# 一覧を読めなかった場合
			# 非root (0444でもCAP_MAC_ADMINが必要) か
			# securityfsが未マウント (コンテナでよくある) である
			# そのためディスク上の存在だけを報告し、PASSとは断定しない
			if (( EUID == 0 )); then
				_info 'User namespaces: AppArmor profile present on disk' \
					'(securityfs unavailable; cannot confirm it is loaded)'
			else
				_info 'User namespaces: AppArmor profile present on disk' \
					'(re-run with sudo to confirm it is loaded)'
			fi
		else
			_warn 'User namespaces: restricted by AppArmor,' \
				'no Claude profile found'
			_info '  Unprivileged user namespaces are blocked, which'
			_info '  crashes the app on launch in X11 sessions'
			_info '  (credentials.cc FATAL). Wayland sessions run with'
			_info '  --no-sandbox and are unaffected.'
			_info '  See docs/troubleshooting.md "Claude Desktop crashes'
			_info '  immediately on launch" for the profile to install.'
		fi
	fi

	# -- ロックファイル --
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	_doctor_check_singleton_lock "$config_dir"

	# -- パスワードストア --
	_doctor_check_password_store
	_doctor_check_keyring_persistence

	# -- トレイアイコン --
	_doctor_check_tray_icon

	# -- MCPの設定 --
	local mcp_config="$config_dir/claude_desktop_config.json"
	if [[ -f $mcp_config ]]; then
		if command -v python3 &>/dev/null; then
			if python3 -c \
			"import json,sys; json.load(open(sys.argv[1]))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
				# 設定されているMCPサーバーの数も表示する
				local server_count
				server_count=$(python3 -c "
import json,sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
servers = cfg.get('mcpServers', {})
print(len(servers))
" "$mcp_config" 2>/dev/null) || server_count='0'
				_info "MCP servers configured: $server_count"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
				_info "Tip: python3 -m json.tool '$mcp_config' to see the error"
			fi
		elif command -v node &>/dev/null; then
			if node -e \
			"JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
			fi
		else
			_warn "MCP config: exists but cannot validate" \
				"(no python3 or node available)"
		fi
	else
		_info "MCP config: not found at $mcp_config (OK if not using MCP)"
	fi

	# -- Node.js (MCPサーバーが必要とする) --
	if command -v node &>/dev/null; then
		local node_version
		node_version=$(node --version 2>/dev/null) || true
		local node_major="${node_version#v}"
		node_major="${node_major%%.*}"
		if ((node_major >= 20)); then
			_pass "Node.js: $node_version"
		elif ((node_major >= 1)); then
			_warn "Node.js: $node_version (v20+ recommended for MCP servers)"
			_info 'Fix: Update Node.js to v20 or later'
		fi
		_info "Path: $(command -v node)"
	else
		_warn 'Node.js: not found (required for MCP servers)'
		_info 'Fix: Install Node.js v20+ from https://nodejs.org'
	fi

	# -- デスクトップ統合 --
	local desktop_file='/usr/share/applications/claude-desktop.desktop'
	if [[ -f $desktop_file ]]; then
		_pass "Desktop entry: $desktop_file"
	else
		_warn 'Desktop entry not found (expected for AppImage installs)'
	fi

	# -- ディスクの空き容量 --
	_doctor_check_disk_space "$config_dir"

	# -- Cowork Mode --
	echo
	echo -e "${_bold}Cowork Mode${_reset}"
	echo '----------------'

	# bwrapが実際に使われるバックエンドかを求める
	# bwrap関連の診断の深刻度を決めるために使う
	# 自動判定はbwrapを優先するため
	# KVMやhostを明示しない限りbwrapが有効になる
	local _bwrap_active=true
	case "${COWORK_VM_BACKEND,,}" in
		# KVMとhostが明示されたのでbwrapは使われない
		kvm|host) _bwrap_active=false ;;
		# 未設定かbwrapならbwrapが使われる
		''|bwrap) ;;
		*)
			# 解釈できない値でも自動判定ではbwrapが選ばれるため
			# bwrapを有効のままにして深刻度を合わせる (#442)
			_warn_unknown_backend
			;;
	esac

	# Bubblewrap (既定のバックエンド)
	if command -v bwrap &>/dev/null; then
		_pass 'bubblewrap: found'

		# サンドボックスを試す
		# bwrapがサンドボックスを作るにはユーザー名前空間が必要だが
		# Ubuntu 24.04以降はAppArmorが既定で遮断する (#351)
		local _bwrap_probe_err='' _bwrap_probe_rc=0
		_bwrap_probe_err=$(bwrap --ro-bind / / true 2>&1 >/dev/null) \
			|| _bwrap_probe_rc=$?
		if ((_bwrap_probe_rc == 0)); then
			_pass 'bubblewrap: sandbox probe succeeded'
		else
			local _bwrap_issue=_warn
			$_bwrap_active && _bwrap_issue=_fail
			"$_bwrap_issue" \
				"bubblewrap: sandbox probe failed" \
				"(rc=$_bwrap_probe_rc)"
			if [[ -n $_bwrap_probe_err ]]; then
				_info "  stderr: $_bwrap_probe_err"
			fi
			# Ubuntu 24.04のAppArmorによる遮断かを判別し、対処方法を示す
			local _userns_re='(user[[:space:]_-]?namespace|apparmor|[Oo]peration not permitted|CLONE_NEW|CAP_SYS_ADMIN)'
			if [[ $_bwrap_probe_err =~ $_userns_re ]]; then
				_info \
					'  Likely cause: unprivileged user namespaces' \
					'are blocked.'
				_info \
					'  Common on Ubuntu 24.04+ where AppArmor sets' \
					'apparmor_restrict_unprivileged_userns=1'
				_info \
					'  by default. See docs/troubleshooting.md' \
					'"Cowork on Ubuntu 24.04" for the AppArmor profile fix.'
			fi
		fi
	else
		_warn 'bubblewrap: not found'
		_info \
			"Fix: $(_cowork_pkg_hint "$_distro_id" bubblewrap)"
	fi

	# KVMの不足は明示的に選ばれたときだけ警告する
	# 既定はbwrapなので、それ以外では情報として伝える
	local _kvm_active=false
	[[ ${COWORK_VM_BACKEND-} == [Kk][Vv][Mm] ]] && _kvm_active=true
	local _kvm_issue=_info
	$_kvm_active && _kvm_issue=_warn

	# KVMバックエンド (COWORK_VM_BACKEND=kvmで明示的に選ぶ)
	if [[ -e /dev/kvm ]]; then
		if [[ -r /dev/kvm && -w /dev/kvm ]]; then
			_pass 'KVM: accessible'
		else
			"$_kvm_issue" 'KVM: /dev/kvm exists but not accessible'
			if $_kvm_active; then
				_info "Fix: sudo usermod -aG kvm $USER"
				_info '(Log out and back in after running this)'
			fi
		fi
	else
		"$_kvm_issue" 'KVM: not available'
		if $_kvm_active; then
			_info \
				'Fix: Install qemu-kvm and ensure KVM is enabled in BIOS'
		fi
	fi

	# vsockのカーネルモジュール
	if [[ -e /dev/vhost-vsock ]]; then
		_pass 'vsock: module loaded'
	else
		"$_kvm_issue" 'vsock: /dev/vhost-vsock not found'
		if $_kvm_active; then
			_info 'Fix: sudo modprobe vhost_vsock'
		fi
	fi

	# KVMで使うツール (QEMUとsocat)
	# virtiofsdはPATHの外に入る環境があるため、下で別に確認する
	local _tool_label _tool_bin _tool_pkg
	for _tool_label in \
		'QEMU:qemu-system-x86_64:qemu' \
		'socat:socat:socat'
	do
		_tool_bin="${_tool_label#*:}"
		_tool_pkg="${_tool_bin#*:}"
		_tool_bin="${_tool_bin%%:*}"
		_tool_label="${_tool_label%%:*}"

		if command -v "$_tool_bin" &>/dev/null; then
			_pass "$_tool_label: found"
		else
			"$_kvm_issue" "$_tool_label: not found"
			if $_kvm_active; then
				_info \
					"Fix: $(_cowork_pkg_hint "$_distro_id" "$_tool_pkg")"
			fi
		fi
	done

	# virtiofsdはPATHの外に入る環境がある (上の_find_virtiofsd参照)
	# 既知の場所も見て、導入済みなのに未検出と報告しないようにする
	# KvmBackendはPATH上の名前で起動し、失敗すると
	# 性能の低いvirtio-9pへ黙って切り替える
	# そのためKVMが有効でPATHから届かない場合だけ警告し
	# シンボリックリンクを張れば性能が出ることを伝える
	# bwrapが既定の場合はvirtiofsdを使わないため、PASSでよい
	local _vfsd_path _vfsd_on_path
	_vfsd_on_path=$(command -v virtiofsd 2>/dev/null)
	_vfsd_path=$(_find_virtiofsd)
	if [[ -n $_vfsd_path ]]; then
		if [[ $_vfsd_path == "$_vfsd_on_path" ]]; then
			_pass 'virtiofsd: found'
		elif $_kvm_active; then
			_warn "virtiofsd: found at $_vfsd_path but not on PATH"
			_info 'KvmBackend spawns by PATH name and will fall back'
			_info 'to virtio-9p (lower performance) without a symlink.'
			_info "Fix: sudo ln -s $_vfsd_path /usr/local/bin/virtiofsd"
		else
			_pass "virtiofsd: found at $_vfsd_path (not on PATH)"
		fi
	else
		"$_kvm_issue" 'virtiofsd: not found'
		if $_kvm_active; then
			_info "Fix: $(_cowork_pkg_hint "$_distro_id" virtiofsd)"
		fi
	fi

	# VMのディスクイメージ
	local vm_image
	vm_image="${HOME}/.local/share/claude-desktop/vm/rootfs.qcow2"
	if [[ -f $vm_image ]]; then
		local vm_size
		vm_size=$(du -h "$vm_image" 2>/dev/null \
			| cut -f1) || vm_size='unknown size'
		_pass "VM image: $vm_size"
	else
		_info 'VM image: not downloaded yet'
	fi

	# 実際に使われるバックエンドを求める (デーモンのdetectBackend()と同じ判定)
	local cowork_backend='none (host-direct, no isolation)'
	if [[ -n ${COWORK_VM_BACKEND-} ]]; then
		case ${COWORK_VM_BACKEND,,} in
			# 明示されたバックエンドを優先する
			kvm)  cowork_backend='KVM (full VM isolation, via override)' ;;
			bwrap) cowork_backend='bubblewrap (namespace sandbox, via override)' ;;
			host) cowork_backend='host-direct (no isolation, via override)' ;;
			# 解釈できない値は自動判定に任せる
			*)
				_warn_unknown_backend
				cowork_backend="auto-detect (invalid override '${COWORK_VM_BACKEND}' — see warning above)"
				;;
		esac
	elif command -v bwrap &>/dev/null; then
		# bwrapが導入済みなら、試して通ればbwrapを使う
		# 通らなければhostへ落とす (デーモンと同じ挙動)
		# bwrapが遮断されているときにKVMが選ばれると誤解させないため (#351)
		if bwrap --ro-bind / / true &>/dev/null; then
			cowork_backend='bubblewrap (namespace sandbox)'
		else
			cowork_backend='host-direct (bwrap probe failed — see above)'
		fi
	elif [[ -e /dev/kvm ]] \
		&& [[ -r /dev/kvm && -w /dev/kvm ]] \
		&& command -v qemu-system-x86_64 &>/dev/null \
		&& [[ -e /dev/vhost-vsock ]]; then
		cowork_backend='KVM (full VM isolation)'
	fi
	_info "Cowork isolation: $cowork_backend"

	# bwrapの追加マウント設定
	_doctor_check_bwrap_mounts

	# ホストの~/.claudeでNAME_MAXが短い場合 (eCryptfsなど)
	# coworkのセッション開始がENAMETOOLONGで止まる (#590)
	_doctor_check_filename_limit

	_doctor_check_device_registry "$config_dir"

	# -- 取り残されたcoworkのデーモン --
	_doctor_check_cowork_daemon

	# -- 最近のクラッシュ --
	# アプリ内に「Claudeが繰り返しクラッシュしました」と出る前に
	# GPUプロセスのFATALの兆候 (#583) を示す
	_doctor_check_recent_crashes "$electron_path"

	# -- ログファイル --
	local log_path
	log_path="${XDG_CACHE_HOME:-$HOME/.cache}"
	log_path="$log_path/claude-desktop-suse/launcher.log"
	if [[ -f $log_path ]]; then
		local log_size
		log_size=$(stat -c '%s' "$log_path" 2>/dev/null) || log_size=0
		local log_size_kb=$((log_size / 1024))
		if ((log_size_kb > 10240)); then
			_warn "Log file: ${log_size_kb}KB" \
				"(consider clearing: rm '$log_path')"
		else
			_pass "Log file: ${log_size_kb}KB ($log_path)"
		fi
	else
		_info 'Log file: not yet created (OK)'
	fi

	# -- まとめ --
	echo
	if ((_doctor_failures == 0)); then
		echo -e "${_green}${_bold}All checks passed.${_reset}"
	else
		echo -e "${_red}${_bold}${_doctor_failures} check(s) failed.${_reset}"
		echo 'See above for fixes.'
	fi

	return "$_doctor_failures"
}
