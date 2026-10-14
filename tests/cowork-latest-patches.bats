#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# cowork-latest-patches.bats
#
# Focused fixture for the Claude 1.44121.4 (latest) minified shapes:
# direct (non-optional-chained) platform gates, the positive
# download-driver short-circuit, the wrapped ENOENT/ECONNREFUSED check,
# the native Unix VM manifest, and the imported-call smol-bin copy.
# Every marker in scripts/cowork-patch-markers.tsv (except the two that
# need full bundle structures) must be present after patching.

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
	# 1.44121.4 connects without an identity check, so Patch 3b stays out.
	[[ $output == *'socket check skipped'* ]]

	local name pattern _sample
	while IFS=$'\t' read -r name pattern _sample; do
		[[ -z $name || $name == '#'* ]] && continue
		# These two patches require full bundle structures not represented by
		# this focused fixture; the verified VM connect arrived in 2.37337.1.
		case "$name" in
			asar-adddir-filter | asar-file-drop-guard | vm-service-socket-check)
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

# 2.37337.1 reshaped three anchors: the VM-service error string is now
# composed from a message const (Zk=`${twn}. The service failed to
# start.`), the reinstall list is a dynamic manifest-driven dXr(), and
# VM download staging is bundle-local (.wvm-tmp- + [Bundle:sweep]).
write_237337_cowork_fixture() {
	printf '%s' \
		'let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`) }function Lhn(){let e=process.platform;if(e!=="darwin"&&e!=="win32")return{status:"unsupported",reason:q().formatMessage({defaultMessage:"Cowork is not currently supported on {platform}"})}}async function aU(){return Lz().status==="supported"&&(J.info("[downloadVM] Download already in progress"),work())}async function jFn(){let t=await ugn();if(t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}}async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}var pipe="\\\\.\\pipe\\cowork-vm-service";function gz(e){switch(e){case"linux":return"unix"}}var ewn="ERR_VM_PIPE_CLOSED",twn="VM service not running";var fwn=!1;async function pwn(e,t){let n=Ci()?.connectNamedPipeSystemOwned;if(typeof n!="function"){if(a.app.isPackaged)throw Object.assign(Error("@ant/claude-native is unavailable or does not provide connectNamedPipeSystemOwned; refusing to connect to the cowork VM service pipe without server-identity verification. Reinstall Claude to restore it."),{code:nwn});return fwn||(fwn=!0,Z.warn("[win-vm] claude-native connectNamedPipeSystemOwned unavailable in this dev build; falling back to net.createConnection")),mwn(e,t)}let r;try{r=await n(e,!a.app.isPackaged)}catch(e){throw QCn(e)}return new g.Socket({fd:r,readable:!0,writable:!0})}function mwn(e,t){return new Promise(((n,r)=>{let i=g.createConnection(e);t.onSocketCreated?.(i);i.once("error",r),i.once("connect",(()=>n(i)))}))}var _endConnect=1;var _Tn=5,vTn=20,yTn=1e3,Zk=`${twn}. The service failed to start.`;async function bTn(e,t){let n=await zk();return n}async function xTn(e,t){let n=_Tn;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t||a===n)throw t?Error(Zk):e;await Hm(yTn)}}}throw Error(Zk);var CYr="efivars.fd";function aJ(){return[]}function dXr(){let e=aJ().map((e=>({file:e.name,origin:`.${e.name}.origin`})));return(process.platform==="darwin"||process.platform==="linux")&&e.push({file:CYr}),e}var vYr=".wvm-tmp-",yYr=".partial";function HYr(e,t){return(0,n.join)(e,`${t.name}.zst.${r}${yYr}`)}function WYr(e){return e.startsWith(vYr)}async function nXr(e,t){let r=sJ(),i=e.name,s=(0,n.join)(r,i),c=(0,n.join)(r,`.${i}.origin`),g=HYr(r,e);return g}Z.info("[Bundle:sweep] Startup sweep");let E=!1;E||(E=!0,IT({name:"cowork-vm-shutdown",fn:async()=>{}}));async function start(){let i="bundle",g={};if(J.info(`[VM:start] memory=${memory}GB`),process.platform==="win32"){let e=nU(),t=(0,n.join)(process.resourcesPath,`smol-bin.${e}.vhdx`),r=(0,n.join)(i,QAn);if((0,u.existsSync)(t)){J.info(`[VM:start] Copying smol-bin.${e}.vhdx to bundle: ${t} -> ${r}`);try{await(0,ne.pipeline)((0,u.createReadStream)(t),Kr(r)),J.info(`[VM:start] smol-bin.${e}.vhdx copied successfully`)}catch(e){throw e}}g.configure&&(J.info("[VM:start] Configuring Windows VM service..."),await g.configure(),J.info("[VM:start] Windows VM service configured"))}process.platform==="linux"&&g.configure&&await g.configure()}let api={getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}};' \
		> "$main_js"
}

@test "2.37337.1 shapes: template error string, dynamic list, bundle-local staging" {
	write_237337_cowork_fixture
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 12 cowork patches'* ]]
	[[ $output == *'Patched VM service connect to verify the Unix socket on Linux (fn: pwn)'* ]]
	[[ $output != *'Some patches failed'* ]]
	# None of the three legacy warnings may remain.
	[[ $output != *'Could not find VM service error string'* ]]
	[[ $output != *'Could not find reinstall file list array'* ]]
	[[ $output != *'Could not find mkdtemp'* ]]
	[[ $output == *'Expanded wrapped ENOENT check to include ECONNREFUSED on Linux'* ]]
	[[ $output == *'Added service daemon auto-launch on Linux'* ]]
	[[ $output == *'dynamic manifest shape'* ]]
	[[ $output == *'tmpdir patch not needed'* ]]
	# The spawn-cooldown guard attaches to the reshaped loop function.
	grep -q 'xTn._lastSpawn' "$main_js"
	# The dynamic delete list carries both recovery entries.
	grep -qF '.push({file:"sessiondata.img"})' "$main_js"
	grep -qF '.push({file:"rootfs.img.zst",origin:".rootfs.img.zst.origin"})' "$main_js"

	local name pattern _sample
	while IFS=$'\t' read -r name pattern _sample; do
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

@test "2.37337.1 shapes: patching twice is byte-idempotent" {
	write_237337_cowork_fixture
	patch_cowork_linux >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 0 cowork patches'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

# Patch 3b: 2.37337.1 refuses the VM service connect in a packaged app
# without claude-native's Windows pipe-identity call. Run the patched
# connect against real sockets: only a socket owned by this uid, on a
# canonical path no other user can modify (every ancestor checked, not
# just the parent), may connect; a missing socket must still reject
# with ENOENT so the daemon auto-launch runs, and any other lookup
# failure (ENOTDIR, ELOOP) must reject with the verify code.
@test "2.37337.1 VM connect: Linux socket check gates the plain connect" {
	write_237337_cowork_fixture
	patch_cowork_linux >/dev/null
	[[ $(grep -o '_cdd_vs_fs=require' "$main_js" | wc -l) -eq 1 ]]

	run env MAIN_JS="$main_js" node -e '
		const fs = require("fs");
		const net = require("net");
		const path = require("path");
		const code = fs.readFileSync(process.env.MAIN_JS, "utf8");
		const src = code.slice(code.indexOf("async function pwn("),
			code.indexOf("var _endConnect"));
		const pwn = new Function("a", "g", "Z", "nwn", "fwn", "Ci", "QCn",
			"require", src + ";return pwn")({ app: { isPackaged: true } }, net,
			{ warn() {} }, "ERR_VM_NATIVE_VERIFY_UNAVAILABLE", false,
			() => null, (e) => e, require);
		const attempt = (p) => pwn(p, {}).then(
			(s) => { s.destroy(); return "connected"; }, (e) => e.code);
		const listen = (p) => new Promise((resolve) => {
			const srv = net.createServer((c) => c.end());
			srv.listen(p, () => resolve(srv));
		});
		(async () => {
			const own = path.join(process.env.TEST_TMP, "run");
			fs.mkdirSync(own, { mode: 0o700 });
			const sock = path.join(own, "cowork-vm-service.sock");
			const srv = await listen(sock);
			fs.writeFileSync(path.join(own, "plain"), "");
			fs.symlinkSync(sock, path.join(own, "link.sock"));
			const open = path.join(process.env.TEST_TMP, "open");
			fs.mkdirSync(open);
			fs.chmodSync(open, 0o777);
			const openSock = path.join(open, "s.sock");
			const openSrv = await listen(openSock);
			const shared = path.join(process.env.TEST_TMP, "shared");
			const sharedRun = path.join(shared, "run");
			fs.mkdirSync(sharedRun, { recursive: true, mode: 0o700 });
			fs.chmodSync(shared, 0o777);
			const sharedSock = path.join(sharedRun, "s.sock");
			const sharedSrv = await listen(sharedSock);
			fs.symlinkSync(own, path.join(process.env.TEST_TMP, "alias"));
			fs.symlinkSync("loop", path.join(own, "loop"));
			const out = [
				await attempt(sock),
				await attempt(path.join(own, "missing.sock")),
				await attempt(path.join(own, "plain")),
				await attempt(path.join(own, "link.sock")),
				await attempt(openSock),
				await attempt(sharedSock),
				await attempt(path.join(own, "plain", "s.sock")),
				await attempt(path.join(own, "loop", "s.sock")),
				await attempt(path.join(process.env.TEST_TMP, "alias",
					"cowork-vm-service.sock")),
			];
			fs.chmodSync(open, 0o1777);
			out.push(await attempt(openSock));
			srv.close();
			openSrv.close();
			sharedSrv.close();
			console.log(out.join(","));
		})();
	'
	[[ $status -eq 0 ]]
	local verify=ERR_VM_NATIVE_VERIFY_UNAVAILABLE
	[[ $output == "connected,ENOENT,$verify,$verify,$verify,$verify,$verify,$verify,connected,connected" ]]
}

# Patch 3b anchors must tolerate formatting: spaces inside the getter
# call, the fallback definition, and its createConnection call.
@test "2.37337.1 VM connect: whitespace-formatted connect patches and is idempotent" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}async function pwn ( e , t ) { let n = Ci ( ) ?. connectNamedPipeSystemOwned ; if ( typeof n != "function" ) { if ( a.app.isPackaged ) throw Object.assign ( Error ( "@ant/claude-native is unavailable or does not provide connectNamedPipeSystemOwned; refusing to connect to the cowork VM service pipe without server-identity verification." ) , { code : nwn } ) ; return fwn || ( fwn = !0 , Z.warn ( "dev build" ) ) , mwn ( e , t ) } let r ; try { r = await n ( e , !a.app.isPackaged ) } catch ( e ) { throw QCn ( e ) } return new g.Socket ( { fd : r , readable : !0 , writable : !0 } ) } function mwn ( e , t ) { return new Promise ( ( ( n , r ) => { let i = g.createConnection ( e ) ; t.onSocketCreated?.( i ) ; i.once ( "error" , r ) , i.once ( "connect" , ( ( ) => n ( i ) ) ) } ) ) }' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Patched VM service connect to verify the Unix socket on Linux (fn: pwn)'* ]]
	[[ $(grep -o '_cdd_vs_fs=require' "$main_js" | wc -l) -eq 1 ]]
	grep -qF '{code:nwn})}return mwn(_cdd_vs_sock,t)}' "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'VM service socket check already applied'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	node --check "$main_js"
}

@test "2.37337.1 VM connect: unknown connect shape warns and is left alone" {
	write_237337_cowork_fixture
	sed -i 's/Ci()?\.connectNamedPipeSystemOwned/Ci().connectNamedPipeSystemOwned/' \
		"$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Could not find VM service connect shape (0 candidates)'* ]]
	[[ $(grep -c '_cdd_vs_' "$main_js") -eq 0 ]]
	node --check "$main_js"
}

# Oracle fix 1: the retry loop lost its delay, and an unrelated later
# async function owns a single-arg await. The injection must NOT jump
# to the unrelated function: WARN + file unchanged. The fixture
# pre-applies the Linux support gate so no other sub-patch writes,
# making whole-file equality meaningful.
@test "template path: delay-less loop with later unrelated await warns and writes nothing" {
	printf '%s' \
		'/* vmClient (TypeScript) */let r=Lz();if(process.platform!=="linux"&&r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var twn="VM service not running";var Zk=`${twn}. The service failed to start.`;async function xTn(e,t){let n=5;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t||a===n)throw t?Error(Zk):e;q3()}}throw Error(Zk)}throw Error(Zk);async function unrelated(e,t){await save(e);return e}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'shape not verified'* ]]
	[[ $output != *'Added service daemon auto-launch'* ]]
	[[ $(< "$main_js") != *'cowork-autolaunch'* ]]
	[[ $(< "$main_js") != *'ECONNREFUSED'* ]]
	[[ $(< "$main_js") != *'unrelated._lastSpawn'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

# Oracle fix 2a: an unrelated sessiondata push elsewhere must not mask
# a pristine dXr — both recovery entries are still added there.
@test "dynamic list: unrelated sessiondata push elsewhere does not mask dXr" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}function other(){x.push({file:"sessiondata.img"})}function dXr(){let e=aJ().map((e=>({file:e.name,origin:`.${e.name}.origin`})));return(process.platform==="darwin"||process.platform==="linux")&&e.push({file:CYr}),e}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'dynamic manifest shape'* ]]
	[[ $(grep -o 'push({file:"sessiondata.img"})' "$main_js" | wc -l) -eq 2 ]]
	grep -qF '.push({file:"rootfs.img.zst",origin:".rootfs.img.zst.origin"})' "$main_js"
	node --check "$main_js"
}

# Oracle fix 2b: partial application (only the sessiondata push) adds
# just the missing rootfs entry; rerun is byte-identical.
@test "dynamic list: partial application adds only the missing entry" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}function dXr(){let e=aJ().map((e=>({file:e.name,origin:`.${e.name}.origin`})));return(process.platform==="darwin"||process.platform==="linux")&&e.push({file:CYr}),e.push({file:"sessiondata.img"}),e}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'dynamic manifest shape'* ]]
	[[ $(grep -o 'push({file:"sessiondata.img"})' "$main_js" | wc -l) -eq 1 ]]
	grep -qF '.push({file:"rootfs.img.zst",origin:".rootfs.img.zst.origin"})' "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'already includes VM images'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	node --check "$main_js"
}

# Oracle fix 3: markers plus an imported-call tmpdir mkdtemp must NOT
# be reported as not-needed — the legacy path handles it instead.
@test "tmpdir: markers plus imported-call tmpdir mkdtemp is patched, not dismissed" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var vYr=".wvm-tmp-",yYr=".partial";function HYr(e,t){return(0,n.join)(e,`${t.name}.zst.${r}${yYr}`)}function WYr(e){return e.startsWith(vYr)}Z.info("[Bundle:sweep] Startup sweep");async function dl(){await fs.mkdir(bundle,{recursive:true});return await(0,fs.mkdtemp)(path.join(os.tmpdir(),"wvm-"))}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output != *'not needed'* ]]
	[[ $output == *'Patched VM download temp dir to use bundle path on Linux'* ]]
	grep -qF '(process.platform==="linux"?bundle:os.tmpdir())' "$main_js"
	node --check "$main_js"
}

# Oracle fix 4: whitespace/newline-formatted variants of the new
# anchors still patch, and the second run is byte-identical.
@test "template path: whitespace-formatted variant patches and is idempotent" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var twn = "VM service not running";var Zk = `${twn}. The service failed to start.`;async function xTn( e , t ) {let n = 5;for( let a = 0 ; a <= n ; a ++ ){try{return await bTn( e , t )}catch( e ){let t = ( e instanceof Error && "code" in e ? e.code : void 0 ) === "ENOENT" || !1;if( !t || a === n )throw t ? Error( Zk ) : e;await Hm ( yTn )}}}throw Error( Zk );function dXr( ) {let e = aJ( ) . map( ( e => ( { file : e . name , origin : `.${ e.name }.origin` } ) ) ) ;return ( process.platform === "darwin" || process.platform === "linux" ) && e . push( { file : CYr } ) , e}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Expanded wrapped ENOENT check to include ECONNREFUSED on Linux'* ]]
	[[ $output == *'Added service daemon auto-launch on Linux'* ]]
	[[ $output == *'dynamic manifest shape'* ]]
	grep -q 'xTn._lastSpawn' "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	node --check "$main_js"
}

# Oracle re-review A1: the retry loop (the only function throwing the
# template const) lost its ENOENT check, and a later function owns its
# own ENOENT/for/delay/Error shape. Patch 6 must not adopt the later
# function — candidates have to reference the template const.
@test "template path: later ENOENT function that does not throw the template is not adopted" {
	printf '%s' \
		'/* vmClient (TypeScript) */let r=Lz();if(process.platform!=="linux"&&r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var twn="VM service not running";var Zk=`${twn}. The service failed to start.`;async function xTn(e,t){let n=5;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){if(a===n)throw Error(Zk);await Hm(yTn)}}}async function other(e,t){for(let a=0;a<3;a++){try{return await f(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t)throw Error("other");await Hm(yTn)}}}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Could not locate VM retry function'* ]]
	[[ $output != *'Added service daemon auto-launch'* ]]
	[[ $(< "$main_js") != *'other._lastSpawn'* ]]
	[[ $(< "$main_js") != *'cowork-autolaunch'* ]]
}

# Oracle re-review A2: two functions throw the template with an ENOENT
# check — ambiguous, so nothing is injected.
@test "template path: two template-throwing ENOENT functions warn and write nothing" {
	printf '%s' \
		'/* vmClient (TypeScript) */let r=Lz();if(process.platform!=="linux"&&r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var twn="VM service not running";var Zk=`${twn}. The service failed to start.`;async function xTn(e,t){let n=5;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t||a===n)throw t?Error(Zk):e;await Hm(yTn)}}}async function yTx(e,t){let n=5;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t||a===n)throw t?Error(Zk):e;await Hm(yTn)}}}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'2 functions throw the service-error template'* ]]
	[[ $output != *'Added service daemon auto-launch'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

# Oracle re-review B: the staging markers are present, but the download
# site's staging dir comes from an imported-call tmpdir() outside the
# anchor windows. That is not bundle-local: no "not needed" INFO.
@test "tmpdir: staging dir from imported-call tmpdir() is not reported bundle-local" {
	# Pad past the ±1500-char anchor windows so only the call-site
	# origin check can catch the tmpdir().
	local pad
	pad=$(printf '%2000s' '')
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}var vYr=".wvm-tmp-",yYr=".partial";function HYr(e,t){let r=t.checksum.slice(0,12);return(0,n.join)(e,`${t.name}.zst.${r}${yYr}`)}function WYr(e){return e.startsWith(vYr)}Z.info("[Bundle:sweep] Startup sweep");/*'"$pad"'*/async function nXr(e,t){let r=(0,os.tmpdir)(),i=e.name,s=(0,n.join)(r,i),c=(0,n.join)(r,`.${i}.origin`),g=HYr(r,e);return g}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output != *'tmpdir patch not needed'* ]]
	[[ $output == *'Could not find mkdtemp'* ]]
}

# Oracle re-review D: a bundle variable containing `$` survives the
# imported-call rewrite verbatim (a replacement string would turn `$$`
# into `$`).
@test "tmpdir: imported-call rewrite keeps a \$-bearing bundle variable verbatim" {
	printf '%s' \
		'async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`)}async function dl(){await fs.mkdir(b$$,{recursive:true});return await(0,fs.mkdtemp)(path.join(os.tmpdir(),"wvm-"))}' \
		> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Patched VM download temp dir to use bundle path on Linux'* ]]
	grep -qF '(process.platform==="linux"?b$$:os.tmpdir())' "$main_js"
	node --check "$main_js"
}
