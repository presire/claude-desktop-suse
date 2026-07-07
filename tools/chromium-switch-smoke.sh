#!/usr/bin/env bash
#
# chromium-switch-smoke.sh — regression guard on the launcher's
# effective Chromium switch list.
#
# Sources a host-state-neutralized copy of the SUSE launcher, runs
# detect_display_backend + build_electron_args for canonical scenarios,
# and diffs the emitted switch list against a checked-in baseline.
# Any drift — a launcher PR that adds/removes a flag — fails loudly
# until the baseline is regenerated deliberately.
#
# Usage:
#   tools/chromium-switch-smoke.sh            compare against baseline
#   tools/chromium-switch-smoke.sh --update   regenerate the baseline

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
launcher_src="$repo_root/scripts/launcher-common.sh"
doctor_src="$repo_root/scripts/doctor.sh"
baseline="$repo_root/tools/chromium-switches.baseline"

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

cp "$launcher_src" "$tmp_dir/launcher-common.sh" || exit 1
cp "$doctor_src" "$tmp_dir/doctor.sh" || exit 1
sed -i 's/@@WM_CLASS@@/Claude/' "$tmp_dir/launcher-common.sh"

for _smoke_var in "${!CLAUDE_@}"; do
	unset "$_smoke_var"
done
unset _smoke_var
unset XRDP_SESSION XDG_SESSION_ID WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
	XDG_CURRENT_DESKTOP

# shellcheck source=scripts/launcher-common.sh
source "$tmp_dir/launcher-common.sh"

log_file="$tmp_dir/launcher.log"

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
