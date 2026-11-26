#!/usr/bin/env bats
#
# @file coverage-summary.bats
# @brief tools/coverage-summary.shが計測の状態を取り違えずに表へ出すことのテスト
#
# coverage.ymlは閾値のない情報提供用のワークフローで、全計測ステップがcontinue-on-errorになる
# そのためkcovの導入失敗やスイートの失敗があっても、要約のステップまで進んでしまう
# Debian版はレポートの有無だけを見て%を出し、0行の計測も0.0%と表示していた
# ここでは、セットアップ失敗、部分計測、レポート欠損、破損、0行が数値と区別されて出ることと
# どの入力でも終了コードが0であることを固定する
#

#
# @brief 合成のカバレッジディレクトリと、要約スクリプトのパスを用意する
# @global summary 対象のcoverage-summary.sh (本関数で設定する)
# @global cov 合成のカバレッジディレクトリ (本関数で設定する)
#
setup() {
	summary="$BATS_TEST_DIRNAME/../tools/coverage-summary.sh"
	cov="$BATS_TEST_TMPDIR/coverage"
	mkdir -p "$cov"
}

#
# @brief kcov v43の--mergeが書くcoverage.jsonと同じ形の合成レポートを書く
# @param $1 合計の計測済み行数
# @param $2 合計の行数
# @param $3 2つ目のファイルの計測済み行数 (省略時は$1の半分)
# @param $4 2つ目のファイルの行数 (省略時は$2の半分)
# @note kcovと同じく、合計は2つのファイルの値の和になるように書く
#
write_kcov_json() {
	local covered="$1"
	local total="$2"
	local second_covered="${3:-$(( covered / 2 ))}"
	local second_total="${4:-$(( total / 2 ))}"
	local first_covered=$(( covered - second_covered ))
	local first_total=$(( total - second_total ))
	mkdir -p "$cov/bats/kcov-merged"
	cat > "$cov/bats/kcov-merged/coverage.json" <<-EOF
	{
	  "files": [
	    {"file": "/repo/scripts/a.sh", "percent_covered": "50.00", "covered_lines": "$first_covered", "total_lines": "$first_total"},
	    {"file": "/repo/build.sh", "percent_covered": "25.00", "covered_lines": "$second_covered", "total_lines": "$second_total"}
	  ],
	  "percent_covered": "0.00",
	  "covered_lines": $covered,
	  "total_lines": $total,
	  "percent_low": 25,
	  "percent_high": 75,
	  "command": "",
	  "date": "2026-11-26 00:00:00"
	}
	EOF
}

#
# @brief c8が書くLCOVのレコードを1件出力する
# @param $1 SFのパス
# @param $2 LFの値 (DAの行数)
# @param $3 LHの値 (先頭からこの数のDAを命中にする)
# @stdout LCOVのレコード
#
lcov_record() {
	local i
	printf 'TN:\nSF:%s\n' "$1"
	for (( i = 1; i <= $2; i++ )); do
		printf 'DA:%d,%d\n' "$i" "$(( i <= $3 ? 1 : 0 ))"
	done
	printf 'LF:%s\nLH:%s\nend_of_record\n' "$2" "$3"
}

#
# @brief c8が書くlcov.infoと同じ形の合成レポートを書く
# @param $1 LFの値
# @param $2 LHの値
#
write_lcov() {
	mkdir -p "$cov/c8"
	lcov_record scripts/cowork-vm-service.js "$1" "$2" > "$cov/c8/lcov.info"
}

#
# @brief 全スイートが通ったBATSの状態ファイルを書く
#
write_bats_ok() {
	printf 'setup=ok\nsuites_total=2\nsuite_ok=a.bats\nsuite_ok=b.bats\nloop=done\nmerge=started\nmerge=ok\n' \
		> "$cov/bats-status"
}

#
# @brief 成功したc8の状態ファイルを書く
#
write_c8_ok() {
	printf 'setup=ok\nrun=ok\nexit_code=0\n' > "$cov/c8-status"
}

#
# @brief 要約の表から、指定したスイートの行だけを取り出す
# @param $1 行の先頭のスイート名 (BATSまたはCowork)
# @stdout 該当する表の行
#
row_of() {
	grep -F "| $1 " <<< "$output"
}

@test "complete kcov and c8 reports produce totals and percentages" {
	write_bats_ok
	write_kcov_json 190 1084
	write_c8_ok
	write_lcov 3849 1225

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $output == *'## Line coverage (informational, no threshold)'* ]]
	[[ $(row_of 'BATS') == *'| complete: 2/2 suites passed | 190 | 1084 | 17.5% |' ]]
	[[ $(row_of 'Cowork') == *'| complete | 1225 | 3849 | 31.8% |' ]]
}

@test "the kcov totals come from the merged totals, not the first file entry" {
	write_bats_ok
	write_kcov_json 6 14 1 4
	write_c8_ok
	write_lcov 10 10

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| 6 | 14 | 42.9% |' ]]
	[[ $(row_of 'Cowork') == *'| 10 | 10 | 100.0% |' ]]
}

@test "a missing coverage directory reports both rows as not run" {
	run bash "$summary" "$BATS_TEST_TMPDIR/absent"
	[[ $status -eq 0 ]]
	[[ $output == *'was not created; no step produced output.'* ]]
	[[ $(row_of 'BATS') == *'| not run | n/a | n/a | n/a |' ]]
	[[ $(row_of 'Cowork') == *'| not run | n/a | n/a | n/a |' ]]
	[[ $output != *'0.0%'* ]]
}

@test "a kcov setup failure is shown with its reason instead of a number" {
	printf 'setup=failed\nsetup_reason=kcov v43 not available\n' > "$cov/bats-status"
	printf 'setup=failed\nsetup_reason=c8@10.1.3 could not be fetched\n' > "$cov/c8-status"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| setup failed: kcov v43 not available | n/a | n/a | n/a |' ]]
	[[ $(row_of 'Cowork') == *'| setup failed: c8@10.1.3 could not be fetched | n/a | n/a | n/a |' ]]
}

@test "a stale report without a status file is not trusted" {
	write_kcov_json 190 1084
	write_lcov 3849 1225

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| run status missing: report not trusted | n/a | n/a | n/a |' ]]
	[[ $(row_of 'Cowork') == *'| n/a |' ]]
	[[ $output != *'17.5%'* ]]
	[[ $output != *'31.8%'* ]]
}

@test "failed Bats suites mark the row partial and name each failed suite" {
	printf 'setup=ok\nsuites_total=3\nsuite_ok=a.bats\nfailed_suite=b.bats\nfailed_suite=c.bats\nloop=done\nmerge=started\nmerge=ok\n' \
		> "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| partial: 1/3 suites passed; failed: b.bats, c.bats | 190 | 1084 | 17.5% |' ]]
	[[ $(row_of 'BATS') != *'complete'* ]]
}

@test "a kcov loop that stopped early is reported as interrupted" {
	printf 'setup=ok\nsuites_total=5\nsuite_ok=a.bats\nsuite_ok=b.bats\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| interrupted: 2/5 suites ran | n/a | n/a | n/a |' ]]
}

@test "an interrupted kcov loop still names the suites that failed" {
	printf 'setup=ok\nsuites_total=5\nsuite_ok=a.bats\nfailed_suite=b.bats\n' > "$cov/bats-status"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| interrupted: 2/5 suites ran; failed: b.bats | n/a | n/a | n/a |' ]]
}

@test "a suite recorded twice is not counted as two passing suites" {
	printf 'setup=ok\nsuites_total=2\nsuite_ok=a.bats\nsuite_ok=a.bats\nloop=done\nmerge=started\nmerge=ok\n' \
		> "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| run status inconsistent: suite a.bats recorded twice | n/a | n/a | n/a |' ]]
	[[ $output != *'complete'* ]]
}

@test "a suite total that is not a plain decimal is unreadable" {
	printf 'setup=ok\nsuites_total=08\nloop=done\nmerge=started\nmerge=ok\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| run status unreadable | n/a | n/a | n/a |' ]]
}

@test "a merge result without a recorded start is not trusted" {
	printf 'setup=ok\nsuites_total=1\nsuite_ok=a.bats\nloop=done\nmerge=ok\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| run status inconsistent: merge recorded out of order | n/a | n/a | n/a |' ]]
}

@test "a kcov step that ended before writing its status is interrupted" {
	KCOV_RUN_OUTCOME=failure run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| interrupted: kcov step failure before recording status | n/a | n/a | n/a |' ]]
}

@test "a kcov merge that never finished is interrupted, not failed" {
	printf 'setup=ok\nsuites_total=1\nsuite_ok=a.bats\nloop=done\nmerge=started\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| interrupted: kcov merge did not finish | n/a | n/a | n/a |' ]]
}

@test "suite counts that do not add up are not trusted" {
	printf 'setup=ok\nsuites_total=2\nloop=done\nmerge=started\nmerge=ok\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| run status inconsistent: 0/2 suites recorded | n/a | n/a | n/a |' ]]
	[[ $output != *'complete'* ]]
}

@test "failed suite names survive when the merged report is missing" {
	printf 'setup=ok\nsuites_total=2\nsuite_ok=a.bats\nfailed_suite=b.bats\nloop=done\nmerge=started\nmerge=ok\n' \
		> "$cov/bats-status"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report missing; failed: b.bats | n/a | n/a | n/a |' ]]
}

@test "a failed kcov merge is not reported as coverage" {
	printf 'setup=ok\nsuites_total=1\nsuite_ok=a.bats\nloop=done\nmerge=started\nmerge=failed\n' > "$cov/bats-status"
	write_kcov_json 190 1084

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| kcov merge failed | n/a | n/a | n/a |' ]]
}

@test "a missing merged report after a clean run is reported as missing" {
	write_bats_ok
	write_c8_ok

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report missing | n/a | n/a | n/a |' ]]
	[[ $(row_of 'Cowork') == *'| report missing | n/a | n/a | n/a |' ]]
}

@test "a corrupt coverage.json is reported as corrupt rather than 0%" {
	write_bats_ok
	mkdir -p "$cov/bats/kcov-merged"
	printf '{"files": [\n  {"file": "/repo/a.sh", "covered_lines": "5"' \
		> "$cov/bats/kcov-merged/coverage.json"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report corrupt (coverage.json unreadable) | n/a | n/a | n/a |' ]]
}

@test "kcov totals that disagree with the per-file sums are treated as corrupt" {
	write_bats_ok
	write_kcov_json 190 1084
	sed -i 's/"covered_lines": 190,/"covered_lines": 191,/' "$cov/bats/kcov-merged/coverage.json"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report corrupt (coverage.json unreadable) | n/a | n/a | n/a |' ]]
}

@test "broken JSON with a well-formed tail is treated as corrupt" {
	write_bats_ok
	mkdir -p "$cov/bats/kcov-merged"
	printf '{\n  "files": [\n    {"file": oops},\n  ],\n  "covered_lines": 1,\n  "total_lines": 2,\n  "command": ""\n}\n' \
		> "$cov/bats/kcov-merged/coverage.json"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report corrupt (coverage.json unreadable) | n/a | n/a | n/a |' ]]
}

@test "kcov totals larger than the line count are treated as corrupt" {
	write_bats_ok
	write_kcov_json 20 10

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| report corrupt (coverage.json unreadable) | n/a | n/a | n/a |' ]]
}

@test "a kcov report with zero instrumented lines is not shown as 0%" {
	write_bats_ok
	write_kcov_json 0 0

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'| no lines instrumented (0 lines) |'*'| n/a |' ]]
	[[ $(row_of 'BATS') != *'0.0%'* ]]
}

@test "a failed c8 smoke is not trusted even when lcov.info exists" {
	printf 'setup=ok\nrun=failed\nexit_code=1\n' > "$cov/c8-status"
	write_lcov 3849 1225

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| smoke failed (exit 1): report not trusted | n/a | n/a | n/a |' ]]
	[[ $output != *'31.8%'* ]]
}

@test "a c8 status that contradicts its exit code is not trusted" {
	printf 'setup=ok\nrun=ok\nexit_code=1\n' > "$cov/c8-status"
	write_lcov 3849 1225

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| run status inconsistent: run=ok, exit 1 | n/a | n/a | n/a |' ]]
	[[ $output != *'31.8%'* ]]
}

@test "a c8 status with a repeated run key is not trusted" {
	printf 'setup=ok\nrun=failed\nexit_code=1\nrun=ok\nexit_code=0\n' > "$cov/c8-status"
	write_lcov 3849 1225

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| run status inconsistent: duplicate run | n/a | n/a | n/a |' ]]
	[[ $output != *'31.8%'* ]]
}

@test "a c8 fetch step that timed out before writing its status is a setup failure" {
	C8_SETUP_OUTCOME=cancelled run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| setup failed: c8 fetch step cancelled before recording status | n/a | n/a | n/a |' ]]
}

@test "a c8 run that never reported is shown as interrupted" {
	printf 'setup=ok\n' > "$cov/c8-status"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| interrupted: smoke did not report | n/a | n/a | n/a |' ]]
}

@test "an lcov record with LF:0 is shown as no lines instrumented" {
	write_c8_ok
	write_lcov 0 0

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| no lines instrumented (LF:0) |'*'| n/a |' ]]
	[[ $(row_of 'Cowork') != *'0.0%'* ]]
}

@test "an lcov file without a daemon record is reported as such" {
	write_c8_ok
	mkdir -p "$cov/c8"
	lcov_record scripts/other.js 10 5 > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report has no record for scripts/cowork-vm-service.js | n/a | n/a | n/a |' ]]
}

@test "only the daemon record is counted when lcov.info has other files" {
	write_c8_ok
	mkdir -p "$cov/c8"
	{
		lcov_record scripts/other.js 1000 1000
		lcov_record scripts/cowork-vm-service.js 10 4
	} > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| complete | 4 | 10 | 40.0% |' ]]
}

@test "a same-named file in another directory is not the daemon record" {
	write_c8_ok
	mkdir -p "$cov/c8"
	lcov_record vendor/scripts/cowork-vm-service.js 10 10 > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report has no record for scripts/cowork-vm-service.js | n/a | n/a | n/a |' ]]
}

@test "a duplicated daemon record is corrupt rather than double counted" {
	write_c8_ok
	mkdir -p "$cov/c8"
	{
		lcov_record scripts/cowork-vm-service.js 10 4
		lcov_record scripts/cowork-vm-service.js 10 4
	} > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report corrupt (lcov.info unreadable) | n/a | n/a | n/a |' ]]
}

@test "LF and LH that disagree with the DA lines are reported as corrupt" {
	write_c8_ok
	mkdir -p "$cov/c8"
	printf 'TN:\nSF:scripts/cowork-vm-service.js\nDA:1,0\nLF:1\nLH:1\nend_of_record\n' > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report corrupt (lcov.info unreadable) | n/a | n/a | n/a |' ]]
	[[ $output != *'100.0%'* ]]
}

@test "an lcov record with LH above LF is reported as corrupt" {
	write_c8_ok
	write_lcov 10 11

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report corrupt (lcov.info unreadable) | n/a | n/a | n/a |' ]]
}

@test "a truncated lcov record is reported as corrupt" {
	write_c8_ok
	mkdir -p "$cov/c8"
	printf 'TN:\nSF:scripts/cowork-vm-service.js\nDA:1,1\nLF:1\n' > "$cov/c8/lcov.info"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'Cowork') == *'| report corrupt (lcov.info unreadable) | n/a | n/a | n/a |' ]]
}

@test "status values cannot inject extra table cells" {
	printf 'setup=failed\nsetup_reason=bad | re\rason\n' > "$cov/bats-status"

	run bash "$summary" "$cov"
	[[ $status -eq 0 ]]
	[[ $(row_of 'BATS') == *'setup failed: bad \| re ason | n/a | n/a | n/a |' ]]
	[[ $output != *$'\r'* ]]
}
