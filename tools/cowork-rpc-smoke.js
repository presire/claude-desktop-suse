#!/usr/bin/env node
/**
 * @file cowork-rpc-smoke.js
 * @brief Synthetic RPC smoke run against scripts/cowork-vm-service.js
 *
 * Starts the Cowork daemon with the host backend inside a throwaway
 * HOME / XDG_* tree, drives the RPCs that work without KVM or bwrap,
 * then stops it with SIGTERM so the daemon's own shutdown path runs
 * and NODE_V8_COVERAGE (set by c8) is flushed on process.exit(0).
 * SIGKILL is only the fallback when the daemon misses the deadline,
 * and that case fails the run because coverage would be lost.
 *
 * The child gets an allowlisted environment, so no token, credential
 * or real user directory reaches it. The temporary tree is removed and
 * the daemon is reaped on every path: spawn failure, a broken socket or
 * frame, a missed deadline, and SIGTERM/SIGINT/SIGHUP sent to the smoke.
 *
 * Usage: node tools/cowork-rpc-smoke.js [service.js]
 * Env:   COWORK_RPC_SMOKE_TERM_TIMEOUT_MS  SIGTERM deadline (default 15000)
 */
'use strict';

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const SERVICE = path.resolve(process.argv[2]
    || path.join(__dirname, '..', 'scripts', 'cowork-vm-service.js'));
const TERM_TIMEOUT_MS = Number(process.env.COWORK_RPC_SMOKE_TERM_TIMEOUT_MS)
    || 15000;
const START_TIMEOUT_MS = 10000;
const REPLY_TIMEOUT_MS = 5000;
const EVENT_TIMEOUT_MS = 10000;
const REAP_TIMEOUT_MS = 5000;
const PREFIX = '[cowork-rpc-smoke]';

// Only what node and the daemon need. NODE_V8_COVERAGE carries the c8
// coverage directory into the child; everything else is synthetic.
const PASSTHROUGH_ENV = ['PATH', 'NODE_V8_COVERAGE', 'LANG', 'TZ'];

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function checkEqual(actual, expected, message) {
    check(actual === expected, `${message}: expected ${JSON.stringify(expected)}`
        + `, got ${JSON.stringify(actual)}`);
}

function checkNumber(value, message) {
    check(typeof value === 'number' && Number.isFinite(value),
        `${message}: expected a finite number, got ${JSON.stringify(value)}`);
}

// What a parent signal has to clean up; set as soon as each exists.
const active = { root: null, daemon: null };

function sandboxLayout(root) {
    const home = path.join(root, 'home');
    return {
        root,
        home,
        runtime: path.join(root, 'runtime'),
        config: path.join(home, '.config'),
        cache: path.join(home, '.cache'),
        data: path.join(home, '.local', 'share'),
        state: path.join(home, '.local', 'state'),
    };
}

function createSandbox(dirs) {
    for (const key of ['runtime', 'config', 'cache', 'data', 'state']) {
        fs.mkdirSync(dirs[key], { recursive: true, mode: 0o700 });
    }
}

function removeSandbox() {
    if (active.root) fs.rmSync(active.root, { recursive: true, force: true });
    active.root = null;
}

// A smoke stopped from outside must not leave the daemon or the tree
// behind. SIGKILL is enough here: the run is already a failure. The
// smoke exits only after the daemon is reaped, or after the deadline.
function onParentSignal(signal) {
    const finish = () => {
        removeSandbox();
        process.stderr.write(`${PREFIX} FAIL: interrupted by ${signal}\n`);
        process.exit(128 + os.constants.signals[signal]);
    };
    const daemon = active.daemon;
    if (!daemon || daemon.state.exit) {
        finish();
        return;
    }
    daemon.child.kill('SIGKILL');
    const timer = setTimeout(finish, REAP_TIMEOUT_MS);
    daemon.exited.then(() => {
        clearTimeout(timer);
        finish();
    });
}

function childEnv(dirs) {
    const env = {};
    for (const name of PASSTHROUGH_ENV) {
        if (process.env[name] !== undefined) env[name] = process.env[name];
    }
    return Object.assign(env, {
        HOME: dirs.home,
        TMPDIR: dirs.root,
        XDG_RUNTIME_DIR: dirs.runtime,
        XDG_CONFIG_HOME: dirs.config,
        XDG_CACHE_HOME: dirs.cache,
        XDG_DATA_HOME: dirs.data,
        XDG_STATE_HOME: dirs.state,
        COWORK_VM_BACKEND: 'host',
        COWORK_VM_VIRTIOFSD_BIN: '/nonexistent',
    });
}

function startDaemon(dirs) {
    const child = spawn(process.execPath, [SERVICE], {
        cwd: dirs.root,
        env: childEnv(dirs),
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    const state = { stdout: '', stderr: '', exit: null };
    const exited = new Promise((resolve) => {
        const finish = (exit) => {
            if (state.exit) return;
            state.exit = exit;
            resolve(exit);
        };
        child.on('exit', (code, signal) => finish({ code, signal }));
        // A failed spawn emits 'error' without 'exit'.
        child.on('error', (e) => {
            if (child.pid === undefined) {
                finish({ code: null, signal: null, error: e.message });
            }
        });
    });
    child.stdout.on('data', (data) => { state.stdout += data.toString(); });
    child.stderr.on('data', (data) => { state.stderr += data.toString(); });

    const socketPath = new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            reject(new Error(`daemon did not listen within ${START_TIMEOUT_MS}ms`));
        }, START_TIMEOUT_MS);
        const onData = () => {
            const match = state.stdout.match(/Service started on (\S+)/);
            if (match) {
                clearTimeout(timer);
                child.stdout.off('data', onData);
                resolve(match[1]);
            }
        };
        child.stdout.on('data', onData);
        exited.then((exit) => {
            clearTimeout(timer);
            reject(new Error(`daemon exited early: ${JSON.stringify(exit)}`
                + ` stderr=${state.stderr.trim()}`));
        });
    });

    return { child, state, exited, socketPath };
}

// Sends SIGTERM and waits for the daemon's own shutdown. A daemon that
// misses the deadline is SIGKILLed so the run never hangs, and the
// result is marked as forced so the caller can fail. The wait after
// SIGKILL is bounded too and reported as unreaped.
function stopDaemon(daemon) {
    if (daemon.state.exit) {
        return Promise.resolve({ ...daemon.state.exit, forced: false });
    }
    daemon.child.kill('SIGTERM');
    return new Promise((resolve) => {
        let forced = false;
        let reapTimer = null;
        const termTimer = setTimeout(() => {
            forced = true;
            daemon.child.kill('SIGKILL');
            // An unreaped child keeps its pipes open; drop them and the
            // child handle so this process can still exit.
            reapTimer = setTimeout(() => {
                daemon.child.stdout.destroy();
                daemon.child.stderr.destroy();
                daemon.child.unref();
                resolve({ code: null, signal: null, forced, unreaped: true });
            }, REAP_TIMEOUT_MS);
        }, TERM_TIMEOUT_MS);
        // A single exit handler: when the deadline already fired, the
        // SIGKILL is what ended the daemon and the run must report it.
        daemon.exited.then((exit) => {
            clearTimeout(termTimer);
            clearTimeout(reapTimer);
            resolve({ ...exit, forced });
        });
    });
}

function connect(socketPath) {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection(socketPath, () => {
            socket.off('error', reject);
            resolve(socket);
        });
        socket.once('error', reject);
    });
}

function frame(message) {
    const body = Buffer.from(JSON.stringify(message));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length, 0);
    return Buffer.concat([header, body]);
}

// Replies carry the request id; events do not. Each waiter is keyed by
// what it expects, so an event cannot be mistaken for a reply. Events
// are kept from subscribeEvents on, so a wait started late still sees
// one that already arrived. A socket error, an early close or a frame
// that is not JSON rejects every pending wait instead of throwing out
// of the data handler.
function makeClient(socket) {
    let buffer = Buffer.alloc(0);
    let nextId = 1;
    let broken = null;
    const replies = new Map();
    const events = [];
    const eventWaiters = [];

    function fail(error) {
        if (broken) return;
        broken = error;
        for (const waiter of [...replies.values(), ...eventWaiters]) {
            clearTimeout(waiter.timer);
            waiter.reject(error);
        }
        replies.clear();
        eventWaiters.length = 0;
        socket.destroy();
    }

    socket.on('error', (e) => fail(new Error(`daemon socket error: ${e.message}`)));
    socket.on('close', () => fail(new Error('daemon closed the connection')));
    socket.on('data', (data) => {
        if (broken) return;
        buffer = Buffer.concat([buffer, data]);
        while (buffer.length >= 4) {
            const length = buffer.readUInt32BE(0);
            if (buffer.length < 4 + length) break;
            let message;
            try {
                message = JSON.parse(buffer.subarray(4, 4 + length).toString());
            } catch (e) {
                fail(new Error(`daemon sent a frame that is not JSON: ${e.message}`));
                return;
            }
            if (message === null || typeof message !== 'object' || Array.isArray(message)) {
                fail(new Error(`daemon sent a frame that is not an object: ${JSON.stringify(message)}`));
                return;
            }
            buffer = buffer.subarray(4 + length);
            if (message.id !== undefined && replies.has(message.id)) {
                const waiter = replies.get(message.id);
                replies.delete(message.id);
                clearTimeout(waiter.timer);
                waiter.resolve(message);
                continue;
            }
            events.push(message);
            for (const waiter of eventWaiters.slice()) {
                if (waiter.match(message)) {
                    eventWaiters.splice(eventWaiters.indexOf(waiter), 1);
                    clearTimeout(waiter.timer);
                    waiter.resolve(message);
                }
            }
        }
    });

    return {
        call(method, params) {
            if (broken) return Promise.reject(broken);
            const id = nextId++;
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    replies.delete(id);
                    reject(new Error(`${method}: no reply within ${REPLY_TIMEOUT_MS}ms`));
                }, REPLY_TIMEOUT_MS);
                replies.set(id, { resolve, reject, timer });
                socket.write(frame({ id, method, params: params || {} }));
            });
        },
        // Await it right away: the deadline starts when this is called.
        waitForEvent(match, label) {
            const seen = events.find(match);
            if (seen) return Promise.resolve(seen);
            if (broken) return Promise.reject(broken);
            return new Promise((resolve, reject) => {
                const waiter = { match, resolve, reject, timer: null };
                waiter.timer = setTimeout(() => {
                    eventWaiters.splice(eventWaiters.indexOf(waiter), 1);
                    reject(new Error(`${label}: no event within ${EVENT_TIMEOUT_MS}ms`));
                }, EVENT_TIMEOUT_MS);
                eventWaiters.push(waiter);
            });
        },
    };
}

async function expectOk(client, method, params) {
    const reply = await client.call(method, params);
    checkEqual(reply.success, true, `${method}: success (error=${reply.error})`);
    return reply.result;
}

async function expectError(client, method, params, error) {
    const reply = await client.call(method, params);
    checkEqual(reply.success, false, `${method}: success`);
    checkEqual(reply.error, error, `${method}: error text`);
}

async function exercise(client, dirs) {
    checkEqual(JSON.stringify(await expectOk(client, 'configure',
        { memoryMB: 1024, cpuCount: 1 })), '{}', 'configure result');
    await expectOk(client, 'setDebugLogging', { enabled: false });
    await expectOk(client, 'createVM', { bundlePath: path.join(dirs.root, 'bundle') });

    checkEqual((await expectOk(client, 'isRunning')).running, false,
        'isRunning before start');
    checkEqual((await expectOk(client, 'isGuestConnected')).connected, false,
        'isGuestConnected before start');

    const memory = await expectOk(client, 'getMemoryInfo');
    checkNumber(memory.totalBytes, 'getMemoryInfo totalBytes');
    checkNumber(memory.freeBytes, 'getMemoryInfo freeBytes');
    checkNumber(memory.availableBytes, 'getMemoryInfo availableBytes');

    const disk = await expectOk(client, 'getSessionsDiskInfo', { lowWaterBytes: 0 });
    checkNumber(disk.totalBytes, 'getSessionsDiskInfo totalBytes');
    checkNumber(disk.freeBytes, 'getSessionsDiskInfo freeBytes');
    checkEqual(JSON.stringify(disk.sessions), '[]', 'getSessionsDiskInfo sessions');

    checkEqual(JSON.stringify(await expectOk(client, 'deleteSessionDirs',
        { sessionNames: ['missing'] })), '{"deleted":[],"errors":{}}',
        'deleteSessionDirs result');
    checkEqual((await expectOk(client, 'pruneSessionCaches',
        { onlyIfFreeBytesBelow: 1 })).freedBytes, 0, 'pruneSessionCaches freedBytes');
    checkEqual(JSON.stringify((await expectOk(client, 'getNetworkDrives')).drives),
        '[]', 'getNetworkDrives drives');
    await expectOk(client, 'sendGuestResponse', { id: 'smoke-1', resultJson: '{}' });

    await expectError(client, 'getHostMemory', {}, 'unknown method: getHostMemory');
    await expectError(client, 'refreshGuestProxy', {}, 'unknown method: refreshGuestProxy');
    await expectError(client, 'runEdrExtension', { extensionId: 'smoke' },
        'handler not registered: runEdrExtension');

    await expectOk(client, 'subscribeEvents');
    await expectOk(client, 'startVM', {});
    checkEqual((await expectOk(client, 'isRunning')).running, true,
        'isRunning after start');
    // The event is buffered since subscribeEvents, so its deadline only
    // has to cover the backend's own delay, not the RPCs before it.
    await client.waitForEvent(
        (event) => event.type === 'networkStatus' && event.status === 'connected',
        'networkStatus connected');
    checkEqual((await expectOk(client, 'isGuestConnected')).connected, true,
        'isGuestConnected after start');
    await expectOk(client, 'stopVM');
    checkEqual((await expectOk(client, 'isRunning')).running, false,
        'isRunning after stop');
}

async function main() {
    check(fs.existsSync(SERVICE), `service not found: ${SERVICE}`);
    for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
        process.once(signal, onParentSignal);
    }
    active.root = fs.mkdtempSync(
        path.join(os.tmpdir(), 'claude-desktop-suse-cowork-smoke-'));
    const dirs = sandboxLayout(active.root);
    const expectedSocket = path.join(dirs.runtime, 'cowork-vm-service.sock');
    const logFile = path.join(dirs.home, '.config', 'Claude', 'logs',
        'cowork_vm_daemon.log');
    const failures = [];
    let daemon = null;
    let socket = null;
    let exit = null;

    try {
        try {
            createSandbox(dirs);
            daemon = startDaemon(dirs);
            active.daemon = daemon;
            const socketPath = await daemon.socketPath;
            checkEqual(socketPath, expectedSocket, 'socket path');
            socket = await connect(socketPath);
            await exercise(makeClient(socket), dirs);
        } catch (e) {
            failures.push(e.message);
        } finally {
            if (socket) socket.destroy();
            if (daemon) exit = await stopDaemon(daemon);
        }

        if (exit) {
            const after = [
                [!exit.error, `daemon could not be spawned: ${exit.error}`],
                [!exit.unreaped, `daemon was not reaped ${REAP_TIMEOUT_MS}ms after SIGKILL`],
                [!exit.forced, `daemon ignored SIGTERM for ${TERM_TIMEOUT_MS}ms; sent SIGKILL`],
            ];
            for (const [ok, message] of after) {
                if (!ok) failures.push(message);
            }
            try {
                checkEqual(exit.signal, null, 'daemon exit signal');
                checkEqual(exit.code, 0, 'daemon exit code');
                check(!fs.existsSync(expectedSocket), `socket left behind: ${expectedSocket}`);
                const lifecycle = fs.existsSync(logFile)
                    ? fs.readFileSync(logFile, 'utf8') : '';
                check(lifecycle.includes('SIGTERM received'),
                    'daemon log in the sandbox HOME has no "SIGTERM received" entry');
            } catch (e) {
                failures.push(e.message);
            }
        }
    } finally {
        removeSandbox();
    }

    const result = {
        ok: failures.length === 0,
        service: SERVICE,
        sandbox: dirs.root,
        exit,
        failures,
    };
    process.stdout.write(`${PREFIX} ${JSON.stringify(result)}\n`);
    if (failures.length) {
        for (const failure of failures) process.stderr.write(`${PREFIX} FAIL: ${failure}\n`);
        if (daemon && daemon.state.stderr.trim()) {
            process.stderr.write(`${PREFIX} daemon stderr:\n${daemon.state.stderr}`);
        }
        process.exitCode = 1;
    }
}

main().catch((e) => {
    process.stderr.write(`${PREFIX} FAIL: ${e.stack || e.message}\n`);
    process.exitCode = 1;
});
