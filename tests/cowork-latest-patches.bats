#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COWORK_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"
MARKERS_TSV="$SCRIPT_DIR/../scripts/cowork-patch-markers.tsv"

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

write_latest_cowork_fixture() {
	printf '%s' \
		'let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`) }function Lhn(){let e=process.platform;if(e!=="darwin"&&e!=="win32")return{status:"unsupported",reason:q().formatMessage({defaultMessage:"Cowork is not currently supported on {platform}"})}}async function aU(){return Lz().status==="supported"&&(J.info("[downloadVM] Download already in progress"),work())}async function jFn(){let t=await ugn();if(t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}}async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}var pipe="\\\\.\\pipe\\cowork-vm-service";function gz(e){switch(e){case"linux":return"unix"}}async function sUt(a,b){for(let n=0;n<2;n++)try{return await rpc()}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t)throw Error("VM service not running. The service failed to start.");await MS(delay)}}let E=!1;E||(E=!0,IT({name:"cowork-vm-shutdown",fn:async()=>{}}));async function start(){let i="bundle",g={};if(J.info(`[VM:start] memory=${memory}GB`),process.platform==="win32"){let e=nU(),t=(0,n.join)(process.resourcesPath,`smol-bin.${e}.vhdx`),r=(0,n.join)(i,QAn);if((0,u.existsSync)(t)){J.info(`[VM:start] Copying smol-bin.${e}.vhdx to bundle: ${t} -> ${r}`);try{await(0,ne.pipeline)((0,u.createReadStream)(t),Kr(r)),J.info(`[VM:start] smol-bin.${e}.vhdx copied successfully`)}catch(e){throw e}}g.configure&&(J.info("[VM:start] Configuring Windows VM service..."),await g.configure(),J.info("[VM:start] Windows VM service configured"))}process.platform==="linux"&&g.configure&&await g.configure()}let api={getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}};' \
		> "$main_js"
}

@test "latest cowork: direct gates and wrapped socket error are patched" {
	write_latest_cowork_fixture
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 10 cowork patches'* ]]
	[[ $output != *'Some patches failed'* ]]

	local name pattern sample
	while IFS=$'\t' read -r name pattern sample; do
		[[ -z $name || $name == '#'* ]] && continue
		# These two patches require full bundle structures not represented by
		# this focused fixture.
		case "$name" in
			asar-adddir-filter | asar-file-drop-guard)
				continue
				;;
		esac
		grep -qP -- "$pattern" "$main_js" || {
			echo "missing marker: $name"
			return 1
		}
	done < "$MARKERS_TSV"
	node --check "$main_js"
}

@test "latest cowork: patching twice is byte-idempotent" {
	write_latest_cowork_fixture
	patch_cowork_linux >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_cowork_linux >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}
