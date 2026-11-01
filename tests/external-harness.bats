#!/usr/bin/env bats
# shellcheck disable=SC2034 # 検証対象のランチャーが環境変数として読むため
#
# @file external-harness.bats
# @brief 外部ハーネスの引数検証と、判定を保留する条件のテスト
#
# 成果物の指定が不正なら、何も起動せずに失敗すること
# 画面が無い場合やxprop、xwininfoが使えない場合は、
# 失敗ではなくSKIPとして理由を残すこと
# 記録はJSONL形式で、各レコードが決められた項目を満たすこと
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ
HARNESS="$SCRIPT_DIR/../scripts/external-harness.sh"         # 検証対象の外部ハーネス

#
# @brief 偽のAppImageとその展開先、結果の出力先を一時領域に用意する
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global RESULTS 結果を書き出すJSONLファイル (本関数で設定する)
# @global FAKE_APPIMAGE 偽のAppImage (本関数で設定する)
# @note AppImageは--appimage-extractでfake-appdirを展開し、通常起動では30秒sleepするだけのスタブ
#
setup() {
	TEST_TMP=$(mktemp -d)
	RESULTS="$TEST_TMP/results.jsonl"
	FAKE_APPIMAGE="$TEST_TMP/fake.AppImage"
	mkdir -p "$TEST_TMP/fake-appdir/usr/lib/node_modules/electron/dist/resources"
	mkdir -p "$TEST_TMP/fake-appdir/usr/share/applications"
	mkdir -p "$TEST_TMP/fake-appdir/usr/lib/claude-desktop"
	printf "readonly WM_CLASS='Claude'\n" \
		> "$TEST_TMP/fake-appdir/usr/lib/claude-desktop/launcher-common.sh"
	printf 'fake asar\n' > "$TEST_TMP/fake-appdir/usr/lib/node_modules/electron/dist/resources/app.asar"
	cat > "$TEST_TMP/fake-appdir/io.github.presire.claude-desktop-suse.desktop" <<'EOF'
[Desktop Entry]
Name=Claude
StartupWMClass=io.github.presire.claude-desktop-suse
EOF
	cp "$TEST_TMP/fake-appdir/io.github.presire.claude-desktop-suse.desktop" \
		"$TEST_TMP/fake-appdir/usr/share/applications/"
	cat > "$FAKE_APPIMAGE" <<'EOF'
#!/usr/bin/env bash
set -- "$@"
if [[ ${1:-} == --appimage-extract ]]; then
	source_dir=$(dirname "$0")/fake-appdir
	cp -a "$source_dir" squashfs-root
	exit 0
fi
if [[ ${1:-} == --version ]]; then
	echo 'claude-desktop 0.0.0-test'
	exit 0
fi
sleep 30
EOF
	chmod +x "$FAKE_APPIMAGE"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	rm -rf "$TEST_TMP"
}

@test "rejects missing artifact argument" {
	run "$HARNESS"
	[[ $status -eq 1 ]]
}

@test "rejects more than one artifact target" {
	run "$HARNESS" --artifact "$FAKE_APPIMAGE" --artifact "$FAKE_APPIMAGE"
	[[ $status -eq 1 ]]
}

@test "rejects unsupported artifact extension" {
	touch "$TEST_TMP/fake.txt"
	run "$HARNESS" --artifact "$TEST_TMP/fake.txt" --results "$RESULTS"
	[[ $status -eq 1 ]]
}

@test "emits JSONL schema and explicit no-display skips" {
	unset DISPLAY WAYLAND_DISPLAY
	run "$HARNESS" --artifact "$FAKE_APPIMAGE" --results "$RESULTS"
	[[ $status -eq 1 || $status -eq 77 ]]
	[[ -s $RESULTS ]]
	python3 - "$RESULTS" <<'PY'
import json
import sys

required = {
    "schema_version", "probe_id", "probe", "expected", "actual",
    "exit_code", "status", "skip_reason", "log_path", "timestamp",
    "duration_ms",
}
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert records
for record in records:
    assert required <= record.keys()
    assert record["status"] in {"PASS", "FAIL", "SKIP"}
    if record["status"] == "SKIP":
        assert record["skip_reason"]
assert any(r["probe_id"] == "launch_process" and r["status"] == "SKIP" for r in records)
PY
}

@test "native Wayland window query is an explicit SKIP" {
	DISPLAY=''
	WAYLAND_DISPLAY='wayland-0'
	run env DISPLAY='' WAYLAND_DISPLAY='wayland-0' \
		"$HARNESS" --artifact "$FAKE_APPIMAGE" --results "$RESULTS"
	[[ $status -eq 1 || $status -eq 77 ]]
	python3 - "$RESULTS" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
window = next(r for r in records if r["probe_id"] == "window_reachability")
assert window["status"] == "SKIP"
assert "native Wayland" in window["skip_reason"]
PY
}

@test "missing xprop and xwininfo are explicit SKIPs" {
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/xprop" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
	cat > "$TEST_TMP/bin/xwininfo" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
	chmod +x "$TEST_TMP/bin/xprop" "$TEST_TMP/bin/xwininfo"
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" DISPLAY=':99' WAYLAND_DISPLAY='' \
		"$HARNESS" --artifact "$FAKE_APPIMAGE" --results "$RESULTS"
	[[ $status -eq 1 || $status -eq 77 ]]
	python3 - "$RESULTS" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
window = next(r for r in records if r["probe_id"] == "window_reachability")
assert window["status"] == "SKIP"
assert "xprop" in window["skip_reason"]
PY
}

@test "window owned by an Electron child of the launcher is reachable" {
	cat > "$FAKE_APPIMAGE" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --appimage-extract ]]; then
	cp -a "$(dirname "$0")/fake-appdir" squashfs-root
	exit 0
fi
sleep 30 &
echo "$!" > "$(dirname "$0")/child.pid"
wait
EOF
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/xprop" <<EOF
#!/usr/bin/env bash
case "\$*" in
	-help) exit 0 ;;
	'-root _NET_CLIENT_LIST') echo '_NET_CLIENT_LIST(WINDOW): window id # 0x1' ;;
	'-id 0x1 _NET_WM_PID') echo "_NET_WM_PID(CARDINAL) = \$(<'$TEST_TMP/child.pid')" ;;
	'-id 0x1 _NET_WM_NAME') echo '_NET_WM_NAME(UTF8_STRING) = "Claude"' ;;
	'-id 0x1 WM_CLASS') echo 'WM_CLASS(STRING) = "io.github.presire.claude-desktop-suse", "io.github.presire.claude-desktop-suse"' ;;
	*) exit 1 ;;
esac
EOF
	printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TMP/bin/dbus-send"
	chmod +x "$TEST_TMP/bin/xprop" "$TEST_TMP/bin/dbus-send"
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" DISPLAY=':99' WAYLAND_DISPLAY='' \
		"$HARNESS" --artifact "$FAKE_APPIMAGE" --results "$RESULTS"
	[[ -s $TEST_TMP/child.pid ]]
	python3 - "$RESULTS" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
window = next(r for r in records if r["probe_id"] == "window_reachability")
assert window["status"] == "PASS", window
PY
}

@test "RPM input does not install and reports explicit launch skip" {
	touch "$TEST_TMP/fake.rpm"
	run "$HARNESS" --artifact "$TEST_TMP/fake.rpm" --results "$RESULTS"
	[[ $status -eq 1 || $status -eq 77 ]]
	python3 - "$RESULTS" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
launch = next(r for r in records if r["probe_id"] == "launch_process")
assert launch["status"] == "SKIP"
assert "RPM" in launch["skip_reason"]
PY
}
