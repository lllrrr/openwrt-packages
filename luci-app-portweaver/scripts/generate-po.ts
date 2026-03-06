import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import { OpenAITranslator } from "./translators/openai-translator.js";
import { loadCache, saveCache } from "./utils/cache.js";
import { generatePOFile } from "./utils/po-generator.js";

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function main(): Promise<void> {
	try {
		console.log("🚀 Starting PO file generation...\n");

		const translationsJsonPath = join(__dirname, "..", "translations.json");
		const cacheFilePath = join(__dirname, "..", "translation.cache.json");
		const poFilePath = join(
			__dirname,
			"..",
			"po",
			"zh_Hans",
			"portweaver.po",
		);

		console.log("📖 Loading translations.json...");
		const translationsContent = await readFile(translationsJsonPath, "utf-8");
		const translationsData = JSON.parse(translationsContent) as {
			translations: string[];
		};
		const sourceStrings = translationsData.translations;
		console.log(`   Found ${sourceStrings.length} source strings\n`);

		console.log("💾 Loading translation cache...");
		const cache = await loadCache(cacheFilePath);
		console.log(`   Loaded ${cache.size} cached translations\n`);

		const stringsToTranslate = sourceStrings.filter(
			(str) => !cache.has(str) && str.trim() !== "",
		);
		console.log(
			`🔍 Found ${stringsToTranslate.length} strings needing translation\n`,
		);

		if (stringsToTranslate.length > 0) {
			if (!process.env.OPENAI_API_KEY) {
				console.error(
					"❌ Error: OPENAI_API_KEY not found in environment variables",
				);
				console.error(
					"   Please create a .env file with OPENAI_API_KEY (see .env.example)",
				);
				process.exit(1);
			}

			console.log("🤖 Translating new strings with OpenAI...");
			const translator = new OpenAITranslator();

			// Batch translation with limit to avoid overloading the API
			const batchSize = 25; // Translate 25 strings at a time
			let totalTranslated = 0;

			for (let i = 0; i < stringsToTranslate.length; i += batchSize) {
				const batch = stringsToTranslate.slice(i, i + batchSize);
				console.log(
					`   Translating batch ${Math.floor(i / batchSize) + 1}/${Math.ceil(stringsToTranslate.length / batchSize)} (${batch.length} strings)...`,
				);
				const batchTranslations = await translator.translate(batch);
				for (const [key, value] of batchTranslations) {
					cache.set(key, value);
					totalTranslated++;
				}
			}

			console.log(`   Translated ${totalTranslated} strings\n`);

			console.log("💾 Updating cache with new translations...");
			await saveCache(cacheFilePath, cache);
			console.log(`   Cache updated (${cache.size} total entries)\n`);
		} else {
			console.log("✅ All strings already cached, skipping translation\n");
		}

		console.log("📝 Generating .po file...");
		await generatePOFile(poFilePath, cache);
		console.log(`   Generated: ${poFilePath}\n`);

		console.log("✨ Summary:");
		console.log(`   Total source strings: ${sourceStrings.length}`);
		console.log(`   Cached translations: ${cache.size}`);
		console.log(`   New translations: ${stringsToTranslate.length}`);
		console.log(`   Output file: ${poFilePath}`);
		console.log("\n✅ PO file generation completed successfully!");
	} catch (error) {
		console.error("\n❌ Error during PO file generation:");
		if (error instanceof Error) {
			console.error(`   ${error.message}`);
			if (error.stack) {
				console.error("\nStack trace:");
				console.error(error.stack);
			}
		} else {
			console.error(`   ${String(error)}`);
		}
		process.exit(1);
	}
}

main();
