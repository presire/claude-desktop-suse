#!/usr/bin/env bash

# L2-only external harness for one SUSE RPM or AppImage artifact.
# No Electron internals, inspector, CDP, DevTools, or remote debugging.

readonly schema_version=1
readonly run_base='/tmp/opencode'
artifact=''
artifact_count=0
artifact_type=''
results_file=''
run_root=''
log_dir=''
retained_log_dir=''
launcher=''
desktop_entry=''
resources_dir=''
wm_class=''
rpm_installed=false
app_pid=''
app_pgid=''
pass_count=0
fail_count=0
skip_count=0

json_escape() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}
	printf '%s' "$value"
}

now_ms() {
	local nanoseconds
	nanoseconds=$(date +%s%N)
	printf '%d' $((nanoseconds / 1000000))
}

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
	case "$status" in
		PASS) ((pass_count++)) ;;
		FAIL) ((fail_count++)) ;;
		SKIP) ((skip_count++)) ;;
	esac
}

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

skip_probe() {
	local probe_id="$1" probe="$2" expected="$3" reason="$4"
	local log_path="$log_dir/$probe_id.log"
	printf '%s\n' "$reason" > "$log_path"
	record "$probe_id" "$probe" "$expected" "$reason" 77 SKIP "$reason" \
		"$log_path" 0
}

usage() {
	printf 'Usage: %s --artifact PATH [--results PATH]\n' "$0" >&2
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--artifact)
				[[ $# -ge 2 ]] || { usage; return 1; }
				artifact="$2"
				((artifact_count++))
				shift 2
				;;
			--results)
				[[ $# -ge 2 ]] || { usage; return 1; }
				results_file="$2"
				shift 2
				;;
			--help|-h)
				usage
				return 2
				;;
			*)
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

extract_rpm() {
	mkdir -p "$run_root/extract"
	if ! command -v rpm2cpio >/dev/null 2>&1 || ! command -v cpio >/dev/null 2>&1; then
		return 1
	fi
	(rpm2cpio "$artifact" | (cd "$run_root/extract" && cpio -idm --quiet)) \
		> "$log_dir/rpm-extract.log" 2>&1
}

extract_appimage() {
	mkdir -p "$run_root/extract"
	(cd "$run_root/extract" && "$artifact" --appimage-extract) \
		> "$log_dir/appimage-extract.log" 2>&1
}

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
}

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

skip_l2() {
	skip_probe launch_process launch_process 'normal launcher reaches process state' "$1"
	skip_probe process_log_state process_log_state 'launcher log/process state is observable' "$1"
	skip_probe window_reachability window_reachability 'X11/XWayland window is reachable with xprop' "$1"
	skip_probe window_title window_title 'X11/XWayland title is readable with xprop' "$1"
	skip_probe tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' "$1"
}

find_window() {
	local window_id pid_line title_line class_line
	local client_list
	client_list=$(xprop -root _NET_CLIENT_LIST 2>/dev/null) || return 1
	while read -r window_id; do
		[[ -n $window_id ]] || continue
		pid_line=$(xprop -id "$window_id" _NET_WM_PID 2>/dev/null) || continue
		[[ $pid_line =~ =[[:space:]]*"$app_pid"$ ]] || continue
		title_line=$(xprop -id "$window_id" _NET_WM_NAME 2>/dev/null) || true
		class_line=$(xprop -id "$window_id" WM_CLASS 2>/dev/null) || true
		[[ $class_line == *"\"$wm_class\""* ]] || continue
		[[ -n $title_line ]] || continue
		printf '%s\n%s\n%s\n' "$window_id" "$title_line" "$class_line"
		return 0
	done < <(printf '%s\n' "$client_list" | tr ',' ' ' | grep -oE '0x[0-9a-fA-F]+')
	return 1
}

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
	if command -v pgrep >/dev/null 2>&1 && pgrep -u "$(id -u)" -f -- \
		"--class=$wm_class( |$)" >/dev/null 2>&1; then
		skip_l2 'an existing Claude process owns the requested WM_CLASS; refusing to interfere'
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
	sleep 2
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
	if window_data=$(find_window); then
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
			if grep -q "StatusNotifierItem-$app_pid-" "$log_dir/tray.log"; then
				record tray_sni tray_sni 'optional StatusNotifierItem is queryable with dbus-send' \
					"StatusNotifierItem-$app_pid- is registered" 0 PASS '' "$log_dir/tray.log" 0
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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
	exit $?
fi
