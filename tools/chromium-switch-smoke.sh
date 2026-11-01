#!/usr/bin/env bash
#
# @file chromium-switch-smoke.sh
# @brief ランチャーが実際に渡すChromiumスイッチの一覧が変わっていないかを確かめる
#
# ホストの状態に左右されないよう加工したSUSEのランチャーを読み込み、
# 代表的なシナリオでdetect_display_backendとbuild_electron_argsを実行する
# 出力されたスイッチの並びを、リポジトリに置いたbaselineとdiffで比べる
# フラグを足したり消したりした変更は、baselineを意図して作り直すまで失敗する
#
# 使い方 :
#   tools/chromium-switch-smoke.sh           baselineと比較する
#   tools/chromium-switch-smoke.sh --update  baselineを作り直す
# 終了コード : 0 = 一致、または[--update]で作り直した
#              1 = 差分あり、baselineがない、または準備に失敗
#

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1 # claude-desktop-suseのルート
launcher_src="$repo_root/scripts/launcher-common.sh"                # 検証対象のランチャー本体
doctor_src="$repo_root/scripts/doctor.sh"                           # ランチャーが読み込むdoctor
baseline="$repo_root/tools/chromium-switches.baseline"              # 期待するスイッチの並び

tmp_dir=$(mktemp -d) || exit 1 # ホストの設定を触らずに済ませるための作業ディレクトリ
trap 'rm -rf "$tmp_dir"' EXIT

cp "$launcher_src" "$tmp_dir/launcher-common.sh" || exit 1
cp "$doctor_src" "$tmp_dir/doctor.sh" || exit 1
# ランチャーはビルド時に@@WM_CLASS@@を置換する前提なので、検証用の固定値に置き換える
sed -i 's/@@WM_CLASS@@/Claude/' "$tmp_dir/launcher-common.sh"

# 実ユーザーの環境変数でスイッチが変わらないよう、ランチャー向けの設定をすべて消す
for _smoke_var in "${!CLAUDE_@}"; do
	unset "$_smoke_var"
done
unset _smoke_var
# セッション種別を決める変数も消し、DISPLAYなどはシナリオごとに設定し直す
unset XRDP_SESSION XDG_SESSION_ID WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
	XDG_CURRENT_DESKTOP

# shellcheck source=scripts/launcher-common.sh
source "$tmp_dir/launcher-common.sh"

log_file="$tmp_dir/launcher.log" # ランチャーが書き出すログ (シナリオごとに空にする)

# user namespaceの判定を固定値に差し替える
# ホストのカーネル設定でAppImageのスイッチ一覧が変わらないようにするため
# 既定はサンドボックスが起動できる状態にし、あとでAppArmor側だけ塞ぐ
printf '63432\n' > "$tmp_dir/userns-max"
printf '0\n' > "$tmp_dir/userns-aa"
export _CLAUDE_USERNS_MAX="$tmp_dir/userns-max"
export _CLAUDE_USERNS_CLONE="$tmp_dir/userns-clone-absent"
export _CLAUDE_USERNS_AA="$tmp_dir/userns-aa"
export _CLAUDE_UNSHARE=/bin/true

# keyringの判定はセッションのD-Busに依存する
# baselineをホスト非依存に保つため、KDE Plasma 6のホストと同じ応答を返すdbus-sendを置く
mkdir -p "$tmp_dir/bin"
printf '#!/usr/bin/env bash\necho "boolean true"\n' > "$tmp_dir/bin/dbus-send"
chmod +x "$tmp_dir/bin/dbus-send"
export PATH="$tmp_dir/bin:$PATH"

#
# @brief 1つのシナリオを描画し、組み立てられたスイッチを1行にまとめる
# @param $1 シナリオ名 (baselineの行頭に出す)
# @param $2 パッケージ種別 (rpm または appimage)
# @global is_wayland、use_x11_on_wayland、electron_args (初期化してから渡す)
# @global log_file (参照のみ)
# @stdout "<シナリオ名>: <スイッチの並び>"
# @note 状態をグローバルに持つランチャー側の作りに合わせ、
#       呼ぶ前に毎回明示的に初期化する
#
render_scenario() {
	local name="$1"
	local pkg="$2"

	: > "$log_file"
	is_wayland=false
	use_x11_on_wayland=true
	electron_args=()
	detect_display_backend
	build_electron_args "$pkg"
	printf '%s: %s\n' "$name" "${electron_args[*]}"
}

#
# @brief 代表的な5つのシナリオを順に描画し、baselineと同じ形式のテキストを作る
# @stdout baselineに書き込む内容
# @note 各シナリオの前に環境変数を消すのは、
#       前のシナリオの設定が次の結果に混ざらないようにするため
#       user namespaceを塞いだ場合も含め、サンドボックスが使えない状況を再現する
#
generate() {
	unset WAYLAND_DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP \
		CLAUDE_TITLEBAR_STYLE CLAUDE_PASSWORD_STORE CLAUDE_DISABLE_GPU
	DISPLAY=':0'
	render_scenario 'x11-rpm' rpm

	unset DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP \
		CLAUDE_TITLEBAR_STYLE CLAUDE_PASSWORD_STORE CLAUDE_DISABLE_GPU
	WAYLAND_DISPLAY='wayland-0'
	render_scenario 'wayland-xwayland-rpm' rpm

	unset DISPLAY NIRI_SOCKET XDG_CURRENT_DESKTOP \
		CLAUDE_TITLEBAR_STYLE CLAUDE_PASSWORD_STORE CLAUDE_DISABLE_GPU
	WAYLAND_DISPLAY='wayland-0'
	CLAUDE_USE_WAYLAND='1'
	render_scenario 'wayland-native-rpm' rpm

	unset WAYLAND_DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP \
		CLAUDE_TITLEBAR_STYLE CLAUDE_PASSWORD_STORE CLAUDE_DISABLE_GPU
	DISPLAY=':0'
	render_scenario 'x11-appimage' appimage

	# AppArmorでuser namespaceを塞いだ場合のスイッチも固定しておく
	printf '1\n' > "$_CLAUDE_USERNS_AA"
	DISPLAY=':0'
	render_scenario 'x11-appimage-userns-blocked' appimage
	printf '0\n' > "$_CLAUDE_USERNS_AA"
}

output=$(generate)

if [[ ${1:-} == '--update' ]]; then
	printf '%s\n' "$output" > "$baseline" || exit 1
	echo "Baseline updated: $baseline"
	exit 0
fi

if [[ ! -f $baseline ]]; then
	echo "Baseline missing: $baseline" >&2
	echo 'Run with --update to generate it.' >&2
	exit 1
fi

if diff_out=$(diff -u "$baseline" <(printf '%s\n' "$output")); then
	echo 'Chromium switch smoke: OK (switch list matches baseline)'
	exit 0
fi

echo 'Chromium switch smoke: DRIFT DETECTED' >&2
echo >&2
printf '%s\n' "$diff_out" >&2
echo >&2
echo 'The effective Chromium switch list changed.' >&2
echo 'If this change is deliberate, regenerate the baseline:' >&2
echo '    ./tools/chromium-switch-smoke.sh --update' >&2
exit 1
