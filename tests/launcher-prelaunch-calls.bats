#!/usr/bin/env bats
#
# launcher-prelaunch-calls.bats
# The generated launchers still call the pre-launch hygiene helpers.
#
# Every helper is unit-tested against its definition in
# scripts/launcher-common.sh, but nothing else asserts that a launcher
# calls it. Deleting the block from scripts/packaging/{rpm,appimage}.sh
# would leave the rest of the suite green. `backup_user_config` matters
# most: losing its call is silent until a user needs a backup that was
# never taken.
#
# This is the cheap static tier. It reads the packaging scripts, not a
# built package, so it pins that the launcher *source* makes the calls
# in the right region, not that the shipped launcher runs them against
# real stale state.
#
# The search scope is the two packaging scripts on purpose:
# `cleanup_after_electron_exit` in scripts/launcher-common.sh re-runs
# several of these names *after* Electron exits, so a repo-wide grep is
# satisfied without any launcher calling anything.
#
# awk splits each script on its heredoc boundaries. A parser that
# silently matched nothing would pass every assertion below, so the
# first test asserts the parse's own shape.
#
# Ported from claude-desktop-debian; the SUSE call list keeps
# `cleanup_stale_cowork_socket` (the SUSE daemon still binds that
# socket) and has no portal entry or VM bundle helpers.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PACKAGING_DIR="${SCRIPT_DIR}/../scripts/packaging"

readonly PACKAGING_SCRIPTS=(
	rpm.sh
	appimage.sh
)

# The pre-launch block, in the order the launchers run it. One array for
# both formats on purpose: a call added to one launcher and missed in the
# other reds here.
readonly PRELAUNCH_CALLS=(
	cleanup_replaced_desktop_ui
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
	heal_autostart_entry
	backup_user_config
)

# External programs a launcher may run in command position. Only the RPM
# launcher's "Electron is missing" dialogs today; add new ones on purpose.
readonly ALLOWED_EXTERNAL=(
	zenity
	kdialog
)

# The launcher heredoc body of packaging script <1>, as `<lineno>:<text>`
# rows (grep -n's own shape, so `cut -d: -f1` reads the number back).
#
# Keyed on a column-0 `cat > … << EOF` opener and its bare `EOF`
# terminator, then narrowed to the single region containing the
# launcher's `setup_logging` call. rpm's `<< SPECEOF` is not an opener
# here and its terminator is not `^EOF$`, so it never splices a region.
launcher_heredoc() {
	awk -v q="'" '
		!inhd && $0 ~ ("^cat > .*<<[[:space:]]*" q "?EOF" q \
			"?[[:space:]]*$") {
			inhd = 1
			body = ""
			next
		}
		inhd && /^EOF[[:space:]]*$/ {
			inhd = 0
			if (body ~ /setup_logging/) printf "%s", body
			next
		}
		inhd { body = body NR ":" $0 "\n" }
	' "${PACKAGING_DIR}/$1"
}

# The `<lineno>:<text>` rows on stdin that are a call to <1>: the name at
# column 0 of the launcher line, followed by end-of-line or whitespace.
# Emits the line numbers. Comment rows are dropped first so a commented
# call never counts even if the anchor is relaxed later.
call_lines() {
	grep -vE '^[0-9]+:[[:space:]]*#' \
		| grep -E "^[0-9]+:$1([[:space:]]|\$)" \
		| cut -d: -f1
}

# The launcher heredoc of <1> with comment rows dropped and the line
# numbers stripped, for assertions that match a whole source line.
uncommented_launcher() {
	launcher_heredoc "$1" | grep -vE '^[0-9]+:[[:space:]]*#' \
		| cut -d: -f2- || true
}

# Count of column-0, uncommented calls to <2> anywhere in script <1>,
# heredoc or not.
file_calls() {
	grep -vE '^[[:space:]]*#' "${PACKAGING_DIR}/$1" \
		| grep -cE "^$2([[:space:]]|\$)" || true
}

# The `heal_autostart_entry` argument each format must carry, verbatim as
# the packaging script spells it. The RPM heredoc is unquoted, so
# `$install_prefix`/`$package_name` expand at build time; the AppImage
# heredoc is quoted, so `${APPIMAGE:-}` stays literal for the runtime.
heal_call() {
	case "$1" in
	rpm.sh)
		printf '%s' \
			"heal_autostart_entry '/usr/bin/\$package_name'"
		;;
	appimage.sh)
		# shellcheck disable=SC2016  # literal AppRun text, expanded at runtime
		printf '%s' 'heal_autostart_entry "${APPIMAGE:-}"'
		;;
	*)
		return 1
		;;
	esac
}

@test "the launcher-heredoc parser sees the expected shape" {
	local script body rows
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		[[ -s "${PACKAGING_DIR}/${script}" ]]

		body=$(launcher_heredoc "$script")
		[[ -n "$body" ]]

		rows=$(grep -c '' <<<"$body")
		[[ "$rows" -ge 30 ]]

		# Exactly one launcher region was kept, carrying both
		# ordering landmarks.
		[[ $(grep -cE '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body") -eq 1 ]]
		[[ $(grep -cE '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body") -eq 1 ]]

		# The region stops at its own EOF instead of bleeding into
		# the .desktop heredoc that follows it.
		[[ "$body" != *'[Desktop Entry]'* ]]
	done
}

@test "the call anchor rejects comments, prefixes and prose mentions" {
	local fixture hits
	fixture=$(cat <<-'FIXTURE'
		10:# cleanup_stale_lock
		11:  # cleanup_stale_lock
		12:cleanup_stale_lock_extra
		13:log_message 'ran cleanup_stale_lock'
		14:  cleanup_stale_lock
		15:cleanup_stale_lock
		16:# heal_autostart_entry "${APPIMAGE:-}"
		17:heal_autostart_entry "${APPIMAGE:-}"
	FIXTURE
	)

	hits=$(call_lines cleanup_stale_lock <<<"$fixture")
	[[ "$hits" == '15' ]]

	hits=$(call_lines heal_autostart_entry <<<"$fixture")
	[[ "$hits" == '17' ]]
}

@test "every pre-launch call appears exactly once in every launcher" {
	local script body call count offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			count=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			[[ "$count" -eq 1 ]] && continue
			offenders+="${script}: ${call}:"
			offenders+=" ${count} call site(s), want 1"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call missing or duplicated:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "pre-launch calls run in order after setup_logging, before Electron" {
	# A cleanup that runs after Electron is not a pre-launch cleanup,
	# and log_message needs setup_logging to have run first.
	local script body start end call line prev offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		start=$(grep -E '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body" | head -1 | cut -d: -f1)
		end=$(grep -E '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body" | head -1 | cut -d: -f1)

		[[ -n "$start" && -n "$end" ]] || {
			offenders+="${script}: no setup_logging/exec landmark"
			offenders+=$'\n'
			continue
		}

		prev=$start
		for call in "${PRELAUNCH_CALLS[@]}"; do
			line=$(call_lines "$call" <<<"$body" | head -1)
			[[ -n "$line" ]] || {
				offenders+="${script}: ${call}: no call site"$'\n'
				continue
			}
			if [[ "$line" -gt "$prev" && "$line" -lt "$end" ]]; then
				prev=$line
				continue
			fi
			offenders+="${script}: ${call}: line ${line} not in"
			offenders+=" (${prev}, ${end})"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call out of order or window:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "no pre-launch call site sits outside the launcher heredoc" {
	# A call written next to the `cat >` in the packaging script's own
	# body would run at build time instead of at launch.
	local script body call inside in_file offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			inside=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			in_file=$(file_calls "$script" "$call")
			[[ "$inside" -eq "$in_file" ]] && continue
			offenders+="${script}: ${call}: ${in_file} in file,"
			offenders+=" ${inside} in the launcher"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call outside the launcher heredoc:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "each launcher carries only its own heal_autostart_entry argument" {
	local script other body want foreign offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script")
		want=$(heal_call "$script")

		[[ $(grep -cFx -- "$want" <<<"$body" || true) -eq 1 ]] || {
			offenders+="${script}: want exactly one: ${want}"$'\n'
		}

		for other in "${PACKAGING_SCRIPTS[@]}"; do
			foreign=$(heal_call "$other")
			[[ "$foreign" == "$want" ]] && continue
			grep -qFx -- "$foreign" <<<"$body" || continue
			offenders+="${script}: carries ${other}'s argument:"
			offenders+=" ${foreign}"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'wrong heal_autostart_entry argument:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "ensure_portal_app_id_entry follows detect_display_backend with the asar desktopName" {
	# The alias is only written on native Wayland, which needs the
	# backend decision first, and the id must match package.json
	# desktopName from app-asar.sh or the portal still rejects it.
	local script body detect ensure end call want offenders=''
	local asar_sh="${PACKAGING_DIR}/../patches/app-asar.sh"
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		detect=$(call_lines detect_display_backend <<<"$body")
		ensure=$(call_lines ensure_portal_app_id_entry <<<"$body")
		end=$(grep -E '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body" | cut -d: -f1)

		if [[ $(grep -c . <<<"$ensure") -ne 1 ||
			$(grep -c . <<<"$detect") -ne 1 ]]; then
			offenders+="${script}: want one detect and one ensure call"
			offenders+=$'\n'
			continue
		fi
		[[ $ensure -gt $detect && $ensure -lt $end ]] || {
			offenders+="${script}: ensure at ${ensure}, detect at"
			offenders+=" ${detect}, Electron at ${end}"$'\n'
		}

		call=$(uncommented_launcher "$script" \
			| sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' \
			| grep -E '^ensure_portal_app_id_entry ')
		case "$script" in
		rpm.sh) want="claude-desktop.desktop" ;;
		appimage.sh) want="io.github.presire.claude-desktop-suse.desktop" ;;
		esac
		grep -qF "'${want}'" "$asar_sh" || {
			offenders+="app-asar.sh: no desktopName ${want}"$'\n'
		}
		[[ $call == *" '${want%.desktop}' "* ]] || {
			offenders+="${script}: app id is not ${want%.desktop}:"
			offenders+=" ${call}"$'\n'
		}
	done

	[[ -z "$offenders" ]] || {
		printf 'portal app-id entry call is wrong:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "both launchers hand Electron to run_electron_and_cleanup, not exec" {
	# A bare exec replaces the launcher, so the output filter and the
	# post-exit Cowork/helper cleanup never run.
	local script body offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script")
		grep -qE '^[[:space:]]*exec[[:space:]]' <<<"$body" || continue
		offenders+="${script}: launcher still execs"$'\n'
	done

	[[ -z "$offenders" ]] || {
		printf '%s' "$offenders" >&2
		false
	}
}

# The words in command position in the launcher heredoc of <1>, one per
# line. A command position is the start of a line, or what follows `;`,
# `&&`, `||`, `|`, a standalone `{`, `!` or one of the keywords `if`,
# `elif`, `then`, `else`, `while`, `until` and `do`.
#
# Backslash-continued lines are joined first, so an option on a
# continuation line is never read as a command. Quoted strings,
# `[[ … ]]` tests and `${…}` expansions are dropped next, so a word
# inside them is never read as a command either.
command_words() {
	uncommented_launcher "$1" \
		| sed -E -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' \
		| sed -E -e "s/'[^']*'//g" -e 's/"[^"]*"//g' \
			-e 's/\[\[[^]]*\]\]//g' -e 's/\$\{[^}]*\}//g' \
		| sed -E -e 's/(;|&&|\|\||\||!)/\n/g' \
			-e 's/\<case[[:space:]]+([^[:space:]]+[[:space:]]+)?in\>/\n/g' \
			-e 's/(^|[[:space:]])\{([[:space:]]|$)/\n/g' \
			-e 's/\<(if|elif|then|else|while|until|do)\>/\n/g' \
		| awk '{ w = 1; if ($1 ~ /\)$/) w = 2 } NF >= w { print $w }'
}

@test "every launcher command is a builtin or a launcher-common function" {
	# A helper deleted or renamed in launcher-common.sh while a launcher
	# still calls it does not fail bash: it prints "command not found"
	# into the log and carries on.
	local common="${SCRIPT_DIR}/../scripts/launcher-common.sh"
	local -A shell_words=() provided=()
	local word script checked=0 offenders=''
	while read -r word; do
		shell_words[$word]=1
	done < <(compgen -k; compgen -b)
	for word in "${ALLOWED_EXTERNAL[@]}"; do
		shell_words[$word]=1
	done
	# shellcheck disable=SC2016  # the inner shell expands $1
	while read -r _ _ word; do
		provided[$word]=1
	done < <(env -i HOME="$HOME" PATH="$PATH" \
		bash --noprofile --norc -c \
		'source "$1" >/dev/null 2>&1; declare -F' _ "$common")
	((${#provided[@]} > 0)) || {
		printf 'sourcing %s defined no functions\n' "$common" >&2
		false
	}

	for script in "${PACKAGING_SCRIPTS[@]}"; do
		while read -r word; do
			[[ $word =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]] && continue
			[[ -n ${shell_words[$word]:-} ]] && continue
			checked=$((checked + 1))
			[[ -n ${provided[$word]:-} ]] && continue
			offenders+="${script}: ${word}"$'\n'
		done < <(command_words "$script")
	done

	((checked >= ${#PRELAUNCH_CALLS[@]} * ${#PACKAGING_SCRIPTS[@]})) || {
		printf 'checked only %d commands\n' "$checked" >&2
		false
	}
	[[ -z "$offenders" ]] || {
		printf '%s %s\n%s' 'not a shell builtin or keyword,' \
			'and not a function launcher-common.sh provides:' \
			"$offenders" >&2
		false
	}
}
