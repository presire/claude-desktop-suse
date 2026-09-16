#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# warm-download-blocked.bats
#
# Focused coverage for the warm prefetch (autoDownloadInBackground) Linux
# gate emitted by Patch 1c-B. Upstream ships three shapes of the support
# check that precedes the warm download log:
#
#   legacy      if(!X||X.status!=="supported"){await Y([]);return}
#   1.21459.0   if(!X||X.status!=="supported"){<null-safe reason>...}
#   1.44121.4   if(X.status!=="supported"){<log>}
#
# All three must be widened to a Linux short-circuit, the patch must be
# byte-idempotent, and an absent anchor must fail closed (WARNING, no
# patch) rather than corrupt the bundle.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COWORK_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"

# Post-patch invariant, i.e. the warm-download-blocked-linux marker.
WARM_MARKER='if\(process\.platform==="linux"\|\|(?:![\w$]+\|\|)?[\w$]+\.status!=="supported"\)\{'

# Direct form used by 1.44121.4 (no null guard on the status read).
DIRECT_WARM='let t=await ugn();if(t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}'

# Null-safe form used by 1.21459.0, mirroring the real bytes including the
# reason interpolation that follows the status check.
NULLSAFE_WARM='let t;try{const{yukonSilver:n}=await S6();if(!n||n.status!=="supported"){const l=(n==null?void 0:n.status)==="unsupported"?n.reason:String((n==null?void 0:n.status)??"unknown");w.info(`[warm] Skipping VM warm download - YukonSilver not supported (${l})`);return}}catch(e){}'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$COWORK_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Writes the shared multi-anchor cowork fixture with the warm prefetch body
# replaced by $1. Every other patch still resolves, so the applied count is
# comparable across cases.
write_warm_fixture() {
	local warm_body="$1"
	{
		printf '%s' \
			'let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`) }function Lhn(){let e=process.platform;if(e!=="darwin"&&e!=="win32")return{status:"unsupported",reason:q().formatMessage({defaultMessage:"Cowork is not currently supported on {platform}"})}}async function aU(){return Lz().status==="supported"&&(J.info("[downloadVM] Download already in progress"),work())}async function jFn(){'
		printf '%s' "$warm_body"
		printf '%s' \
			'}async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}var pipe="\\\\.\\pipe\\cowork-vm-service";function gz(e){switch(e){case"linux":return"unix"}}async function sUt(a,b){for(let n=0;n<2;n++)try{return await rpc()}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t)throw Error("VM service not running. The service failed to start.");await MS(delay)}}let E=!1;E||(E=!0,IT({name:"cowork-vm-shutdown",fn:async()=>{}}));async function start(){let i="bundle",g={};if(J.info(`[VM:start] memory=${memory}GB`),process.platform==="win32"){let e=nU(),t=(0,n.join)(process.resourcesPath,`smol-bin.${e}.vhdx`),r=(0,n.join)(i,QAn);if((0,u.existsSync)(t)){J.info(`[VM:start] Copying smol-bin.${e}.vhdx to bundle: ${t} -> ${r}`);try{await(0,ne.pipeline)((0,u.createReadStream)(t),Kr(r)),J.info(`[VM:start] smol-bin.${e}.vhdx copied successfully`)}catch(e){throw e}}g.configure&&(J.info("[VM:start] Configuring Windows VM service..."),await g.configure(),J.info("[VM:start] Windows VM service configured"))}process.platform==="linux"&&g.configure&&await g.configure()}let api={getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}};'
	} > "$main_js"
}

sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

@test "warm gate: null-safe 1.21459.0 shape is widened to a Linux short-circuit" {
	write_warm_fixture "$NULLSAFE_WARM"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 10 cowork patches'* ]]
	[[ $output != *'VM-download block partial'* ]]

	grep -qP -- "$WARM_MARKER" "$main_js"
	grep -qF -- \
		'if(process.platform==="linux"||!n||n.status!=="supported"){' \
		"$main_js"
	node --check "$main_js"
}

@test "warm gate: direct 1.44121.4 shape is widened to a Linux short-circuit" {
	write_warm_fixture "$DIRECT_WARM"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 10 cowork patches'* ]]
	[[ $output != *'VM-download block partial'* ]]

	grep -qP -- "$WARM_MARKER" "$main_js"
	grep -qF -- \
		'if(process.platform==="linux"||t.status!=="supported"){' \
		"$main_js"
	node --check "$main_js"
}

@test "warm gate: legacy null-safe shape with await/return body is widened" {
	write_warm_fixture \
		'let t=await ugn();if(!t||t.status!=="supported"){await ugn();J.info("[warm] Skipping VM warm download");return}'
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 10 cowork patches'* ]]

	grep -qP -- "$WARM_MARKER" "$main_js"
	grep -qF -- \
		'if(process.platform==="linux"||!t||t.status!=="supported"){' \
		"$main_js"
	node --check "$main_js"
}

@test "warm gate: only the check nearest the warm log is widened" {
	local pad
	pad=$(printf 'p%.0s' $(seq 1 300))
	write_warm_fixture \
		"if(zzz.status!==\"supported\"){J.info(\"decoy\")}var pad=\"$pad\";let t=await ugn();if(t.status!==\"supported\"){J.info(\"[warm] Skipping VM warm download\");return}"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 10 cowork patches'* ]]

	# The far-away decoy keeps its original, unwidened form.
	grep -qF -- 'if(zzz.status!=="supported"){' "$main_js"
	# The check adjacent to the warm log is widened.
	grep -qF -- \
		'if(process.platform==="linux"||t.status!=="supported"){' \
		"$main_js"
	node --check "$main_js"
}

@test "warm gate: an already widened bundle is not patched twice" {
	write_warm_fixture \
		'let t=await ugn();if(process.platform==="linux"||t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}'
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Warm-download Linux block already applied'* ]]
	[[ $output != *'VM-download block partial'* ]]

	grep -qP -- "$WARM_MARKER" "$main_js"
	node --check "$main_js"
}

@test "warm gate: an already widened null-safe bundle is not patched twice" {
	write_warm_fixture \
		'let t=await ugn();if(process.platform==="linux"||!t||t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}'
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Warm-download Linux block already applied'* ]]
	[[ $output != *'VM-download block partial'* ]]

	grep -qP -- "$WARM_MARKER" "$main_js"
	node --check "$main_js"
}

@test "warm gate: patching twice is byte-idempotent" {
	write_warm_fixture "$NULLSAFE_WARM"
	patch_cowork_linux >/dev/null
	local before after
	before=$(sha_of "$main_js")
	patch_cowork_linux >/dev/null
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "warm gate: an absent anchor fails closed with a WARNING" {
	write_warm_fixture \
		'let t=await ugn();J.info("no warm gate in this bundle");'
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'VM-download block partial'* ]]
	[[ $output == *'warm=false'* ]]

	# The bundle stays valid JS and no Linux short-circuit is invented.
	node --check "$main_js"
	if grep -qP -- "$WARM_MARKER" "$main_js"; then
		echo 'unexpected Linux short-circuit in a bundle with no anchor'
		return 1
	fi
}
