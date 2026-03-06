import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import * as gettextParser from "gettext-parser";

/**
 * Generates a .po file from scratch using the provided translations.
 *
 * @param poFilePath - Path to the .po file to generate
 * @param translations - Map of original text (msgid) to translated text (msgstr)
 * @returns Promise that resolves when the file is written
 *
 * @remarks
 * - Always creates a new .po file from scratch (does not read existing file)
 * - Creates default headers for the .po file
 * - Only includes translations provided in the Map
 * - Untranslated strings (not in the Map) will not be included
 * - Uses gettext-parser for proper .po file format handling
 *
 * @example
 * ```typescript
 * const translations = new Map([
 *   ["Hello", "你好"],
 *   ["World", "世界"]
 * ]);
 * await generatePOFile("po/zh_Hans/portweaver.po", translations);
 * ```
 */
export async function generatePOFile(
	poFilePath: string,
	translations: Map<string, string>,
): Promise<void> {
	// Always create new PO structure from scratch (do not read existing file)
	const poData: gettextParser.GetTextTranslations = {
		charset: "UTF-8",
		headers: {
			"Project-Id-Version": "portweaver",
			"POT-Creation-Date": `${new Date().toISOString().split("T")[0]} 00:00+0000`,
			"PO-Revision-Date": `${new Date().toISOString().split("T")[0]} 00:00+0000`,
			"Last-Translator": "PortWeaver Translator Tools <lazulikao233@outlook.com>",
			"Language-Team": "Chinese <lazulikao233@outlook.com>",
			Language: "zh_CN",
			"MIME-Version": "1.0",
			"Content-Type": "text/plain; charset=UTF-8",
			"Content-Transfer-Encoding": "8bit",
		},
		translations: {
			"": {},
		},
	};

	// Ensure translations context exists
	if (!poData.translations) {
		poData.translations = {};
	}
	if (!poData.translations[""]) {
		poData.translations[""] = {};
	}

	// Merge new translations into the PO data structure
	for (const [msgid, msgstr] of translations) {
		// Skip empty msgid (reserved for headers)
		if (msgid === "" || msgid === msgstr) {
			continue;
		}

		// Create or update translation entry
		poData.translations[""][msgid] = {
			msgid,
			msgstr: [msgstr],
		};
	}

	// Compile PO data back to .po file format
	const compiledContent = gettextParser.po.compile(poData);

	// Ensure directory exists
	await mkdir(dirname(poFilePath), { recursive: true });

	// Write the compiled content to file
	await writeFile(poFilePath, compiledContent, "utf-8");
}
