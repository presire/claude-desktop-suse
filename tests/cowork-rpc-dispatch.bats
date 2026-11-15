#!/usr/bin/env bats
#
# @file cowork-rpc-dispatch.bats
# @brief cowork-vm-service.jsのRPCメソッドと並行ディスパッチを確認する
#
# 追加したセッションディスク系RPC、getMemoryInfo、getNetworkDrives、
# 未知メソッドのエラー文字列、runEdrExtensionの未対応通知、
# KVMでの未検証ゲストRPC転送の明示的な無効化、フレーム分割と
# リクエストID、遅い要求が同じ接続の後続要求をブロックしないこと、
# VMのstart/stopが直列化されること、QMP接続とゲスト待機の期限・中断、
# 正常なQMP交渉後のコマンド送信、virtiofsd待機中の中断でQEMUを
# 起動しないこと、強制cleanupによる所有資源の回収、shutdown中の
# 新規start拒否と最後のstopの一意性、期限切れ時の強制cleanupを、
# 実際のデーモンまたは制御されたバックエンドで検証する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ

#
# @brief テストごとの作業ディレクトリとRPCハーネスを用意する
# @global TEST_ROOT デーモン用のHOME/XDGを作る一時ディレクトリ
# @global HARNESS Node.js製のRPCクライアントのパス
#
setup() {
	TEST_ROOT=$(mktemp -d -p "${BATS_TEST_TMPDIR:-/tmp}")
	export TEST_ROOT
	export SERVICE_PATH="${SCRIPT_DIR}/../scripts/cowork-vm-service.js"
	export HARNESS="${BATS_FILE_TMPDIR}/rpc-harness.js"
	if [[ ! -f "$HARNESS" ]]; then
		cat > "$HARNESS" <<'NODE'
'use strict';

const { spawn } = require('child_process');
const net = require('net');
const fs = require('fs');
const path = require('path');

const SERVICE = process.env.SERVICE_PATH;
const ROOT = process.env.TEST_ROOT;
const MODE = process.argv[2];

function fail(msg) {
	process.stderr.write('HARNESS FAILED: ' + msg + '\n');
	process.exit(1);
}

function assert(condition, msg) {
	if (!condition) fail(msg);
}

function assertEqual(actual, expected, msg) {
	assert(actual === expected, msg + ' expected=' + JSON.stringify(expected)
		+ ' actual=' + JSON.stringify(actual));
}

function assertDeepEqual(actual, expected, msg) {
	const a = JSON.stringify(actual);
	const e = JSON.stringify(expected);
	assert(a === e, msg + ' expected=' + e + ' actual=' + a);
}

function assertNumber(value, msg) {
	assert(typeof value === 'number' && Number.isFinite(value),
		msg + ' expected number actual=' + JSON.stringify(value));
}

async function assertRejects(promise, msg, expected) {
	try {
		await promise;
	} catch (e) {
		assertEqual(e.message, expected, msg);
		return;
	}
	fail(msg + ': expected rejection');
}

function deferred() {
	let resolve;
	let reject;
	const promise = new Promise((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

function flush() {
	return new Promise((resolve) => setImmediate(resolve));
}

function withDeadline(promise, ms, label) {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			reject(new Error(label + ': exceeded ' + ms + 'ms'));
		}, ms);
		Promise.resolve(promise).then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}

function classifyClientError(message) {
	if (message.startsWith('handler not registered:')
			|| message.startsWith('unknown method:')) {
		return 'unsupported';
	}
	return 'error';
}

function unverifiedGuestMessage(method) {
	return 'handler not registered: ' + method
		+ ' (unsupported on KVM backend: guest wire protocol unverified)';
}

function startDaemon(backend, extraEnv) {
	const home = fs.mkdtempSync(path.join(ROOT, 'home-'));
	const xdg = fs.mkdtempSync(path.join(ROOT, 'xdg-'));
	const env = {
		...process.env,
		HOME: home,
		XDG_RUNTIME_DIR: xdg,
		XDG_CONFIG_HOME: path.join(home, '.config'),
		XDG_CACHE_HOME: path.join(home, '.cache'),
		XDG_DATA_HOME: path.join(home, '.local', 'share'),
		COWORK_VM_BACKEND: backend,
		COWORK_VM_VIRTIOFSD_BIN: '/nonexistent',
		...(extraEnv || {}),
	};
	const child = spawn(process.execPath, [SERVICE], {
		env,
		stdio: ['ignore', 'pipe', 'pipe'],
		detached: true,
	});
	let stdout = '';
	let stderr = '';
	child.stdout.on('data', (data) => { stdout += data.toString(); });
	child.stderr.on('data', (data) => { stderr += data.toString(); });

	const socketPath = new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			reject(new Error('daemon start timeout stderr=' + stderr));
		}, 5000);
		const onData = () => {
			const match = stdout.match(/Service started on (\S+)/);
			if (match) {
				clearTimeout(timer);
				resolve(match[1]);
			}
		};
		child.stdout.on('data', onData);
		child.on('exit', (code) => {
			clearTimeout(timer);
			reject(new Error('daemon exited ' + code
				+ ' stderr=' + stderr));
		});
	});

	return { child, socketPath };
}

function stopDaemon(child) {
	try {
		process.kill(-child.pid, 'SIGKILL');
	} catch (_) { /* already gone */ }
}

function connect(socketPath) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(socketPath, () => resolve(socket));
		socket.once('error', reject);
	});
}

function makeReader(socket) {
	let buffer = Buffer.alloc(0);
	const queued = [];
	const waiters = [];

	function pump() {
		while (buffer.length >= 4) {
			const length = buffer.readUInt32BE(0);
			if (buffer.length < 4 + length) break;
			const body = buffer.subarray(4, 4 + length).toString();
			buffer = buffer.subarray(4 + length);
			let message;
			try {
				message = JSON.parse(body);
			} catch (e) {
				fail('invalid JSON reply: ' + body);
			}
			const waiter = waiters.shift();
			if (waiter) {
				clearTimeout(waiter.timer);
				waiter.resolve(message);
			} else {
				queued.push(message);
			}
		}
	}

	socket.on('data', (data) => {
		buffer = Buffer.concat([buffer, data]);
		pump();
	});

	return {
		next(timeoutMs) {
			const timeout = timeoutMs || 5000;
			if (queued.length) return Promise.resolve(queued.shift());
			return new Promise((resolve, reject) => {
				const waiter = { resolve, timer: null };
				waiter.timer = setTimeout(() => {
					const index = waiters.indexOf(waiter);
					if (index >= 0) waiters.splice(index, 1);
					reject(new Error('reply timeout'));
				}, timeout);
				waiters.push(waiter);
			});
		},
	};
}

function frame(message) {
	const body = Buffer.from(JSON.stringify(message));
	const header = Buffer.alloc(4);
	header.writeUInt32BE(body.length, 0);
	return Buffer.concat([header, body]);
}

let nextRequestId = 1;

async function rpc(socket, reader, method, params) {
	const id = nextRequestId++;
	socket.write(frame({ id, method, params: params || {} }));
	const reply = await reader.next();
	assertEqual(reply.id, id, method + ': response id');
	return reply;
}

async function localBackendSuite(backend) {
	const daemon = startDaemon(backend);
	try {
		const socketPath = await daemon.socketPath;
		const socket = await connect(socketPath);
		const reader = makeReader(socket);

		let reply = await rpc(socket, reader, 'getSessionsDiskInfo',
			{ lowWaterBytes: 0 });
		assertEqual(reply.success, true, backend + ': disk info success');
		assertNumber(reply.result.totalBytes, backend + ': totalBytes');
		assertNumber(reply.result.freeBytes, backend + ': freeBytes');
		assert(reply.result.totalBytes > 0, backend + ': totalBytes > 0');
		assert(reply.result.freeBytes >= 0, backend + ': freeBytes >= 0');
		assertDeepEqual(reply.result.sessions, [],
			backend + ': no VM sessions');

		reply = await rpc(socket, reader, 'deleteSessionDirs',
			{ sessionNames: ['missing'] });
		assertEqual(reply.success, true, backend + ': delete success');
		assertDeepEqual(reply.result, { deleted: [], errors: {} },
			backend + ': delete result');

		reply = await rpc(socket, reader, 'pruneSessionCaches',
			{ onlyIfFreeBytesBelow: 1 });
		assertEqual(reply.success, true, backend + ': prune success');
		assertDeepEqual(reply.result, {
			prunedSessions: [],
			skippedSessions: [],
			freedBytes: 0,
			errors: {},
		}, backend + ': prune result');

		reply = await rpc(socket, reader, 'getNetworkDrives');
		assertEqual(reply.success, true, backend + ': network drives success');
		assertDeepEqual(reply.result, { drives: [] },
			backend + ': network drives result');

		reply = await rpc(socket, reader, 'getMemoryInfo');
		assertEqual(reply.success, true, backend + ': memory success');
		assertNumber(reply.result.totalBytes, backend + ': memory total');
		assertNumber(reply.result.freeBytes, backend + ': memory free');
		assertNumber(reply.result.availableBytes,
			backend + ': memory available');
		assert(reply.result.totalBytes >= reply.result.freeBytes,
			backend + ': total >= free');
		assert(reply.result.availableBytes > 0,
			backend + ': available > 0');

		reply = await rpc(socket, reader, 'sendGuestResponse',
			{ id: 'test-1', resultJson: '{}' });
		assertEqual(reply.success, true, backend + ': sendGuestResponse');
		assertDeepEqual(reply.result, {},
			backend + ': sendGuestResponse no-op');

		reply = await rpc(socket, reader, 'refreshGuestProxy');
		assertEqual(reply.success, false, backend + ': unknown success=false');
		assertEqual(reply.error, 'unknown method: refreshGuestProxy',
			backend + ': unknown method text');

		reply = await rpc(socket, reader, 'runEdrExtension',
			{ extensionId: 'test' });
		assertEqual(reply.success, false, backend + ': EDR success=false');
		assertEqual(reply.error, 'handler not registered: runEdrExtension',
			backend + ': EDR unsupported text');

		socket.end();
	} finally {
		stopDaemon(daemon.child);
	}
}

async function kvmSuite() {
	const daemon = startDaemon('kvm');
	try {
		const socketPath = await daemon.socketPath;
		const socket = await connect(socketPath);
		const reader = makeReader(socket);

		const guestMethods = [
			['getSessionsDiskInfo', {}],
			['deleteSessionDirs', { sessionNames: ['x'] }],
			['pruneSessionCaches', { onlyIfFreeBytesBelow: 1 }],
			['sendGuestResponse', { id: '1', resultJson: '{}' }],
		];
		for (const [method, params] of guestMethods) {
			const reply = await rpc(socket, reader, method, params);
			assertEqual(reply.success, false, 'kvm: ' + method + ' fails');
			assertEqual(reply.error, unverifiedGuestMessage(method),
				'kvm: ' + method + ' explicit unsupported');
			assertEqual(classifyClientError(reply.error), 'unsupported',
				'kvm: ' + method + ' client classification');
		}

		let reply = await rpc(socket, reader, 'getNetworkDrives');
		assertEqual(reply.success, true, 'kvm: network drives success');
		assertDeepEqual(reply.result, { drives: [] },
			'kvm: network drives result');

		reply = await rpc(socket, reader, 'getMemoryInfo');
		assertEqual(reply.success, true, 'kvm: memory success');
		assertNumber(reply.result.totalBytes, 'kvm: memory total');
		assertNumber(reply.result.freeBytes, 'kvm: memory free');
		assertNumber(reply.result.availableBytes, 'kvm: memory available');

		socket.end();
	} finally {
		stopDaemon(daemon.child);
	}
}

async function guestForwardingDisabledSuite() {
	const home = fs.mkdtempSync(path.join(ROOT, 'home-'));
	const xdg = fs.mkdtempSync(path.join(ROOT, 'xdg-'));
	process.env.HOME = home;
	process.env.XDG_RUNTIME_DIR = xdg;
	process.env.XDG_CONFIG_HOME = path.join(home, '.config');
	process.env.XDG_CACHE_HOME = path.join(home, '.cache');
	process.env.XDG_DATA_HOME = path.join(home, '.local', 'share');
	const { KvmBackend } = require(SERVICE);
	const { PassThrough } = require('stream');
	const events = [];
	const backend = new KvmBackend((event) => events.push(event));
	const guest = new PassThrough();
	let guestWrites = '';
	guest.on('data', (data) => { guestWrites += data.toString(); });
	backend._guestConn = guest;
	backend._guestBuffer = Buffer.alloc(0);
	backend.guestConnected = true;

	backend._handleGuestData(frame({
		type: 'request',
		id: 'g1',
		method: 'classifyCliPlugin',
		params: { sessionId: 's1' },
	}));
	assertEqual(events.length, 0,
		'guest forwarding: request frame not re-emitted');

	await assertRejects(
		backend.sendGuestResponse({ id: 'g1', resultJson: '{}' }),
		'guest forwarding: sendGuestResponse',
		unverifiedGuestMessage('sendGuestResponse'));
	try {
		await backend.sendGuestResponse({ id: 'g1', resultJson: '{}' });
	} catch (e) {
		assertEqual(classifyClientError(e.message), 'unsupported',
			'guest forwarding: sendGuestResponse classification');
	}

	for (const method of ['getSessionsDiskInfo', 'deleteSessionDirs',
		'pruneSessionCaches']) {
		await assertRejects(backend[method]({}),
			'guest forwarding: ' + method,
			unverifiedGuestMessage(method));
		try {
			await backend[method]({});
		} catch (e) {
			assertEqual(classifyClientError(e.message), 'unsupported',
				'guest forwarding: ' + method + ' classification');
		}
	}
	assertEqual(guestWrites, '', 'guest forwarding: guest received no frames');
	guest.end();
}

async function framingSuite() {
	const daemon = startDaemon('host');
	try {
		const socketPath = await daemon.socketPath;
		const socket = await connect(socketPath);
		const reader = makeReader(socket);

		const message = frame({
			id: 41,
			method: 'getMemoryInfo',
			params: {},
		});
		socket.write(message.subarray(0, 2));
		await new Promise((resolve) => setImmediate(resolve));
		socket.write(message.subarray(2, 7));
		await new Promise((resolve) => setImmediate(resolve));
		socket.write(message.subarray(7));
		const first = await reader.next();
		assertEqual(first.id, 41, 'framing: split frame id');
		assertEqual(first.success, true, 'framing: split frame success');

		socket.write(Buffer.concat([
			frame({ id: 42, method: 'getMemoryInfo', params: {} }),
			frame({ id: 43, method: 'getNetworkDrives', params: {} }),
		]));
		const replies = [await reader.next(), await reader.next()];
		const ids = replies.map((reply) => reply.id).sort((a, b) => a - b);
		assertDeepEqual(ids, [42, 43], 'framing: both ids echoed');
		for (const reply of replies) {
			assertEqual(reply.success, true, 'framing: batched reply success');
		}

		socket.end();
	} finally {
		stopDaemon(daemon.child);
	}
}

async function concurrencySuite() {
	const binDir = path.join(ROOT, 'bin');
	const bundleDir = path.join(ROOT, 'bundle');
	fs.mkdirSync(binDir);
	fs.mkdirSync(bundleDir);
	fs.writeFileSync(path.join(binDir, 'qemu-img'),
		'#!/bin/sh\nexit 0\n', { mode: 0o755 });
	fs.writeFileSync(path.join(binDir, 'qemu-system-x86_64'),
		'#!/bin/sh\nexec tail -f /dev/null\n', { mode: 0o755 });
	fs.writeFileSync(path.join(bundleDir, 'rootfs.qcow2'), '');

	const daemon = startDaemon('kvm', {
		PATH: binDir + ':' + process.env.PATH,
	});
	try {
		const socketPath = await daemon.socketPath;
		const socket = await connect(socketPath);
		const reader = makeReader(socket);

		socket.write(Buffer.concat([
			frame({
				id: 101,
				method: 'startVM',
				params: { bundlePath: bundleDir, memoryGB: 1 },
			}),
			frame({ id: 102, method: 'isRunning', params: {} }),
		]));

		const first = await reader.next(5000);
		assertEqual(first.id, 102,
			'concurrency: fast request replies before slow startVM');
		assertEqual(first.success, true, 'concurrency: isRunning success');
		assertEqual(first.result.running, true,
			'concurrency: VM marked running before QMP wait');

		socket.end();
	} finally {
		stopDaemon(daemon.child);
	}
}

async function lifecycleSuite() {
	process.env.COWORK_VM_BACKEND = 'host';
	const { VMManager } = require(SERVICE);
	const manager = new VMManager();
	const calls = [];
	const gates = [];
	let wakeStart = null;
	let wakeStop = null;
	let stopRequests = 0;

	manager.backend = {
		requestStop() {
			stopRequests += 1;
		},
		startVM(params) {
			calls.push('start:' + params.tag);
			const gate = deferred();
			gates.push(gate);
			if (wakeStart) {
				const wake = wakeStart;
				wakeStart = null;
				wake();
			}
			return gate.promise;
		},
		stopVM() {
			calls.push('stop');
			const gate = deferred();
			gates.push(gate);
			if (wakeStop) {
				const wake = wakeStop;
				wakeStop = null;
				wake();
			}
			return gate.promise;
		},
		isRunning() {
			return { running: true };
		},
	};

	const startedA = deferred();
	wakeStart = startedA.resolve;
	const startA = manager.startVM({ tag: 'a' });
	await startedA.promise;

	const startedB = deferred();
	wakeStart = startedB.resolve;
	const startB = manager.startVM({ tag: 'b' });
	await flush();
	assertDeepEqual(calls, ['start:a'],
		'lifecycle: concurrent start waits for the first');
	assertDeepEqual(manager.isRunning(), { running: true },
		'lifecycle: status read while start is pending');

	gates[0].resolve({});
	await startA;
	await startedB.promise;
	assertDeepEqual(calls, ['start:a', 'start:b'],
		'lifecycle: queued start runs after the first');
	gates[1].resolve({});
	await startB;

	const startedC = deferred();
	wakeStart = startedC.resolve;
	const startC = manager.startVM({ tag: 'c' });
	await startedC.promise;

	const stopped = deferred();
	wakeStop = stopped.resolve;
	const stopAfterStart = manager.stopVM();
	await assertRejects(startC, 'lifecycle: stop aborts pending start',
		'VM stop requested');
	assertEqual(stopRequests, 1, 'lifecycle: stop requests backend abort');
	await flush();
	assertDeepEqual(calls, ['start:a', 'start:b', 'start:c'],
		'lifecycle: stop waits for the settling start');
	gates[2].resolve({});
	await stopped.promise;
	gates[3].resolve({});
	await stopAfterStart;
	assertDeepEqual(calls, ['start:a', 'start:b', 'start:c', 'stop'],
		'lifecycle: queued stop runs after the start');

	const failed = deferred();
	wakeStart = failed.resolve;
	const startFailed = manager.startVM({ tag: 'failed' });
	await failed.promise;
	gates[4].reject(new Error('start failed'));
	await assertRejects(startFailed, 'lifecycle: failed start surfaces',
		'start failed');

	const stoppedAfterFailure = deferred();
	wakeStop = stoppedAfterFailure.resolve;
	const stopAfterFailure = manager.stopVM();
	await stoppedAfterFailure.promise;
	gates[5].resolve({});
	await stopAfterFailure;
	assertEqual(calls[calls.length - 1], 'stop',
		'lifecycle: queue survives a failed start');
}

function isolatedHome() {
	const home = fs.mkdtempSync(path.join(ROOT, 'home-'));
	const xdg = fs.mkdtempSync(path.join(ROOT, 'xdg-'));
	process.env.HOME = home;
	process.env.XDG_RUNTIME_DIR = xdg;
	process.env.XDG_CONFIG_HOME = path.join(home, '.config');
	process.env.XDG_CACHE_HOME = path.join(home, '.cache');
	process.env.XDG_DATA_HOME = path.join(home, '.local', 'share');
	return home;
}

function listenOn(server, socketPath) {
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(socketPath, () => {
			server.removeListener('error', reject);
			resolve();
		});
	});
}

async function qmpSuite() {
	const home = isolatedHome();
	const { KvmBackend } = require(SERVICE);
	const connectOptions = {
		qmpConnectTimeout: 150,
		qmpInitialDelay: 1,
		qmpRetryDelay: 5,
	};

	const commands = [];
	const success = net.createServer((conn) => {
		conn.on('error', () => {});
		conn.write('{"QMP":{"version":{}}}\n');
		let buffer = '';
		conn.on('data', (data) => {
			buffer += data.toString();
			let newline;
			while ((newline = buffer.indexOf('\n')) >= 0) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line) continue;
				const command = JSON.parse(line);
				commands.push(command.execute);
				conn.write(JSON.stringify({ return: {} }) + '\n');
			}
		});
	});
	const successSock = path.join(home, 'qmp-success.sock');
	await withDeadline(listenOn(success, successSock), 1000,
		'qmp: success listen');
	const successBackend = new KvmBackend(() => {});
	Object.assign(successBackend, {
		monitorSock: successSock,
		qmpInitialDelay: 1,
		qmpRetryDelay: 5,
		qmpConnectTimeout: 2000,
	});
	await withDeadline(successBackend._connectQmp(), 2000,
		'qmp: normal negotiation');
	assertEqual(successBackend._qmpAvailable, true,
		'qmp: normal negotiation available');
	const client = successBackend._qmpClient;
	assert(client && !client.destroyed,
		'qmp: normal negotiation keeps the socket');
	const powerdown = await withDeadline(
		successBackend._sendQmpCommand('system_powerdown'), 1000,
		'qmp: system_powerdown');
	assertDeepEqual(powerdown, { return: {} },
		'qmp: system_powerdown reply');
	const quit = await withDeadline(
		successBackend._sendQmpCommand('quit'), 1000, 'qmp: quit');
	assertDeepEqual(quit, { return: {} }, 'qmp: quit reply');
	assertDeepEqual(commands,
		['qmp_capabilities', 'system_powerdown', 'quit'],
		'qmp: commands use the negotiated socket');
	const clientClosed = new Promise((resolve) => {
		client.once('close', resolve);
	});
	client.destroy();
	await withDeadline(clientClosed, 1000, 'qmp: client socket closes');
	assertEqual(client.destroyed, true, 'qmp: client socket destroyed');
	success.close();

	// A command in flight when cleanup destroys the socket must reject
	// with the close, not crash later in its own timer.
	const mute = net.createServer((conn) => {
		conn.on('error', () => {});
		conn.write('{"QMP":{"version":{}}}\n');
		conn.once('data', () => {
			conn.write(JSON.stringify({ return: {} }) + '\n');
		});
	});
	const muteSock = path.join(home, 'qmp-mute.sock');
	await withDeadline(listenOn(mute, muteSock), 1000, 'qmp: mute listen');
	const racing = new KvmBackend(() => {});
	Object.assign(racing, {
		monitorSock: muteSock,
		qmpInitialDelay: 1,
		qmpRetryDelay: 5,
		qmpConnectTimeout: 2000,
		qmpCommandTimeout: 100,
	});
	await withDeadline(racing._connectQmp(), 2000, 'qmp: mute negotiation');
	assertEqual(racing._qmpAvailable, true, 'qmp: mute negotiated');
	const inFlight = racing._sendQmpCommand('system_powerdown');
	racing._cleanupOwnedResources();
	assertEqual(racing._qmpClient, null, 'qmp: cleanup clears client');
	let closeError = null;
	try {
		await withDeadline(inFlight, 1000, 'qmp: in-flight command settles');
	} catch (e) {
		closeError = e;
	}
	assertEqual(closeError && closeError.message, 'QMP connection closed',
		'qmp: in-flight command rejects on close');
	const timedOut = new KvmBackend(() => {});
	Object.assign(timedOut, {
		monitorSock: muteSock,
		qmpInitialDelay: 1,
		qmpRetryDelay: 5,
		qmpConnectTimeout: 2000,
		qmpCommandTimeout: 50,
	});
	await withDeadline(timedOut._connectQmp(), 2000,
		'qmp: timeout negotiation');
	let timeoutError = null;
	try {
		await withDeadline(timedOut._sendQmpCommand('quit'), 1000,
			'qmp: unanswered command settles');
	} catch (e) {
		timeoutError = e;
	}
	assertEqual(timeoutError && timeoutError.message, 'QMP command timeout',
		'qmp: unanswered command times out');
	timedOut._cleanupOwnedResources();
	mute.close();

	const noReturn = net.createServer((conn) => {
		conn.on('error', () => {});
		conn.write('{"QMP":{"version":{}}}\n');
	});
	const noReturnSock = path.join(home, 'qmp-no-return.sock');
	await withDeadline(listenOn(noReturn, noReturnSock), 1000,
		'qmp: no-return listen');
	const silent = new KvmBackend(() => {});
	Object.assign(silent, connectOptions, { monitorSock: noReturnSock });
	await withDeadline(silent._connectQmp(), 2000,
		'qmp: no response deadline');
	assertEqual(silent._qmpAvailable, false,
		'qmp: no response marks unavailable');
	assertEqual(silent._qmpClient, null,
		'qmp: no response leaves no client');
	noReturn.close();

	let connections = 0;
	const closing = net.createServer((conn) => {
		connections += 1;
		conn.on('error', () => {});
		conn.destroy();
	});
	const closingSock = path.join(home, 'qmp-closing.sock');
	await withDeadline(listenOn(closing, closingSock), 1000,
		'qmp: closing listen');
	const closeBackend = new KvmBackend(() => {});
	Object.assign(closeBackend, connectOptions, {
		monitorSock: closingSock,
	});
	await withDeadline(closeBackend._connectQmp(), 2000,
		'qmp: closed connection deadline');
	assertEqual(closeBackend._qmpAvailable, false,
		'qmp: closed connection marks unavailable');
	assert(connections >= 2,
		'qmp: close retries before deadline actual=' + connections);
	closing.close();

	const hanging = net.createServer((conn) => {
		conn.on('error', () => {});
		conn.write('{"QMP":{"version":{}}}\n');
	});
	const hangingSock = path.join(home, 'qmp-hanging.sock');
	await withDeadline(listenOn(hanging, hangingSock), 1000,
		'qmp: hanging listen');
	const abortBackend = new KvmBackend(() => {});
	Object.assign(abortBackend, connectOptions, {
		monitorSock: hangingSock,
		qmpConnectTimeout: 5000,
	});
	const connected = new Promise((resolve) => {
		hanging.once('connection', resolve);
	});
	const token = abortBackend._beginStartup();
	const pending = abortBackend._connectQmp(token);
	await withDeadline(connected, 1000, 'qmp: abort connect');
	token.cancel();
	await withDeadline(pending, 1000, 'qmp: abort resolves');
	assertEqual(abortBackend._qmpAvailable, false,
		'qmp: abort marks unavailable');
	abortBackend._endStartup(token);
	hanging.close();
}

async function guestWaitSuite() {
	const home = isolatedHome();
	const { KvmBackend } = require(SERVICE);
	const backend = new KvmBackend(() => {});
	backend._startVsockBridge = () => {};
	backend.bridgeSock = path.join(home, 'bridge.sock');

	const token = backend._beginStartup();
	const pending = backend._waitForGuest(token);
	assert(backend._bridgeServer, 'guest wait: bridge server created');
	const listening = backend._bridgeServer.listening
		? Promise.resolve()
		: new Promise((resolve) => {
			backend._bridgeServer.once('listening', resolve);
		});
	await withDeadline(listening, 1000, 'guest wait: bridge listening');
	token.cancel();
	await withDeadline(pending, 1000, 'guest wait: cancel resolves');
	assertEqual(token.cancelled, true, 'guest wait: token cancelled');
	await new Promise((resolve) => backend._bridgeServer.close(resolve));
	backend._endStartup(token);
}

async function kvmCancelSuite() {
	const home = isolatedHome();
	const binDir = path.join(home, 'bin');
	const bundleDir = path.join(home, 'bundle');
	const callsLog = path.join(home, 'qemu-img.log');
	const qemuLog = path.join(home, 'qemu.log');
	fs.mkdirSync(binDir);
	fs.mkdirSync(bundleDir);
	fs.writeFileSync(path.join(binDir, 'qemu-img'),
		'#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_QEMU_IMG_LOG"\nexit 0\n',
		{ mode: 0o755 });
	fs.writeFileSync(path.join(binDir, 'qemu-system-x86_64'),
		'#!/bin/sh\nprintf "spawned\\n" >> "$FAKE_QEMU_LOG"\nexec sleep 30\n',
		{ mode: 0o755 });
	const virtiofsd = path.join(home, 'virtiofsd-fake');
	fs.writeFileSync(virtiofsd, '#!/bin/sh\nexec sleep 30\n',
		{ mode: 0o755 });
	fs.writeFileSync(path.join(bundleDir, 'rootfs.qcow2'), '');
	fs.writeFileSync(path.join(bundleDir, 'smol-bin.vhdx'), '');

	process.env.PATH = binDir + ':' + process.env.PATH;
	process.env.COWORK_VM_VIRTIOFSD_BIN = virtiofsd;
	process.env.FAKE_QEMU_IMG_LOG = callsLog;
	process.env.FAKE_QEMU_LOG = qemuLog;

	const { KvmBackend } = require(SERVICE);
	const backend = new KvmBackend(() => {});
	await backend.init({ memoryMB: 1, cpuCount: 1 });

	const start = backend.startVM({
		bundlePath: bundleDir,
		memoryGB: 1,
	});
	const outcome = start.then(() => null, (e) => e);
	assert(backend.virtiofsdProcess,
		'cancel: virtiofsd spawned before the wait');
	const sessionDir = backend.sessionDir;
	assert(sessionDir, 'cancel: session dir created');

	backend.requestStop();
	const error = await withDeadline(outcome, 2000,
		'cancel: start settles');
	assertEqual(error.message, 'VM startup cancelled',
		'cancel: start reports cancellation');
	assertEqual(fs.existsSync(qemuLog), false,
		'cancel: QEMU was not spawned');
	assertEqual(fs.existsSync(path.join(sessionDir, 'sessiondata.qcow2')),
		false, 'cancel: session disk was not created');
	assertEqual(fs.existsSync(path.join(bundleDir, 'smol-bin.qcow2')),
		false, 'cancel: smol-bin conversion was not started');
	const qemuImgCalls = fs.readFileSync(callsLog, 'utf8')
		.trim().split('\n');
	assertEqual(qemuImgCalls.length, 1,
		'cancel: only the pre-wait overlay creation ran');
	assert(qemuImgCalls[0].startsWith('create '),
		'cancel: the pre-wait command was overlay creation');
	assertEqual(backend.sessionDir, null,
		'cancel: startup reclaimed the session');
	assertEqual(fs.existsSync(sessionDir), false,
		'cancel: session directory removed');
	assertEqual(backend.virtiofsdProcess, null,
		'cancel: virtiofsd reclaimed');
	assertEqual(backend.running, false,
		'cancel: backend is not running');
}

async function forceCleanupSuite() {
	const home = isolatedHome();
	const { KvmBackend } = require(SERVICE);
	const backend = new KvmBackend(() => {});
	const calls = [];
	const proc = (name) => ({
		exitCode: null,
		kill(signal) {
			calls.push(name + ':' + (signal || 'kill'));
		},
	});

	backend.qemuProcess = proc('qemu');
	backend.virtiofsdProcess = proc('virtiofsd');
	backend.socatProcess = proc('socat');
	backend._qmpClient = {
		destroy() { calls.push('qmp:destroy'); },
	};
	backend._guestConn = {
		destroy() { calls.push('guest:destroy'); },
	};
	backend._bridgeServer = {
		close() { calls.push('bridge:close'); },
	};
	const sessionDir = path.join(home, 'session');
	fs.mkdirSync(sessionDir);
	fs.writeFileSync(path.join(sessionDir, 'overlay.qcow2'), '');
	backend.sessionDir = sessionDir;
	backend.running = true;
	backend.guestConnected = true;

	backend.forceCleanup();
	assertDeepEqual(calls, [
		'qemu:SIGKILL',
		'virtiofsd:kill',
		'socat:kill',
		'qmp:destroy',
		'guest:destroy',
		'bridge:close',
	], 'force cleanup: owned processes and sockets');
	assertEqual(backend.sessionDir, null,
		'force cleanup: session detached');
	assertEqual(fs.existsSync(sessionDir), false,
		'force cleanup: session removed');
	assertEqual(backend.qemuProcess, null,
		'force cleanup: QEMU reference cleared');
	assertEqual(backend.running, false,
		'force cleanup: backend not running');
	assertEqual(backend.guestConnected, false,
		'force cleanup: guest not connected');
}

function fakeLifecycleBackend() {
	const calls = [];
	const starts = [];
	const stops = [];
	const aborts = [];
	const cleanups = [];
	let wakeStart = null;
	let wakeStop = null;

	return {
		calls,
		starts,
		stops,
		aborts,
		cleanups,
		onStart(handler) {
			wakeStart = handler;
		},
		onStop(handler) {
			wakeStop = handler;
		},
		backend: {
			startVM(params) {
				calls.push('start:' + params.tag);
				const gate = deferred();
				starts.push(gate);
				if (wakeStart) {
					const wake = wakeStart;
					wakeStart = null;
					wake();
				}
				return gate.promise;
			},
			stopVM() {
				calls.push('stop');
				const gate = deferred();
				stops.push(gate);
				if (wakeStop) {
					const wake = wakeStop;
					wakeStop = null;
					wake();
				}
				return gate.promise;
			},
			requestStop() {
				aborts.push('request');
			},
			forceCleanup() {
				cleanups.push('force');
			},
			isRunning() {
				return { running: true };
			},
		},
	};
}

async function shutdownSuite() {
	process.env.COWORK_VM_BACKEND = 'host';
	const { VMManager } = require(SERVICE);

	const manager = new VMManager();
	manager.shutdownTimeout = 500;
	const fake = fakeLifecycleBackend();
	manager.backend = fake.backend;

	const startedA = deferred();
	fake.onStart(startedA.resolve);
	const startA = manager.startVM({ tag: 'a' });
	const startAOutcome = startA.then(() => null, (e) => e);
	await startedA.promise;

	const startB = manager.startVM({ tag: 'b' });
	const startBOutcome = startB.then(() => null, (e) => e);
	await flush();
	assertDeepEqual(fake.calls, ['start:a'], 'shutdown: start b queued');

	const stopStarted = deferred();
	fake.onStop(stopStarted.resolve);
	const shutdown = manager.shutdown();
	await withDeadline(stopStarted.promise, 1000,
		'shutdown: stop called during startup');
	assertDeepEqual(fake.calls, ['start:a', 'stop'],
		'shutdown: stop runs before queued start');
	assertEqual(fake.aborts.length, 1, 'shutdown: startup aborted');

	const after = manager.startVM({ tag: 'after' });
	const afterOutcome = after.then(() => null, (e) => e);
	assertEqual((await afterOutcome).message, 'Shutting down',
		'shutdown: new start rejected');
	assertEqual((await startAOutcome).message, 'Shutting down',
		'shutdown: active start rejected');
	assertEqual((await startBOutcome).message, 'Shutting down',
		'shutdown: queued start rejected');

	fake.starts[0].resolve({});
	await flush();
	assertDeepEqual(fake.calls, ['start:a', 'stop'],
		'shutdown: queued start never runs after stop');
	fake.stops[0].resolve({});
	await withDeadline(shutdown, 2000, 'shutdown: completes');
	assertDeepEqual(fake.calls, ['start:a', 'stop'],
		'shutdown: one final stop');
	assertDeepEqual(fake.cleanups, [],
		'shutdown: completed stop needs no forced cleanup');

	const stopManager = new VMManager();
	stopManager.shutdownTimeout = 500;
	const stopFake = fakeLifecycleBackend();
	stopManager.backend = stopFake.backend;
	const activeStop = deferred();
	stopFake.onStop(activeStop.resolve);
	const stopCall = stopManager.stopVM();
	const stopOutcome = stopCall.then(() => null, (e) => e);
	await withDeadline(activeStop.promise, 1000,
		'shutdown: active stop began');
	const stopShutdown = stopManager.shutdown();
	await flush();
	assertDeepEqual(stopFake.calls, ['stop'],
		'shutdown: reuses active stop');
	assertEqual((await stopOutcome).message, 'Shutting down',
		'shutdown: active stop rpc rejected');
	stopFake.stops[0].resolve({});
	await withDeadline(stopShutdown, 2000,
		'shutdown: active stop settles');
	assertDeepEqual(stopFake.calls, ['stop'],
		'shutdown: no second stop');

	const timeoutManager = new VMManager();
	timeoutManager.shutdownTimeout = 100;
	const timeoutFake = fakeLifecycleBackend();
	timeoutManager.backend = timeoutFake.backend;
	const timeoutStop = deferred();
	timeoutFake.onStop(timeoutStop.resolve);
	const timeoutShutdown = timeoutManager.shutdown();
	await withDeadline(timeoutStop.promise, 1000,
		'shutdown: timeout stop began');
	await withDeadline(timeoutShutdown, 2000,
		'shutdown: bounded stop wait');
	assertDeepEqual(timeoutFake.calls, ['stop'],
		'shutdown: timeout still stops');
	assertDeepEqual(timeoutFake.cleanups, ['force'],
		'shutdown: deadline forces cleanup before returning');

	const abortManager = new VMManager();
	const abortFake = fakeLifecycleBackend();
	abortManager.backend = abortFake.backend;
	const startedD = deferred();
	abortFake.onStart(startedD.resolve);
	const startD = abortManager.startVM({ tag: 'd' });
	const startDOutcome = startD.then(() => null, (e) => e);
	await startedD.promise;
	const startE = abortManager.startVM({ tag: 'e' });
	const startEOutcome = startE.then(() => null, (e) => e);
	await flush();
	const stopDStarted = deferred();
	abortFake.onStop(stopDStarted.resolve);
	const stopD = abortManager.stopVM();
	assertEqual((await startDOutcome).message, 'VM stop requested',
		'stop: active start aborted');
	assertEqual((await startEOutcome).message, 'VM stop requested',
		'stop: queued start cancelled');
	assertEqual(abortFake.aborts.length, 1,
		'stop: backend abort requested');
	abortFake.starts[0].resolve({});
	await withDeadline(stopDStarted.promise, 1000,
		'stop: stop runs after start settles');
	assertDeepEqual(abortFake.calls, ['start:d', 'stop'],
		'stop: aborted start never overlaps stop');
	abortFake.stops[0].resolve({});
	await withDeadline(stopD, 2000, 'stop: completes');
}

(async () => {
	switch (MODE) {
	case 'host':
		await localBackendSuite('host');
		break;
	case 'bwrap':
		await localBackendSuite('bwrap');
		break;
	case 'kvm':
		await kvmSuite();
		break;
	case 'guestbridge':
		await guestForwardingDisabledSuite();
		break;
	case 'framing':
		await framingSuite();
		break;
	case 'concurrency':
		await concurrencySuite();
		break;
	case 'lifecycle':
		await lifecycleSuite();
		break;
	case 'qmp':
		await qmpSuite();
		break;
	case 'guestwait':
		await guestWaitSuite();
		break;
	case 'kvmcancel':
		await kvmCancelSuite();
		break;
	case 'forcecleanup':
		await forceCleanupSuite();
		break;
	case 'shutdown':
		await shutdownSuite();
		break;
	default:
		fail('unknown mode: ' + MODE);
	}
})().catch((e) => {
	fail(e && e.stack ? e.stack : String(e));
});
NODE
	fi
}

@test "host backend: session disk, memory, network, unknown, EDR" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" host
	[[ "$status" -eq 0 ]]
}

@test "bwrap backend: session disk, memory, network, unknown, EDR" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" bwrap
	[[ "$status" -eq 0 ]]
}

@test "kvm backend: unverified guest RPCs fail explicitly" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" kvm
	[[ "$status" -eq 0 ]]
}

@test "kvm guest forwarding: disabled and explicit" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" guestbridge
	[[ "$status" -eq 0 ]]
}

@test "framing: split frames, batched frames, request id echo" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" framing
	[[ "$status" -eq 0 ]]
}

@test "concurrency: startVM does not block a later request" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" concurrency
	[[ "$status" -eq 0 ]]
}

@test "lifecycle: start and stop are serialized per VM" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" lifecycle
	[[ "$status" -eq 0 ]]
}

@test "qmp: connect is deadline-bound and cancellable" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" qmp
	[[ "$status" -eq 0 ]]
}

@test "guest wait: readiness wait is cancellable" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" guestwait
	[[ "$status" -eq 0 ]]
}

@test "kvm cancel: stop during virtiofsd wait spawns no QEMU" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" kvmcancel
	[[ "$status" -eq 0 ]]
}

@test "force cleanup: reclaims owned processes and session" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" forcecleanup
	[[ "$status" -eq 0 ]]
}

@test "shutdown: rejects starts and keeps one final stop" {
	run env TEST_ROOT="$TEST_ROOT" SERVICE_PATH="$SERVICE_PATH" \
		HARNESS="$HARNESS" node "$HARNESS" shutdown
	[[ "$status" -eq 0 ]]
}
