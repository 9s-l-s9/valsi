// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { AAPClient, aapConnection } from "../aap-client.mjs";

function fakeProcess(onWrite = () => {}) {
	const child = new EventEmitter();
	child.exitCode = null;
	child.stdout = new EventEmitter();
	child.stdout.setEncoding = () => {};
	child.stderr = new EventEmitter();
	child.stderr.setEncoding = () => {};
	child.stdin = {
		write(record, _encoding, callback) {
			onWrite(record, child);
			callback();
		},
		end() {},
	};
	child.signalCode = null;
	child.kills = [];
	child.kill = (signal) => {
		child.kills.push(signal);
		child.signalCode = signal;
		child.emit("exit", null, signal);
	};
	return child;
}

test("AAP responses correlate out of order and Unicode separators are data", async () => {
	const child = fakeProcess();
	const client = new AAPClient("unused", [], { spawn: () => child });
	const first = client.request("one");
	const second = client.request("two");
	child.stdout.emit(
		"data",
		`{"jsonrpc":"2.0","id":"pi-2","result":"b\u2028c\u2029d"}\n{"jsonrpc":"2.0","id":"pi-1","result":`,
	);
	child.stdout.emit("data", '"a"}\n');
	assert.equal(await first, "a");
	assert.equal(await second, "b\u2028c\u2029d");
});

test("AAP JSON-RPC errors surface", async () => {
	const child = fakeProcess((_record, process) => {
		queueMicrotask(() =>
			process.stdout.emit(
				"data",
				'{"jsonrpc":"2.0","id":"pi-1","error":{"code":-32601,"message":"no"}}\n',
			),
		);
	});
	const client = new AAPClient("unused", [], { spawn: () => child });
	await assert.rejects(client.request("missing"), /AAP -32601: no/);
});

test("malformed output, CRLF, exit, abort, and timeout reject without hanging", async () => {
	for (const output of ["{bad}\n", '{"id":"pi-1","result":1}\r\n']) {
		const child = fakeProcess((_record, process) => {
			queueMicrotask(() => process.stdout.emit("data", output));
		});
		const client = new AAPClient("unused", [], { spawn: () => child });
		await assert.rejects(client.request("x"), /malformed JSON|strict LF/);
	}
	{
		const child = fakeProcess();
		const client = new AAPClient("unused", [], { spawn: () => child });
		const pending = client.request("x");
		child.emit("exit", 7, null);
		await assert.rejects(pending, /exited \(7\)/);
	}
	{
		const child = fakeProcess();
		const controller = new AbortController();
		const client = new AAPClient("unused", [], { spawn: () => child });
		const pending = client.request("x", {}, controller.signal);
		controller.abort(new Error("stop"));
		await assert.rejects(pending, /stop/);
	}
	{
		const child = fakeProcess();
		const client = new AAPClient("unused", [], {
			spawn: () => child,
			timeoutMs: 5,
		});
		await assert.rejects(client.request("x"), /timed out/);
	}
});

test("a connection respawns the client after the server exits or fails to spawn", async () => {
	const children = [];
	const connection = aapConnection(
		() =>
			new AAPClient("unused", [], {
				spawn: () => {
					const child = fakeProcess();
					children.push(child);
					return child;
				},
			}),
	);
	const first = connection();
	assert.equal(connection(), first);
	children[0].emit("exit", 3, null);
	assert.equal(first.running, false);
	await assert.rejects(first.request("x"), /not running/);
	const second = connection();
	assert.notEqual(second, first);
	assert.equal(second.running, true);
	children[1].emit("error", new Error("spawn emacs ENOENT"));
	const third = connection();
	assert.notEqual(third, second);
	assert.equal(children.length, 3);
	connection.close();
	assert.equal(third.running, false);
});

test("a pre-aborted signal rejects at once and settled requests detach their listener", async () => {
	let writes = 0;
	const child = fakeProcess((record, process) => {
		writes++;
		const { id } = JSON.parse(record);
		queueMicrotask(() =>
			process.stdout.emit("data", `{"jsonrpc":"2.0","id":"${id}","result":1}\n`),
		);
	});
	const client = new AAPClient("unused", [], { spawn: () => child });
	const aborted = new AbortController();
	aborted.abort(new Error("pre-aborted"));
	await assert.rejects(client.request("x", {}, aborted.signal), /pre-aborted/);
	assert.equal(writes, 0);
	assert.equal(client.pending.size, 0);

	const live = new AbortController();
	const added = [];
	const removed = [];
	live.signal.addEventListener = (type, listener) => added.push([type, listener]);
	live.signal.removeEventListener = (type, listener) =>
		removed.push([type, listener]);
	assert.equal(await client.request("y", {}, live.signal), 1);
	assert.deepEqual(removed, added);
});

test("issue #80: a timed-out request kills the wedged server", async () => {
	const child = fakeProcess();
	const client = new AAPClient("unused", [], {
		spawn: () => child,
		timeoutMs: 5,
	});
	const first = client.request("x");
	const queued = client.request("queued");
	await assert.rejects(first, /timed out/);
	await assert.rejects(queued, /exited \(SIGKILL\)/);
	assert.deepEqual(child.kills, ["SIGKILL"]);
	assert.equal(client.running, false);
});

test("issue #80: close() kills a server that ignores EOF after the grace period", async () => {
	const child = fakeProcess();
	let ended = false;
	child.stdin.end = () => {
		ended = true;
	};
	const client = new AAPClient("unused", [], {
		spawn: () => child,
		closeGraceMs: 10,
	});
	client.close();
	assert.equal(ended, true);
	assert.deepEqual(child.kills, []);
	await new Promise((resolve) => setTimeout(resolve, 40));
	assert.deepEqual(child.kills, ["SIGKILL"]);

	// A server that exits on EOF is not killed.
	const polite = fakeProcess();
	polite.stdin.end = () => {
		polite.exitCode = 0;
		polite.emit("exit", 0, null);
	};
	new AAPClient("unused", [], { spawn: () => polite, closeGraceMs: 10 }).close();
	await new Promise((resolve) => setTimeout(resolve, 40));
	assert.deepEqual(polite.kills, []);
});

function documentClient() {
	const documents = new Map();
	const calls = [];
	const child = fakeProcess((record, process) => {
		const { id, method, params } = JSON.parse(record);
		calls.push([method, params.uri, params.text]);
		if (method === "artifact/didOpen") documents.set(params.uri, params.text);
		if (method === "artifact/didClose") documents.delete(params.uri);
		queueMicrotask(() => process.stdout.emit("data",
			JSON.stringify({ id, result: documents.get(params.uri) ?? null }) + "\n"));
	});
	const client = new AAPClient("unused", [], { spawn: () => child });
	return { client, child, documents, calls };
}

test("temporary documents close on success, query failure, and cancellation", async () => {
	for (const mode of ["success", "failure", "abort"]) {
		const { client, documents, calls } = documentClient();
		const controller = new AbortController();
		const operation = client.withDocument("PLAN.md", "plan", async (aap) => {
			if (mode === "failure") throw new Error("query failed");
			if (mode === "abort") controller.abort(new Error("cancel query"));
			return aap.request("artifact/symbols", { uri: "PLAN.md" }, controller.signal);
		}, controller.signal);
		if (mode === "success") assert.equal(await operation, "plan");
		else await assert.rejects(operation, /query failed|cancel query/);
		assert.equal(documents.size, 0);
		assert.equal(client.documents.size, 0);
		assert.equal(calls.at(-1)[0], "artifact/didClose");
		assert.equal(client.pending.size, 0);
	}
});

test("same-path calls serialize their own snapshots; other paths remain independent", async () => {
	const { client, documents } = documentClient();
	let finish;
	let entered;
	const ready = new Promise(resolve => { entered = resolve; });
	const first = client.withDocument("PLAN.md", "first", () => {
		entered();
		return new Promise(resolve => { finish = resolve; });
	});
	await ready;
	const second = client.withDocument("PLAN.md", "second",
		aap => aap.request("artifact/symbols", { uri: "PLAN.md" }));
	assert.equal(await client.withDocument("OTHER.md", "other",
		aap => aap.request("artifact/symbols", { uri: "OTHER.md" })), "other");
	assert.equal(documents.get("PLAN.md"), "first");
	finish("first query");
	assert.equal(await first, "first query");
	assert.equal(await second, "second");
	assert.equal(documents.size, 0);
	assert.equal(client.documents.size, 0);
});

test("a cancelled queued query never opens its document", async () => {
	const { client, calls } = documentClient();
	let finish;
	let entered;
	const ready = new Promise(resolve => { entered = resolve; });
	const first = client.withDocument("PLAN.md", "first", () => {
		entered(); return new Promise(resolve => { finish = resolve; });
	});
	await ready;
	const controller = new AbortController();
	const second = client.withDocument("PLAN.md", "cancelled", () => assert.fail(), controller.signal);
	controller.abort(new Error("cancel queued"));
	const rejected = assert.rejects(second, /cancel queued/);
	finish();
	await Promise.all([first, rejected]);
	assert.equal(calls.filter(([method]) => method === "artifact/didOpen").length, 1);
	assert.equal(client.documents.size, 0);
});

test("failed cleanup retires the server and preserves the original query error", async () => {
	const { client } = documentClient();
	const request = client.request.bind(client);
	client.request = (method, ...args) => method === "artifact/didClose"
		? Promise.reject(new Error("close failed")) : request(method, ...args);
	await assert.rejects(client.withDocument("PLAN.md", "text", () => {
		throw new Error("original query failure");
	}), /original query failure/);
	assert.equal(client.running, false);
	assert.equal(client.documents.size, 0);
});

test("cancelling didOpen still closes the document that reached the server", async () => {
	const controller = new AbortController();
	const documents = new Map();
	const child = fakeProcess((record, process) => {
		const { id, method, params } = JSON.parse(record);
		if (method === "artifact/didOpen") {
			documents.set(params.uri, params.text);
			queueMicrotask(() => controller.abort(new Error("cancel open")));
		} else if (method === "artifact/didClose") {
			documents.delete(params.uri);
			queueMicrotask(() => process.stdout.emit("data", JSON.stringify({ id, result: null }) + "\n"));
		}
	});
	const client = new AAPClient("unused", [], { spawn: () => child });
	await assert.rejects(client.withDocument("PLAN.md", "text", () => assert.fail(), controller.signal), /cancel open/);
	assert.equal(documents.size, 0);
	assert.equal(client.pending.size, 0);
	assert.equal(client.documents.size, 0);
});
