#!/usr/bin/env bash
#
# @file coverage-summary.sh
# @brief Coverageワークフローの計測結果を$GITHUB_STEP_SUMMARY向けのMarkdown表にする
#
# kcovのmerged JSONとc8のLCOVをjqなしで集計する (JSONの検証にはnodeを使う)
# 情報提供用なので閾値はなく、どの入力が欠けても壊れていても終了コードは0
# レポートの有無だけで%を出さず、計測ステップが残すstatusファイルと突き合わせて、
# セットアップ失敗、計測の中断・失敗、一部スイートの失敗、
# レポートの欠損・破損・0行計測を、数値とは別の状態として表に出す
#
# 使い方 : tools/coverage-summary.sh [coverage-dir]   (省略時は coverage)
#
# 入力 (どれも任意。無いものは「未実行」や「欠損」として表示する) :
#   <dir>/bats-status                       kcovステップが書くkey=value
#     setup=ok|failed, setup_reason=..., suites_total=N,
#     suite_ok=<name> / failed_suite=<name> (スイートごとに1行),
#     loop=done, merge=started|ok|failed
#   <dir>/bats/kcov-merged/coverage.json    kcov --mergeの集計
#   <dir>/c8-status                         c8ステップが書くkey=value
#     setup=ok|failed, setup_reason=..., run=ok|failed, exit_code=N
#   <dir>/c8/lcov.info                      c8のLCOV
# 環境変数 (任意) :
#   KCOV_RUN_OUTCOME, C8_SETUP_OUTCOME      kcov/c8ステップのoutcome
#     statusを書く前に期限切れになった時、「未実行」ではなく中断と表示する
# 終了コード : 常に0
#

cov_dir=${1:-coverage} # 計測結果を置いたディレクトリ

bats_status="$cov_dir/bats-status"                   # kcovステップの状態
kcov_json="$cov_dir/bats/kcov-merged/coverage.json"  # kcovの集計結果
c8_status="$cov_dir/c8-status"                       # c8ステップの状態
c8_lcov="$cov_dir/c8/lcov.info"                      # c8のLCOV
c8_target='scripts/cowork-vm-service.js'             # c8で計測する唯一のファイル

# 表のScope列。バッククォートは文字として出す
bats_scope="\`scripts/\`, \`build.sh\`, \`tools/\`"
c8_scope="\`$c8_target\`"

#
# @brief statusファイルから指定したキーの値を全て出力する
# @param $1 statusファイル
# @param $2 キー
# @return 常に0
#
status_values() {
	local file=$1 key=$2 line
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ $line == "$key="* ]] && printf '%s\n' "${line#"$key="}"
	done < "$file"
	return 0
}

#
# @brief statusファイルの記録の矛盾を1つ出力する
# @param $1 statusファイル
# @return 常に0 (矛盾がなければ何も出力しない)
#
# key=value以外の行、キーの重複、空・重複のスイート名を矛盾とする
# 繰り返してよいのはスイートの記録と、merge=startedの後のmerge=ok|failedだけ
#
status_problem() {
	local file=$1 line key value merges=''
	local -A seen=() suites=()
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ -z $line ]] && continue
		key=${line%%=*}
		value=${line#*=}
		if [[ $line != *=* || ! $key =~ ^[a-z_]+$ ]]; then
			printf 'malformed line'
			return 0
		fi
		case $key in
			suite_ok | failed_suite)
				if [[ -z $value ]]; then
					printf 'empty suite name'
					return 0
				fi
				if [[ -n ${suites[$value]:-} ]]; then
					printf 'suite %s recorded twice' "$value"
					return 0
				fi
				suites[$value]=1
				;;
			merge)
				merges+=" $value"
				;;
			*)
				if [[ -n ${seen[$key]:-} ]]; then
					printf 'duplicate %s' "$key"
					return 0
				fi
				seen[$key]=1
				;;
		esac
	done < "$file"
	case $merges in
		'' | ' started' | ' started ok' | ' started failed') ;;
		*) printf 'merge recorded out of order' ;;
	esac
	return 0
}

#
# @brief statusファイルから指定したキーの最後の値を出力する
# @param $1 statusファイル
# @param $2 キー
# @return 常に0
# @note 繰り返すキーはmergeだけで、merge=startedの後に追記した値を採る
#
status_value() {
	local values=()
	mapfile -t values < <(status_values "$1" "$2")
	(( ${#values[@]} > 0 )) && printf '%s' "${values[-1]}"
	return 0
}

#
# @brief Markdownの表のセルを壊す文字を無害化する
# @param $1 セルに入れる文字列
# @return 常に0
#
md_cell() {
	local text=${1//|/\\|}
	text=${text//$'\r'/ }
	text=${text//$'\n'/ }
	printf '%s' "$text"
}

#
# @brief 命中行数と総行数から小数1桁の%を出力する
# @param $1 命中行数
# @param $2 総行数 (1以上)
# @return 常に0
#
percent() {
	local tenths=$(( ($1 * 1000 + $2 / 2) / $2 ))
	printf '%d.%d%%' "$(( tenths / 10 ))" "$(( tenths % 10 ))"
}

#
# @brief kcovのmerged JSONから全体の命中行数と総行数を取り出す
# @param $1 coverage.json
# @return 0 = "covered total"を出力、1 = ファイルなし、2 = 構造が壊れている、
#         4 = nodeがなく検証できない
#
# JSON全体をJSON.parseで読み、ファイルごとの値と全体の値がどれも0以上の整数で、
# 命中行数が総行数を超えず、ファイルごとの合計が全体の値と一致する時だけ信頼する
# (kcov v43の--mergeは全体の値をファイルごとの合計として書く)
#
kcov_totals() {
	local file=$1 rc=0
	[[ -f $file ]] || return 1
	command -v node > /dev/null 2>&1 || return 4
	node -e '
const fs = require("fs");
const count = (value) => {
    if (typeof value !== "number" && !(typeof value === "string" && /^[0-9]+$/.test(value))) return null;
    const n = Number(value);
    return Number.isSafeInteger(n) && n >= 0 ? n : null;
};
let data;
try {
    data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch (e) {
    process.exit(2);
}
if (!data || typeof data !== "object" || !Array.isArray(data.files)) process.exit(2);
let fileCovered = 0;
let fileTotal = 0;
for (const entry of data.files) {
    if (!entry || typeof entry.file !== "string") process.exit(2);
    const covered = count(entry.covered_lines);
    const total = count(entry.total_lines);
    if (covered === null || total === null || covered > total) process.exit(2);
    fileCovered += covered;
    fileTotal += total;
}
const covered = count(data.covered_lines);
const total = count(data.total_lines);
if (covered === null || total === null || covered > total) process.exit(2);
if (covered !== fileCovered || total !== fileTotal) process.exit(2);
process.stdout.write(covered + " " + total + "\n");
' "$file" || rc=$?
	(( rc == 0 )) && return 0
	return 2
}

#
# @brief LCOVから対象ファイルのレコードを1件だけ選び、命中行数と総行数を出力する
# @param $1 lcov.info
# @param $2 対象ファイルのパス (c8が書くリポジトリ相対パスと完全一致させる)
# @return 0 = "hit found"を出力、1 = ファイルなし、2 = 構造が壊れている、
#         3 = 対象ファイルのレコードがない
#
# どのレコードもSFで始まりend_of_recordで閉じ、LFとLHを1つずつ持ち、
# DAの行数がLF、命中したDAの行数がLHと一致することを確かめる
# 対象のレコードが2件以上ある時は壊れているとみなし、対象外のファイルは数えない
#
lcov_totals() {
	local file=$1 target=$2 line value
	local in_record=0 is_target=0 lf='' lh='' da=0 da_hit=0 found=0 hit=0 lines=0
	[[ -f $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		case $line in
			SF:*)
				(( in_record )) && return 2
				in_record=1
				lf=''
				lh=''
				da=0
				da_hit=0
				is_target=0
				[[ ${line#SF:} == "$target" ]] && is_target=1
				;;
			DA:*)
				(( in_record )) || return 2
				[[ $line =~ ^DA:[0-9]+,([0-9]+)(,.*)?$ ]] || return 2
				da=$(( da + 1 ))
				[[ ${BASH_REMATCH[1]} =~ ^0+$ ]] || da_hit=$(( da_hit + 1 ))
				;;
			LF:* | LH:*)
				(( in_record )) || return 2
				value=${line#L?:}
				[[ $value =~ ^[0-9]+$ ]] || return 2
				if [[ $line == LF:* ]]; then
					[[ -z $lf ]] || return 2
					lf=$(( 10#$value ))
				else
					[[ -z $lh ]] || return 2
					lh=$(( 10#$value ))
				fi
				;;
			end_of_record)
				(( in_record )) || return 2
				[[ -n $lf && -n $lh ]] || return 2
				(( lh <= lf && da == lf && da_hit == lh )) || return 2
				if (( is_target )); then
					(( found )) && return 2
					found=1
					hit=$lh
					lines=$lf
				fi
				in_record=0
				;;
		esac
	done < "$file"
	(( in_record )) && return 2
	(( found )) || return 3
	printf '%d %d\n' "$hit" "$lines"
	return 0
}

#
# @brief 表の1行を出力する
# @param $1 Suite  $2 Scope  $3 Status  $4 Lines hit  $5 Lines  $6 Coverage
# @return 常に0
#
row() {
	printf '| %s | %s | %s | %s | %s | %s |\n' "$1" "$2" "$(md_cell "$3")" "$4" "$5" "$6"
}

#
# @brief kcovによるBatsの行を出力する
# @return 常に0
#
bats_row() {
	local suite='BATS (kcov)' setup reason total loop merge totals rc state problem
	local passed=() failed=() hit lines recorded failed_note=''
	setup=$(status_value "$bats_status" setup)
	reason=$(status_value "$bats_status" setup_reason)
	total=$(status_value "$bats_status" suites_total)
	loop=$(status_value "$bats_status" loop)
	merge=$(status_value "$bats_status" merge)
	mapfile -t passed < <(status_values "$bats_status" suite_ok)
	mapfile -t failed < <(status_values "$bats_status" failed_suite)

	if [[ ! -f $bats_status ]]; then
		if [[ -f $kcov_json ]]; then
			row "$suite" "$bats_scope" 'run status missing: report not trusted' n/a n/a n/a
		elif [[ ${KCOV_RUN_OUTCOME:-} == failure || ${KCOV_RUN_OUTCOME:-} == cancelled ]]; then
			row "$suite" "$bats_scope" \
				"interrupted: kcov step $KCOV_RUN_OUTCOME before recording status" n/a n/a n/a
		else
			row "$suite" "$bats_scope" 'not run' n/a n/a n/a
		fi
		return 0
	fi
	problem=$(status_problem "$bats_status")
	if [[ -n $problem ]]; then
		row "$suite" "$bats_scope" "run status inconsistent: $problem" n/a n/a n/a
		return 0
	fi
	if [[ $setup == failed ]]; then
		row "$suite" "$bats_scope" "setup failed: ${reason:-unknown reason}" n/a n/a n/a
		return 0
	fi
	if [[ $setup != ok || ! $total =~ ^(0|[1-9][0-9]*)$ ]]; then
		row "$suite" "$bats_scope" 'run status unreadable' n/a n/a n/a
		return 0
	fi
	recorded=$(( ${#passed[@]} + ${#failed[@]} ))
	if (( ${#failed[@]} > 0 )); then
		local IFS=','
		failed_note="; failed: ${failed[*]}"
		failed_note=${failed_note//,/, }
		unset IFS
	fi
	if (( recorded > total )); then
		row "$suite" "$bats_scope" \
			"run status inconsistent: $recorded/$total suites recorded" n/a n/a n/a
		return 0
	fi
	if [[ $loop != 'done' ]]; then
		row "$suite" "$bats_scope" "interrupted: $recorded/$total suites ran$failed_note" n/a n/a n/a
		return 0
	fi
	if (( total == 0 || recorded != total )); then
		row "$suite" "$bats_scope" \
			"run status inconsistent: $recorded/$total suites recorded" n/a n/a n/a
		return 0
	fi
	case $merge in
		ok) ;;
		'' | started)
			row "$suite" "$bats_scope" "interrupted: kcov merge did not finish$failed_note" n/a n/a n/a
			return 0
			;;
		failed)
			row "$suite" "$bats_scope" "kcov merge failed$failed_note" n/a n/a n/a
			return 0
			;;
		*)
			row "$suite" "$bats_scope" 'run status unreadable' n/a n/a n/a
			return 0
			;;
	esac

	totals=$(kcov_totals "$kcov_json")
	rc=$?
	case $rc in
		0) ;;
		1)
			row "$suite" "$bats_scope" "report missing$failed_note" n/a n/a n/a
			return 0
			;;
		4)
			row "$suite" "$bats_scope" "report not verified (node not found)$failed_note" n/a n/a n/a
			return 0
			;;
		*)
			row "$suite" "$bats_scope" "report corrupt (coverage.json unreadable)$failed_note" n/a n/a n/a
			return 0
			;;
	esac
	read -r hit lines <<< "$totals"
	if (( lines == 0 )); then
		row "$suite" "$bats_scope" "no lines instrumented (0 lines)$failed_note" 0 0 n/a
		return 0
	fi

	if (( ${#failed[@]} == 0 )); then
		state="complete: ${#passed[@]}/$total suites passed"
	else
		state="partial: ${#passed[@]}/$total suites passed$failed_note"
	fi
	row "$suite" "$bats_scope" "$state" "$hit" "$lines" "$(percent "$hit" "$lines")"
	return 0
}

#
# @brief c8によるCoworkデーモンの行を出力する
# @return 常に0
#
c8_row() {
	local suite='Cowork daemon (c8)' setup reason run code totals rc hit lines problem
	setup=$(status_value "$c8_status" setup)
	reason=$(status_value "$c8_status" setup_reason)
	run=$(status_value "$c8_status" run)
	code=$(status_value "$c8_status" exit_code)

	if [[ ! -f $c8_status ]]; then
		if [[ -f $c8_lcov ]]; then
			row "$suite" "$c8_scope" 'run status missing: report not trusted' n/a n/a n/a
		elif [[ ${C8_SETUP_OUTCOME:-} == failure || ${C8_SETUP_OUTCOME:-} == cancelled ]]; then
			row "$suite" "$c8_scope" \
				"setup failed: c8 fetch step $C8_SETUP_OUTCOME before recording status" n/a n/a n/a
		else
			row "$suite" "$c8_scope" 'not run' n/a n/a n/a
		fi
		return 0
	fi
	problem=$(status_problem "$c8_status")
	if [[ -n $problem ]]; then
		row "$suite" "$c8_scope" "run status inconsistent: $problem" n/a n/a n/a
		return 0
	fi
	if [[ $setup == failed ]]; then
		row "$suite" "$c8_scope" "setup failed: ${reason:-unknown reason}" n/a n/a n/a
		return 0
	fi
	if [[ $setup != ok ]]; then
		row "$suite" "$c8_scope" 'run status unreadable' n/a n/a n/a
		return 0
	fi
	case $run in
		ok)
			if [[ $code != 0 ]]; then
				row "$suite" "$c8_scope" "run status inconsistent: run=ok, exit ${code:-unknown}" n/a n/a n/a
				return 0
			fi
			;;
		failed)
			if [[ ! $code =~ ^[1-9][0-9]*$ ]]; then
				row "$suite" "$c8_scope" "run status inconsistent: run=failed, exit ${code:-unknown}" n/a n/a n/a
				return 0
			fi
			row "$suite" "$c8_scope" "smoke failed (exit $code): report not trusted" n/a n/a n/a
			return 0
			;;
		*)
			row "$suite" "$c8_scope" 'interrupted: smoke did not report' n/a n/a n/a
			return 0
			;;
	esac

	totals=$(lcov_totals "$c8_lcov" "$c8_target")
	rc=$?
	case $rc in
		1)
			row "$suite" "$c8_scope" 'report missing' n/a n/a n/a
			return 0
			;;
		2)
			row "$suite" "$c8_scope" 'report corrupt (lcov.info unreadable)' n/a n/a n/a
			return 0
			;;
		3)
			row "$suite" "$c8_scope" "report has no record for $c8_target" n/a n/a n/a
			return 0
			;;
	esac
	read -r hit lines <<< "$totals"
	if (( lines == 0 )); then
		row "$suite" "$c8_scope" 'no lines instrumented (LF:0)' 0 0 n/a
		return 0
	fi
	row "$suite" "$c8_scope" 'complete' "$hit" "$lines" "$(percent "$hit" "$lines")"
	return 0
}

printf '## Line coverage (informational, no threshold)\n\n'
if [[ ! -d $cov_dir ]]; then
	printf "> Coverage directory \`%s\` was not created; no step produced output.\n\n" \
		"$(md_cell "$cov_dir")"
fi
printf '| Suite | Scope | Status | Lines hit | Lines | Coverage |\n'
printf '| --- | --- | --- | ---: | ---: | ---: |\n'
bats_row
c8_row
printf "\n\`n/a\` means there is no trustworthy measurement for that row; it is not 0%%.\n"
printf 'A partial BATS row counts only the suites that ran under kcov, including failed ones.\n'
exit 0
