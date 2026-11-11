#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file cowork-latest-patches.bats
# @brief Claude 1.44121.4系のminify済み形状を対象にした、焦点を絞ったテスト用固定データ
#
# 対象は、省略可能チェーンを使わない直接のプラットフォーム判定、
# ダウンロード処理の短絡、ENOENTとECONNREFUSEDを包んだ判定、
# Unix向けネイティブVMのマニフェスト、imported-call形式のsmol-binコピーである
# パッチ適用後は、scripts/cowork-patch-markers.tsvにあるマーカーが、
# 完全なバンドル構造を必要とする2件を除いてすべて揃っていなければならない
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"           # このテストファイルがあるディレクトリ
COWORK_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"                    # 検証対象のcowork向けパッチ
MARKERS_TSV="$SCRIPT_DIR/../scripts/cowork-patch-markers.tsv"           # 適用後に確認するマーカー一覧

#
# @brief テスト用の一時ディレクトリとパッチ対象のindex.jsを用意し、cowork.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメインプロセス側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$COWORK_SH"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
# @note setupが途中で失敗してTEST_TMPが未定義でも失敗しないよう、存在を確認してから削除する
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief 1.44121.4系のminify済み形状を持つindex.jsを書き出す
# @global TEST_TMP 書き出し先の一時ディレクトリ (参照のみ)
# @global main_js 書き出すindex.jsのパス (参照のみ)
# @note パッチのアンカーになる文字列を1つのファイルにまとめ、焦点を絞った固定データにしている
#
write_latest_cowork_fixture() {
	printf '%s' \
		'let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`) }function Lhn(){let e=process.platform;if(e!=="darwin"&&e!=="win32")return{status:"unsupported",reason:q().formatMessage({defaultMessage:"Cowork is not currently supported on {platform}"})}}async function aU(){return Lz().status==="supported"&&(J.info("[downloadVM] Download already in progress"),work())}async function jFn(){let t=await ugn();if(t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}}async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}var pipe="\\\\.\\pipe\\cowork-vm-service";function gz(e){switch(e){case"linux":return"unix"}}async function sUt(a,b){for(let n=0;n<2;n++)try{return await rpc()}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t)throw Error("VM service not running. The service failed to start.");await MS(delay)}}let E=!1;E||(E=!0,IT({name:"cowork-vm-shutdown",fn:async()=>{}}));async function start(){let i="bundle",g={};if(J.info(`[VM:start] memory=${memory}GB`),process.platform==="win32"){let e=nU(),t=(0,n.join)(process.resourcesPath,`smol-bin.${e}.vhdx`),r=(0,n.join)(i,QAn);if((0,u.existsSync)(t)){J.info(`[VM:start] Copying smol-bin.${e}.vhdx to bundle: ${t} -> ${r}`);try{await(0,ne.pipeline)((0,u.createReadStream)(t),Kr(r)),J.info(`[VM:start] smol-bin.${e}.vhdx copied successfully`)}catch(e){throw e}}g.configure&&(J.info("[VM:start] Configuring Windows VM service..."),await g.configure(),J.info("[VM:start] Windows VM service configured"))}process.platform==="linux"&&g.configure&&await g.configure()}let api={getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}};' \
		> "$main_js"
}

@test "latest cowork: direct gates and wrapped socket error are patched" {
	write_latest_cowork_fixture
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 11 cowork patches'* ]]
	[[ $output != *'Some patches failed'* ]]
	# 1.44121.4は識別情報を確認せずに接続するため、Patch 3bは適用しない
	[[ $output == *'socket check skipped'* ]]

	local name pattern _sample
	while IFS=$'\t' read -r name pattern _sample; do
		[[ -z $name || $name == '#'* ]] && continue
		# 次の2つは完全なバンドル構造を必要とし、この焦点を絞った固定データでは表現できない
		# 検証済みのVM接続は2.37337.1で入った
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

# 2.37337.1ではアンカーが3つ形を変えた
# VMサービス側のエラー文字列はメッセージ定数から組み立てられ、
# 再インストール用の一覧は動的なマニフェスト由来の関数になり、
# VMのダウンロード一時領域はバンドル内 (.wvm-tmp- と [Bundle:sweep]) に置かれるようになった
#
# @brief 2.37337.1系のminify済み形状を持つindex.jsを書き出す
# @global TEST_TMP 書き出し先の一時ディレクトリ (参照のみ)
# @global main_js 書き出すindex.jsのパス (参照のみ)
#
write_237337_cowork_fixture() {
	printf '%s' \
		'let r=Lz();if(r.status!=="supported"){J.warn(`[startVM] VM not supported`) }function Lhn(){let e=process.platform;if(e!=="darwin"&&e!=="win32")return{status:"unsupported",reason:q().formatMessage({defaultMessage:"Cowork is not currently supported on {platform}"})}}async function aU(){return Lz().status==="supported"&&(J.info("[downloadVM] Download already in progress"),work())}async function jFn(){let t=await ugn();if(t.status!=="supported"){J.info("[warm] Skipping VM warm download");return}}async function SUt(){return Ir()?(J.info("vmClient (TypeScript)"),client):null}var pipe="\\\\.\\pipe\\cowork-vm-service";function gz(e){switch(e){case"linux":return"unix"}}var ewn="ERR_VM_PIPE_CLOSED",twn="VM service not running";var fwn=!1;async function pwn(e,t){let n=Ci()?.connectNamedPipeSystemOwned;if(typeof n!="function"){if(a.app.isPackaged)throw Object.assign(Error("@ant/claude-native is unavailable or does not provide connectNamedPipeSystemOwned; refusing to connect to the cowork VM service pipe without server-identity verification. Reinstall Claude to restore it."),{code:nwn});return fwn||(fwn=!0,Z.warn("[win-vm] claude-native connectNamedPipeSystemOwned unavailable in this dev build; falling back to net.createConnection")),mwn(e,t)}let r;try{r=await n(e,!a.app.isPackaged)}catch(e){throw QCn(e)}return new g.Socket({fd:r,readable:!0,writable:!0})}function mwn(e,t){return new Promise(((n,r)=>{let i=g.createConnection(e);t.onSocketCreated?.(i);i.once("error",r),i.once("connect",(()=>n(i)))}))}var _endConnect=1;var _Tn=5,vTn=20,yTn=1e3,Zk=`${twn}. The service failed to start.`;async function bTn(e,t){let n=await zk();return n}async function xTn(e,t){let n=_Tn;for(let a=0;a<=n;a++){try{return await bTn(e,t)}catch(e){let t=(e instanceof Error&&"code"in e?e.code:void 0)==="ENOENT"||!1;if(!t||a===n)throw t?Error(Zk):e;await Hm(yTn)}}}throw Error(Zk);var CYr="efivars.fd";function aJ(){return[]}function dXr(){let e=aJ().map((e=>({file:e.name,origin:`.${e.name}.origin`})));return(process.platform==="darwin"||process.platform==="linux")&&e.push({file:CYr}),e}var vYr=".wvm-tmp-",yYr=".partial";function HYr(e,t){return(0,n.join)(e,`${t.name}.zst.${r}${yYr}`)}function WYr(e){return e.startsWith(vYr)}async function nXr(e,t){let r=sJ(),i=e.name,s=(0,n.join)(r,i),c=(0,n.join)(r,`.${i}.origin`),g=HYr(r,e);return g}Z.info("[Bundle:sweep] Startup sweep");let E=!1;E||(E=!0,IT({name:"cowork-vm-shutdown",fn:async()=>{}}));async function start(){let i="bundle",g={};if(J.info(`[VM:start] memory=${memory}GB`),process.platform==="win32"){let e=nU(),t=(0,n.join)(process.resourcesPath,`smol-bin.${e}.vhdx`),r=(0,n.join)(i,QAn);if((0,u.existsSync)(t)){J.info(`[VM:start] Copying smol-bin.${e}.vhdx to bundle: ${t} -> ${r}`);try{await(0,ne.pipeline)((0,u.createReadStream)(t),Kr(r)),J.info(`[VM:start] smol-bin.${e}.vhdx copied successfully`)}catch(e){throw e}}g.configure&&(J.info("[VM:start] Configuring Windows VM service..."),await g.configure(),J.info("[VM:start] Windows VM service configured"))}process.platform==="linux"&&g.configure&&await g.configure()}let api={getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}};' \
		> "$main_js"
}

@test "2.37337.1 shapes: template error string, dynamic list, bundle-local staging" {
	write_237337_cowork_fixture
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 13 cowork patches'* ]]
	[[ $output == *'Patched VM service connect to verify the Unix socket on Linux (fn: pwn)'* ]]
	[[ $output != *'Some patches failed'* ]]
	# 従来の3つの警告がどれも残っていてはいけない
	[[ $output != *'Could not find VM service error string'* ]]
	[[ $output != *'Could not find reinstall file list array'* ]]
	[[ $output != *'Could not find mkdtemp'* ]]
	[[ $output == *'Expanded wrapped ENOENT check to include ECONNREFUSED on Linux'* ]]
	[[ $output == *'Added service daemon auto-launch on Linux'* ]]
	[[ $output == *'dynamic manifest shape'* ]]
	[[ $output == *'tmpdir patch not needed'* ]]
	# 起動のクールダウン制御は、形の変わったループ関数側に付く
	grep -q 'xTn._lastSpawn' "$main_js"
	# 動的な削除一覧には、復旧用の2つの項目が入る
	grep -qF '.push({file:"sessiondata.img"})' "$main_js"
	grep -qF '.push({file:"rootfs.img.zst",origin:".rootfs.img.zst.origin"})' "$main_js"

	local name pattern _sample
	while IFS=$'\t' read -r name pattern _sample; do
		[[ -z $name || $name == '#'* ]] && continue
		# 次の2つは完全なバンドル構造を必要とし、この焦点を絞った固定データでは表現できない
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
	# パッチ適用済みのバンドルへ再実行しても、誤った失敗を報告してはいけない
	[[ $output != *'Could not find pipe path'* ]]
	[[ $output != *'Some patches failed'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

# Patch 3b : 2.37337.1は、claude-nativeのWindowsパイプ識別呼び出しを持たない状態で、
# パッケージ済みアプリからVMサービスへ接続することを拒否する
# パッチを当てた接続処理を実際のソケットに対して動かして確認する
# 接続できるのは、このuidが所有し、他のユーザーが変更できない正規のパスにあるソケットだけである
# パスは親だけでなく、すべての上位ディレクトリを確認する
# ソケットが無い場合は、デーモンの自動起動が動くようENOENTで拒否しなければならない
# それ以外の検索失敗(ENOTDIR、ELOOP)は、検証用のエラーコードで拒否しなければならない
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

# Patch 3bのアンカーは整形の揺れを許容する必要がある
# getter呼び出し、代替の定義、その中のcreateConnection呼び出しに空白が入っていてもパッチできる
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

# 修正1 : 再試行ループから遅延が消えているうえ、無関係な後続の非同期関数が
# 単一引数のawaitを持っている
# 注入先をその関数へ取り違えてはいけない
# 警告を出してファイルを変更しない
# 他に書き込む副パッチが動かないよう、
# 固定データにはLinux対応ゲートを適用済みにして、ファイル全体の同一性を意味のある検査にする
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

# 修正2a : 別の場所にある無関係なsessiondataのpushが、変更前のdXrを
# 隠してはいけない
# 復旧用のエントリは両方ともそちらへ追加される
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

# 修正2b : 一部だけ適用済み(sessiondataのpushだけがある)場合は、足りないrootfsの
# エントリだけを追加する
# 再実行してもバイト単位で同一になる
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

# 修正3 : マーカーと、importした呼び出しによるtmpdirのmkdtempが揃っていても
# 不要と判定してはいけない
# 従来のパス処理が担当する
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

# 修正4 : 新しいアンカーの空白や改行を変えた形でもパッチでき、
# 2回目の実行結果はバイト単位で同一になる
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

# 再レビューA1 : テンプレート定数を投げる唯一の関数である再試行ループから
# ENOENTの判定が消えている
# 別の関数は独自のENOENT・for・遅延・Errorを持っている
# パッチ6はその別の関数を採用してはいけない
# 候補はテンプレート定数を参照している必要がある
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

# 再レビューA2 : テンプレートを投げ、かつENOENT判定を持つ関数が2つあり、
# 対象を絞れないため何も注入しない
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

# 再レビューB : ステージングのマーカーはあるが、ダウンロード処理のステージング先は
# アンカーの走査範囲の外にあるimportした呼び出しのtmpdir()から取っている
# これはバンドル内のパスではないため、不要というINFOを出してはいけない
@test "tmpdir: staging dir from imported-call tmpdir() is not reported bundle-local" {
	# アンカーの走査幅(前後1500文字)を超えるまで埋めて、
	# 呼び出し位置から辿る確認だけがこのtmpdir()を検出できる状態にする
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

# 再レビューD : ドル記号を含むバンドル変数が、importした呼び出しの書き換え後も
# そのまま残ること
# 置換文字列として扱うと連続したドル記号が1つに減ってしまう
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

# 5.1231.2では、getDownloadStatusが非同期メソッドになり、
# ステージング用ヘルパーの定義の直前に `.origin` を組み立てる別の関数が置かれた
# 定義を呼び出し位置と誤認せず、非同期版にもLinuxの早期returnを入れなければならない
#
# @brief 2.37337.1系の固定データを5.1231.2系の形状へ書き換える
# @global main_js 書き換えるindex.jsのパス (参照のみ)
#
write_51231_cowork_fixture() {
	write_237337_cowork_fixture
	MAIN_JS="$main_js" node -e '
		const fs = require("fs");
		let c = fs.readFileSync(process.env.MAIN_JS, "utf8");
		const fns = [
			["getDownloadStatus(){return lU()?zb.Downloading:cU()?zb.Ready:zb.NotDownloaded}",
				"async getDownloadStatus(){let e=await xS();return e!==zb.NotDownloaded||!lP?e:(await lP,xS())}"],
			["function HYr(e,t){",
				"async function tXr(e,t){return await(0,h.readFile)((0,n.join)(e,`.${t}.origin`),\"utf8\")}function HYr(e,t){"],
		];
		for (const [from, to] of fns) {
			if (!c.includes(from)) throw new Error("fixture anchor missing: " + from);
			c = c.replace(from, to);
		}
		fs.writeFileSync(process.env.MAIN_JS, c);
	'
}

@test "5.1231.2 shapes: async getDownloadStatus and staging helper definition" {
	write_51231_cowork_fixture
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Patched async getDownloadStatus to return NotDownloaded on Linux'* ]]
	[[ $output == *'tmpdir patch not needed'* ]]
	[[ $output != *'Could not find getDownloadStatus'* ]]
	[[ $output != *'Could not find mkdtemp'* ]]
	grep -qF 'async getDownloadStatus(){if(process.platform==="linux")return zb.NotDownloaded;let e=await xS();' "$main_js"
	local pattern
	pattern=$(awk -F '\t' '$1 == "getdownloadstatus-suppression" { print $2 }' "$MARKERS_TSV")
	grep -qP -- "$pattern" "$main_js"
	node --check "$main_js"
}

@test "5.1231.2 shapes: patching twice is byte-idempotent" {
	write_51231_cowork_fixture
	patch_cowork_linux >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Applied 0 cowork patches'* ]]
	[[ $output == *'Cowork auto-nav suppression already applied'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

# 先に現れる別のasyncメソッドを書き換えず、空白入りの形状とドル記号を含むenum名も
# そのまま扱えること
@test "5.1231.2 shapes: async getDownloadStatus patch targets the matched method verbatim" {
	write_51231_cowork_fixture
	MAIN_JS="$main_js" node -e '
		const fs = require("fs");
		let c = fs.readFileSync(process.env.MAIN_JS, "utf8");
		const from = "async getDownloadStatus(){let e=await xS();return e!==zb.NotDownloaded";
		if (!c.includes(from)) throw new Error("fixture anchor missing");
		c = c.replace(from, () =>
			"async getDownloadStatus ( ) {let e=await xS();return e!==z$$ . NotDownloaded");
		fs.writeFileSync(process.env.MAIN_JS,
			"class Dq{async getDownloadStatus(){return 7}}" + c);
	'
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output == *'Patched async getDownloadStatus to return NotDownloaded on Linux'* ]]
	grep -qF 'class Dq{async getDownloadStatus(){return 7}}' "$main_js"
	grep -qF 'async getDownloadStatus(){if(process.platform==="linux")return z$$.NotDownloaded;let e=await xS();' "$main_js"
	node --check "$main_js"
}

# 定義を呼び出し位置から外しても、`.origin` で裏付けられない実際の呼び出しは
# 未証明として数え、バンドル内と報告してはいけない
@test "5.1231.2 shapes: an unproven staging call far from the anchors is not bundle-local" {
	write_51231_cowork_fixture
	local pad
	pad=$(printf '%2000s' '')
	printf '%s' "/*$pad*/async function bad(e){let r=(0,os.tmpdir)();return HYr(r,e)}" >> "$main_js"
	run patch_cowork_linux
	[[ $status -eq 0 ]]
	[[ $output != *'tmpdir patch not needed'* ]]
	[[ $output == *'Could not find mkdtemp'* ]]
}
