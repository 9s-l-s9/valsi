// SPDX-License-Identifier: GPL-3.0-or-later

import { spawn } from "node:child_process";

export const AAP_TIMEOUT_MS = 10_000;
/** How long close() waits for the server to exit on EOF before killing it. */
export const AAP_CLOSE_GRACE_MS = 2_000;

/** A strict-LF JSON-RPC client for the headless Valsi AAP server. */
export class AAPClient {
	constructor(command, args, options = {}) {
		this.nextId = 1;
		this.pending = new Map();
		this.documents = new Map();
		this.buffer = "";
		this.timeoutMs = options.timeoutMs ?? AAP_TIMEOUT_MS;
		this.closeGraceMs = options.closeGraceMs ?? AAP_CLOSE_GRACE_MS;
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
		this.child.once("error", (error) => {
			this.child = undefined;
			this.failAll(error);
		});
		this.child.once("exit", (code, signal) => {
			this.child = undefined;
			const detail = this.stderr.trim();
			this.failAll(
				new Error(
					`AAP server exited (${signal ?? code ?? "unknown"})${detail ? `: ${detail}` : ""}`,
				),
			);
		});
	}

	/** True while the server process can still accept requests. */
	get running() {
		return this.child !== undefined && this.child.exitCode === null;
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
		if (!this.running) {
			return Promise.reject(new Error("AAP server is not running"));
		}
		if (signal?.aborted) {
			return Promise.reject(signal.reason ?? new Error("AAP request aborted"));
		}
		const id = `pi-${this.nextId++}`;
		return new Promise((settleResolve, settleReject) => {
			// Every settlement path detaches the abort listener.
			const resolve = (value) => {
				signal?.removeEventListener("abort", finishAbort);
				settleResolve(value);
			};
			const reject = (error) => {
				signal?.removeEventListener("abort", finishAbort);
				settleReject(error);
			};
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
				// The server is synchronous: a request that times out has
				// wedged it, so later requests would only queue behind it.
				// Kill it; a connection respawns a fresh server.
				this.child?.kill("SIGKILL");
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

	/** Run one query with temporary document state; serialize calls for one URI. */
	withDocument(uri, text, query, signal) {
		const previous = this.documents.get(uri) ?? Promise.resolve();
		const operation = previous.catch(() => {}).then(async () => {
			if (signal?.aborted) throw signal.reason ?? new Error("AAP request aborted");
			let failed = false;
			try {
				await this.request("artifact/didOpen", { uri, text }, signal);
				return await query(this);
			} catch (error) {
				failed = true;
				throw error;
			} finally {
				// Even an aborted didOpen may already be queued in the server.
				// Close without the caller's signal, after that queued request.
				if (this.running) {
					try {
						await this.request("artifact/didClose", { uri });
					} catch (error) {
						// A server that cannot release the document is not reusable.
						this.close();
						if (!failed) throw error;
					}
				}
			}
		});
		this.documents.set(uri, operation);
		const release = () => {
			if (this.documents.get(uri) === operation) this.documents.delete(uri);
		};
		operation.then(release, release);
		return operation;
	}

	/** End the server's stdin; kill it if it has not exited after the grace period. */
	close() {
		this.failAll(new Error("AAP client closed"));
		const child = this.child;
		this.child = undefined;
		if (!child) return;
		child.stdin.end();
		if (child.exitCode !== null || child.signalCode) return;
		const timer = setTimeout(() => child.kill("SIGKILL"), this.closeGraceMs);
		timer.unref?.();
		child.once("exit", () => clearTimeout(timer));
	}
}

/** Return a getter that reuses a running client and respawns a dead one. */
export function aapConnection(create) {
	let client;
	const connection = () => {
		if (!client?.running) {
			client?.close();
			client = create();
		}
		return client;
	};
	connection.close = () => {
		client?.close();
		client = undefined;
	};
	return connection;
}

