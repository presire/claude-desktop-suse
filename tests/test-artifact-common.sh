#!/usr/bin/env bash
# Shared helpers for artifact validation tests

_pass_count=0
_fail_count=0
_skip_count=0

pass() {
	printf '[PASS] %s\n' "$*"
	((_pass_count++))
}

fail() {
	printf '[FAIL] %s\n' "$*" >&2
	((_fail_count++))
}

skip() {
	printf '[SKIP] %s\n' "$*"
	((_skip_count++))
	return 0
}

assert_file_exists() {
	if [[ -f $1 ]]; then
		pass "File exists: $1"
	else
		fail "File missing: $1"
	fi
}

assert_dir_exists() {
	if [[ -d $1 ]]; then
		pass "Directory exists: $1"
	else
		fail "Directory missing: $1"
	fi
}

assert_executable() {
	if [[ -x $1 ]]; then
		pass "Executable: $1"
	else
		fail "Not executable: $1"
	fi
}

assert_setuid() {
	if [[ -u $1 ]]; then
		pass "Setuid bit set: $1"
	else
		fail "Setuid bit not set: $1"
	fi
}

assert_contains() {
	local file="$1" pattern="$2" desc="${3:-}"
	if grep -q "$pattern" "$file" 2>/dev/null; then
		pass "${desc:-"$file contains '$pattern'"}"
	else
		fail "${desc:-"$file does not contain '$pattern'"}"
	fi
}

assert_command_succeeds() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit code: $?)"
	fi
}

# Validate app contents inside an Electron resources directory.
# $1 = path to the resources/ dir containing app.asar
validate_app_contents() {
	local resources_dir="$1"

	assert_file_exists "$resources_dir/app.asar"
	assert_dir_exists "$resources_dir/app.asar.unpacked"

	# Check unpacked contents (always available, no asar tool needed)
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js"
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/cowork-vm-service.js"

	# Extract app.asar for deeper inspection if tools available
	local extract_dir
	extract_dir=$(mktemp -d)

	local extracted=false
	if command -v asar &>/dev/null; then
		asar extract "$resources_dir/app.asar" "$extract_dir/app" \
			&& extracted=true
	elif command -v npx &>/dev/null; then
		npx --yes @electron/asar extract \
			"$resources_dir/app.asar" "$extract_dir/app" 2>/dev/null \
			&& extracted=true
	fi

	if [[ $extracted == true ]]; then
		# frame-fix files present
		assert_file_exists "$extract_dir/app/frame-fix-wrapper.js"
		assert_file_exists "$extract_dir/app/frame-fix-menu.js"
		assert_file_exists "$extract_dir/app/frame-fix-entry.js"

		# package.json main points to frame-fix-entry.js
		assert_contains "$extract_dir/app/package.json" \
			'frame-fix-entry.js' \
			"package.json main field references frame-fix-entry.js"

		# .vite/build/index.js exists (main process code)
		assert_file_exists "$extract_dir/app/.vite/build/index.js"

		# claude-native stub exists inside asar
		assert_file_exists \
			"$extract_dir/app/node_modules/@ant/claude-native/index.js"

		# cowork-vm-service.js exists inside asar
		assert_file_exists "$extract_dir/app/cowork-vm-service.js"

		# frame-fix-entry.js loads the wrapper
		assert_contains "$extract_dir/app/frame-fix-entry.js" \
			'frame-fix-wrapper' \
			"frame-fix-entry.js loads wrapper"

		# Tray icons present in resources
		local tray_count
		tray_count=$(find "$extract_dir/app/resources/" \
			-name 'Tray*' 2>/dev/null | wc -l)
		if [[ $tray_count -gt 0 ]]; then
			pass "Tray icons present ($tray_count files)"
		else
			fail "No tray icons found in app resources"
		fi
	else
		pass "Skipping asar extraction (tool not available)"
	fi

	rm -rf "$extract_dir"
}

# Assert the launcher's --version fast-path: it must print
# "<package_name> <version>" and exit 0. The fast-path exits before
# any launch, log-redirect, or sandbox logic, so it needs no display,
# D-Bus, or privilege handling.
#
# Usage: run_version_flag_test <label> <expected> <policy> <cmd> [args...]
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

# Module-scope state so the caller's trap can reap an interrupted launch.
_smoke_launch_pid=''
_smoke_group_pid=''
_smoke_cache_root=''
_smoke_xvfb_log=''

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

# True when a log file carries the sandbox-namespace-denied signature:
# the container forbidding Chromium's user/PID namespace sandbox.
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

# Headless launch smoke test. Boots the packaged app under Xvfb + dbus
# and waits for the launcher's 'Executing:' log line (written
# immediately before exec'ing Electron), then requires the process
# group to survive a grace window.
#
# SUSE adaptation: isolates HOME plus all four XDG roots
# (CONFIG/CACHE/DATA/STATE) to a per-run temp root, and uses the
# claude-desktop-suse launcher-log namespace.
#
# Usage:
#   run_launch_smoke_test <label> <run_as> <cmd> [args...]
#     run_as       unprivileged user to drop to, or '' to run as-is.
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
		runner+=(runuser -u "$run_as" -- setsid bash -c
			'printf "%s\\n" "$$" > "$1"; shift; exec "$@"'
			smoke-runner "$pgid_file")
	fi
	# All four XDG roots + HOME are isolated under cache_root so the
	# test owns the launcher log and no real user state is touched.
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

	local readiness_marker='Executing: '
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

print_summary() {
	echo
	echo '================================'
	printf 'Results: %d passed, %d failed\n' "$_pass_count" "$_fail_count"
	printf 'Skipped: %d\n' "$_skip_count"
	echo '================================'
	if [[ $_fail_count -gt 0 ]]; then
		exit 1
	fi
}
