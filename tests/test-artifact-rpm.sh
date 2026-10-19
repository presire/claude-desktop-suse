#!/usr/bin/env bash
# Integration tests for .rpm package artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

if [[ ! -d $artifact_dir || ! -r $artifact_dir ]]; then
	fail "Artifact directory is not readable: $artifact_dir"
	print_summary
fi

# Reap an interrupted launch smoke test, then remove the throwaway
# unprivileged user the launch drops to.
_rpm_cleanup() {
	_launch_smoke_cleanup
	[[ ${smoke_user_created:-false} == true ]] \
		&& userdel -r "$smoke_user" 2>/dev/null
}
trap _rpm_cleanup EXIT INT TERM

# Find the .rpm file
rpm_file=$(find "$artifact_dir" -name '*.rpm' -type f | head -1)
if [[ -z $rpm_file ]]; then
	skip "No .rpm artifact available in $artifact_dir"
	print_summary
	exit 0
fi
pass "Found rpm: $(basename "$rpm_file")"

# --- RPM metadata ---
rpm_info=$(rpm -qip "$rpm_file" 2>/dev/null)

if [[ $rpm_info =~ Name.*claude-desktop ]]; then
	pass "Package name is claude-desktop"
else
	fail "Package name is not claude-desktop"
fi

# --- Payload modes ---
# Checked from the package header, so a umask-dependent build that ships
# group/world-writable files, or drops chrome-sandbox's setuid bit, fails
# here even where the install step below cannot run.
payload_modes=$(rpm -qp --queryformat '[%{FILEMODES:perms} %{FILENAMES}\n]' \
	"$rpm_file" 2>/dev/null)
if [[ -z $payload_modes ]]; then
	fail "Could not read payload file modes from $rpm_file"
else
	writable=$(awk '$1 ~ /^-/ && substr($1, 6, 1) == "w" \
		|| $1 ~ /^-/ && substr($1, 9, 1) == "w"' <<< "$payload_modes")
	if [[ -z $writable ]]; then
		pass "No group/world-writable files in the payload"
	else
		fail "Group/world-writable payload files: $(head -3 <<< "$writable" | tr '\n' ' ')"
	fi
	if grep -Eq '^-rws[r-][w-]x[r-][w-]x .*/electron/dist/chrome-sandbox$' \
		<<< "$payload_modes"; then
		pass "Payload ships chrome-sandbox setuid"
	else
		fail "Payload chrome-sandbox is not setuid"
	fi
fi

# app.asar.unpacked must be world-traversable and root-owned in the
# payload, or Cowork's fs.existsSync() auto-launch guard silently fails
# (#695). %defattr only forces directory modes, so read the header
# directly instead of relying on the install umask.
payload_owners=$(rpm -qp --queryformat \
	'[%{FILEMODES:perms} %{FILEUSERNAME}:%{FILEGROUPNAME} %{FILENAMES}\n]' \
	"$rpm_file" 2>/dev/null)
unpacked_dirs=$(awk '$1 ~ /^d/ && $3 ~ /\/app\.asar\.unpacked(\/|$)/' \
	<<< "$payload_owners")
if [[ -z $unpacked_dirs ]]; then
	fail 'Payload has no app.asar.unpacked directory'
elif awk '$1 != "drwxr-xr-x" || $2 != "root:root" { exit 1 }' \
	<<< "$unpacked_dirs"; then
	pass 'Payload app.asar.unpacked directories are 755 root:root'
else
	fail "Payload app.asar.unpacked modes/owner wrong: $(head -3 <<< "$unpacked_dirs" | tr '\n' ' ')"
fi

# --- Install (--noscripts regression guard) ---
# The spec sets 4755 on the buildroot file in %install, so the payload
# itself carries the setuid mode and any install path that skips
# scriptlets keeps it. --noscripts is the CI proxy for layered/immutable
# images. Run it FIRST, isolated from any state a scripted install could
# leave behind, so the asserted mode can only have come from the payload.
chrome_sandbox='/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'

# This script installs and removes the package, so it must never run on a
# host that already has it: the removal below would delete that install.
if rpm -q claude-desktop &>/dev/null; then
	fail 'claude-desktop is already installed; run on a clean host or container'
	print_summary
fi

noscripts_installed=false
if rpm -ivh --nodeps --noscripts "$rpm_file"; then
	noscripts_installed=true
	pass 'rpm -ivh --noscripts succeeded'
else
	fail 'rpm -ivh --noscripts failed'
fi
if [[ -u $chrome_sandbox ]]; then
	pass "Setuid bit set (noscripts install): $chrome_sandbox"
else
	fail "Setuid bit not set (noscripts install): $chrome_sandbox"
fi

if [[ $noscripts_installed == true ]]; then
	if rpm -e --noscripts claude-desktop; then
		pass 'rpm -e --noscripts succeeded'
	else
		fail 'rpm -e --noscripts failed'
	fi
fi

# --- Install ---
if rpm -ivh --nodeps "$rpm_file"; then
	pass "rpm -ivh succeeded"
else
	fail "rpm -ivh failed"
fi

# --- File existence checks ---
assert_executable '/usr/bin/claude-desktop'
assert_file_exists '/usr/share/applications/claude-desktop.desktop'
assert_dir_exists '/usr/lib/claude-desktop'
assert_file_exists '/usr/lib/claude-desktop/launcher-common.sh'

# Electron binary
electron_path='/usr/lib/claude-desktop/node_modules/electron/dist/electron'
assert_file_exists "$electron_path"
assert_executable "$electron_path"

chrome_sandbox='/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'
assert_file_exists "$chrome_sandbox"
assert_setuid "$chrome_sandbox"

# --- Desktop entry validation ---
desktop_file='/usr/share/applications/claude-desktop.desktop'
assert_contains "$desktop_file" 'Exec=/usr/bin/claude-desktop' \
	"Desktop entry Exec correct"
assert_contains "$desktop_file" 'Type=Application' \
	"Desktop entry Type correct"
assert_contains "$desktop_file" 'Icon=claude-desktop' \
	"Desktop entry Icon correct"
assert_contains "$desktop_file" 'StartupWMClass=Claude' \
	"Desktop entry WM_CLASS correct"

# --- Icons ---
icon_dir='/usr/share/icons/hicolor'
icon_found=false
for size in 16 24 32 48 64 256; do
	if [[ -f "$icon_dir/${size}x${size}/apps/claude-desktop.png" ]]; then
		icon_found=true
	fi
done
if [[ $icon_found == true ]]; then
	pass "At least one icon installed in hicolor"
else
	fail "No icons found in hicolor"
fi

# --- Launcher script content ---
assert_contains '/usr/bin/claude-desktop' 'launcher-common.sh' \
	"Launcher sources launcher-common.sh"
assert_contains '/usr/bin/claude-desktop' 'run_doctor' \
	"Launcher references run_doctor"
assert_contains '/usr/bin/claude-desktop' 'build_electron_args' \
	"Launcher calls build_electron_args"
assert_contains '/usr/bin/claude-desktop' 'run_electron_and_cleanup' \
	"Launcher keeps Electron as a child (run_electron_and_cleanup)"

# rpm only warns when a scriptlet fails, so a syntax error installs
# "successfully". Parse every scriptlet as rpm renders it.
for tag in PREIN POSTIN PREUN POSTUN; do
	body=$(rpm -q --qf "%{$tag}" claude-desktop 2>/dev/null)
	[[ -z $body || $body == '(none)' ]] && continue
	if sh_err=$(sh -n 2>&1 <<< "$body"); then
		pass "%{$tag} scriptlet parses under sh"
	else
		fail "%{$tag} scriptlet has a syntax error: $sh_err"
	fi
done

# --- App contents (asar) ---
resources_dir='/usr/lib/claude-desktop/node_modules/electron/dist/resources'
validate_app_contents "$resources_dir"

# --- Doctor smoke test ---
doctor_exit=0
/usr/bin/claude-desktop --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Launcher --version fast-path ---
# The launcher bakes the RAW build version; rpm splits it into
# %{VERSION}-%{RELEASE}, so match on the %{VERSION} prefix.
run_version_flag_test 'rpm launcher' \
	"claude-desktop $(rpm -qp --queryformat '%{VERSION}' \
		"$rpm_file" 2>/dev/null)" rpm \
	/usr/bin/claude-desktop

# --- Headless launch smoke test ---
# Drop to a throwaway unprivileged user when running as root: Electron
# aborts as root without --no-sandbox. The pkill sweep targets the
# install path — specific enough to avoid user-process collateral.
smoke_user=''
smoke_user_created=false
if [[ $(id -u) -eq 0 ]] && command -v useradd &>/dev/null; then
	smoke_user="claude-smoke-$$"
	if useradd -m "$smoke_user" 2>/dev/null; then
		smoke_user_created=true
	else
		smoke_user=''
	fi
fi

if [[ $(id -u) -eq 0 && -z $smoke_user ]]; then
	skip 'rpm package launch smoke (cannot create unprivileged runner)'
else
	run_launch_smoke_test 'rpm package' "$smoke_user" \
		/usr/bin/claude-desktop
fi

print_summary
