// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { AAPClient } from "../aap-client.mjs";

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
