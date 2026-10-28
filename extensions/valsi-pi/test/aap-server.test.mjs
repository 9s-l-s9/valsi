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
