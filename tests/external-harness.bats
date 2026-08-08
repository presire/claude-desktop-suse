#!/usr/bin/env bats
# shellcheck disable=SC2034  # env vars consumed by the launcher under test

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
HARNESS="$SCRIPT_DIR/../scripts/external-harness.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	RESULTS="$TEST_TMP/results.jsonl"
	FAKE_APPIMAGE="$TEST_TMP/fake.AppImage"
	mkdir -p "$TEST_TMP/fake-appdir/usr/lib/node_modules/electron/dist/resources"
	mkdir -p "$TEST_TMP/fake-appdir/usr/share/applications"
	printf 'fake asar\n' > "$TEST_TMP/fake-appdir/usr/lib/node_modules/electron/dist/resources/app.asar"
	cat > "$TEST_TMP/fake-appdir/io.github.presire.claude-desktop-suse.desktop" <<'EOF'
[Desktop Entry]
Name=Claude
StartupWMClass=Claude
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
