import { readFile, writeFile } from "node:fs/promises";

/**
 * Loads a translation cache from a JSON file.
 *
 * @param filePath - Path to the cache file
 * @returns A Map containing the cached translations, or an empty Map if the file doesn't exist
 */
export async function loadCache(
	filePath: string,
): Promise<Map<string, string>> {
	try {
		const data = await readFile(filePath, "utf-8");
		const parsed = JSON.parse(data) as Record<string, string>;
		return new Map(Object.entries(parsed));
	} catch (error) {
		// If file doesn't exist or is invalid, return empty Map
		if ((error as NodeJS.ErrnoException).code === "ENOENT") {
			return new Map();
		}
		throw error;
	}
}

/**
 * Saves a translation cache to a JSON file.
 *
 * @param filePath - Path to the cache file
 * @param cache - Map containing the translations to cache
 */
export async function saveCache(
	filePath: string,
	cache: Map<string, string>,
): Promise<void> {
	const obj = Object.fromEntries(cache);
	await writeFile(filePath, JSON.stringify(obj, null, 2), "utf-8");
}
