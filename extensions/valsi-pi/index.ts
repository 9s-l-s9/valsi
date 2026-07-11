// SPDX-License-Identifier: GPL-3.0-or-later

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerAAPTools } from "./aap.ts";

/** Add only Valsi's semantic artifact tool to stock Pi. */
export default function valsiArtifacts(pi: ExtensionAPI) {
	registerAAPTools(pi);
}
