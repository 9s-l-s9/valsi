// SPDX-License-Identifier: GPL-3.0-or-later

import { spawn } from "node:child_process";

export const AAP_TIMEOUT_MS = 10_000;

/** A strict-LF JSON-RPC client for the headless Valsi AAP server. */
export class AAPClient {
	constructor(command, args, options = {}) {
		this.nextId = 1;
		this.pending = new Map();
		this.buffer = "";
		this.timeoutMs = options.timeoutMs ?? AAP_TIMEOUT_MS;
		this.child = (options.spawn ?? spawn)(command, args, {
			cwd: options.cwd,
			env: options.env ?? process.env,
			stdio: ["pipe", "pipe", "pipe"],
		});
		this.child.stdout.setEncoding("utf8");
		this.child.stdout.on("data", (chunk) => this.consume(chunk));
		this.child.stderr.setEncoding("utf8");
		this.stderr = "";
		this.child.stderr.on("data", (chunk) => {
			this.stderr = (this.stderr + chunk).slice(-16_384);
		});
		this.child.once("error", (error) => this.failAll(error));
		this.child.once("exit", (code, signal) => {
			const detail = this.stderr.trim();
			this.failAll(
				new Error(
					`AAP server exited (${signal ?? code ?? "unknown"})${detail ? `: ${detail}` : ""}`,
				),
			);
		});
	}

	consume(chunk) {
		this.buffer += chunk;
		for (;;) {
			const end = this.buffer.indexOf("\n");
			if (end < 0) return;
			const record = this.buffer.slice(0, end);
			this.buffer = this.buffer.slice(end + 1);
			if (record.endsWith("\r")) {
				this.failAll(new Error("AAP server emitted CRLF; strict LF required"));
				continue;
			}
			let message;
			try {
				message = JSON.parse(record);
			} catch {
				this.failAll(new Error("AAP server emitted malformed JSON"));
				continue;
			}
			const pending = this.pending.get(message.id);
			if (!pending) continue;
			clearTimeout(pending.timer);
			this.pending.delete(message.id);
			if (message.error) {
				pending.reject(
					new Error(`AAP ${message.error.code}: ${message.error.message}`),
				);
			} else {
				pending.resolve(message.result);
			}
		}
	}

	request(method, params = {}, signal) {
		if (!this.child || this.child.exitCode !== null) {
			return Promise.reject(new Error("AAP server is not running"));
		}
		const id = `pi-${this.nextId++}`;
		return new Promise((resolve, reject) => {
			const finishAbort = () => {
				const pending = this.pending.get(id);
				if (!pending) return;
				clearTimeout(pending.timer);
				this.pending.delete(id);
				reject(signal?.reason ?? new Error("AAP request aborted"));
			};
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`AAP request timed out: ${method}`));
			}, this.timeoutMs);
			this.pending.set(id, { resolve, reject, timer });
			signal?.addEventListener("abort", finishAbort, { once: true });
			const record = JSON.stringify({ jsonrpc: "2.0", id, method, params });
			this.child.stdin.write(`${record}\n`, "utf8", (error) => {
				if (error) {
					clearTimeout(timer);
					this.pending.delete(id);
					reject(error);
				}
			});
		});
	}

	failAll(error) {
		for (const pending of this.pending.values()) {
			clearTimeout(pending.timer);
			pending.reject(error);
		}
		this.pending.clear();
	}

	close() {
		this.failAll(new Error("AAP client closed"));
		this.child?.stdin.end();
		this.child = undefined;
	}
}

