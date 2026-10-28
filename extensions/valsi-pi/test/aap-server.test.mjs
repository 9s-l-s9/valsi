// SPDX-License-Identifier: GPL-3.0-or-later

// End-to-end tests against the REAL headless Emacs server, spawned with
// Node's default `child_process.spawn' exactly as aap.ts does.  Skipped when
// no Emacs is available.

import assert from "node:assert/strict";
import { accessSync, constants } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { AAPClient } from "../aap-client.mjs";

const lispDirectory = resolve(
	dirname(fileURLToPath(import.meta.url)),
	"../../../lisp",
);

function executable(file) {
	try {
		accessSync(file, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

function findEmacs() {
	for (const candidate of [process.env.Valsi_AAP_EMACS, process.env.EMACS]) {
		if (!candidate || candidate === "t") continue;
		if (candidate.includes("/")) {
			if (executable(candidate)) return candidate;
			continue;
		}
		for (const dir of (process.env.PATH ?? "").split(delimiter)) {
			if (dir && executable(join(dir, candidate))) return join(dir, candidate);
		}
	}
	for (const dir of (process.env.PATH ?? "").split(delimiter)) {
		if (dir && executable(join(dir, "emacs"))) return join(dir, "emacs");
	}
	return undefined;
}

const emacs = findEmacs();
const skip = emacs ? false : "no emacs found";

function realServer(options = {}) {
	return new AAPClient(
		emacs,
		[
			"-Q",
			"--batch",
			"--eval",
			"(setq load-prefer-newer t)",
			"-L",
			lispDirectory,
			"-l",
			"valsi-server",
			"-f",
			"valsi-server-stdio",
		],
		{ timeoutMs: 30_000, ...options },
	);
}

test("issue #78: the real server answers a client spawned with a socketpair stdin", { skip }, async () => {
	const client = realServer();
	try {
		const init = await client.request("initialize");
		assert.ok(init.capabilities.includes("artifact/didOpen"));
		const opened = await client.request("artifact/didOpen", {
			uri: "PLAN.md",
			text: "# Plan\n\n- [ ] T1 first\n",
		});
		assert.equal(opened.uri, "PLAN.md");
		assert.equal(opened.version, 1);
	} finally {
		client.close();
	}
});

test("issue #80: the real server rejects a catastrophic regexp and stays responsive", { skip }, async () => {
	const client = realServer({ timeoutMs: 15_000 });
	try {
		await assert.rejects(
			client.request("grammar/register", {
				spec: {
					id: "evil",
					match: { textRegexp: "\\(a*\\)*b", score: 1000 },
					recognizers: [{ type: "x", regexp: "^x" }],
				},
			}),
			/AAP -32602/,
		);
		const opened = await client.request("artifact/didOpen", {
			uri: "f.md",
			text: `${"a".repeat(40)}\n`,
		});
		assert.notEqual(opened.grammar, "evil");
		assert.ok((await client.request("initialize")).capabilities.length > 0);
	} finally {
		client.close();
	}
});

test("issue #81: grammar/register re-syncs every open document and reports failures", { skip }, async () => {
	const client = realServer();
	const spec = (id, uriSuffix) => ({
		id,
		match: { uriSuffix, score: 50 },
		recognizers: [{ type: "x", regexp: "^\\(ab\\)*$" }],
		capabilities: ["so-cap"],
	});
	try {
		// The issue's repro: before #80 the long line overflowed the regexp
		// stack and aborted the re-sync, leaving zz.so stale.
		for (const [uri, text] of [
			["aa.so", "hi\n"],
			["big.so", `${"ab".repeat(400_000)}\n`],
			["zz.so", "hi\n"],
		]) {
			await client.request("artifact/didOpen", { uri, text });
		}
		const registered = await client.request("grammar/register", {
			spec: spec("so", ".so"),
		});
		assert.deepEqual(registered, { id: "so", failed: [] });
		for (const uri of ["aa.so", "big.so", "zz.so"]) {
			const caps = await client.request("artifact/capabilities", { uri });
			assert.deepEqual(caps.capabilities, ["so-cap"], uri);
		}
		const again = await client.request("grammar/register", {
			spec: spec("unrelated", ".zzz"),
		});
		assert.deepEqual(again, { id: "unrelated", failed: [] });
	} finally {
		client.close();
	}
});

test("issue #79: the real server round-trips non-ASCII text in any locale", { skip }, async () => {
	const uri = "caf\u00e9-\u{1F600}-\u2028.md";
	for (const env of [process.env, { ...process.env, LC_ALL: "C", LANG: "C" }]) {
		const client = realServer({ env });
		let raw = "";
		client.child.stdout.on("data", (chunk) => {
			raw += chunk;
		});
		try {
			const opened = await client.request("artifact/didOpen", {
				uri,
				text: "# Caf\u00e9 \u{1F600}\u2028x\n- [ ] T1 na\u00efve\n",
			});
			assert.equal(opened.uri, uri);
			const symbols = await client.request("artifact/symbols", { uri });
			assert.equal(symbols.children[0].props.title, "Caf\u00e9 \u{1F600}\u2028x");
			// Invalid UTF-8 would have been decoded to U+FFFD.
			assert.ok(!raw.includes("\uFFFD"));
		} finally {
			client.close();
		}
	}
});
