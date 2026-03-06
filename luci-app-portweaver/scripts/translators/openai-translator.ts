import dotenv from "dotenv";
import OpenAI from "openai";
import type { Translator } from "./index.js";
import { readFileSync } from "node:fs";
const md = readFileSync(new URL("./prompt.md", import.meta.url), "utf8");
dotenv.config();
console.log(md);

export class OpenAITranslator implements Translator {
	private client: OpenAI;

	constructor() {
		const apiKey = process.env.OPENAI_API_KEY;
		const baseURL = process.env.OPENAI_API_URL;

		if (!apiKey) {
			throw new Error("OPENAI_API_KEY environment variable is required");
		}

		this.client = new OpenAI({
			apiKey,
			baseURL: baseURL || undefined,
		});
	}

	async translate(texts: string[]): Promise<Map<string, string>> {
		if (texts.length === 0) {
			return new Map();
		}

		const prompt = `You are a professional English (en) to Chinese (zh-Hans) translator. Your goal is to accurately convey the meaning and nuances of the original English text while adhering to Chinese grammar, vocabulary, and cultural sensitivities. The purpose of the translation is to provide i18n for the software.
Return ONLY a JSON array of translations in the same order as the input, with no additional text or explanation.
Please translate the following English text into Chinese:

${texts.map((text, index) => `${index + 1}. ${JSON.stringify(text)}`).join("\n")}`;

		try {
			console.log("Translation prompt:", prompt);
			const response = await this.client.chat.completions.create({
				model: "translategemma:12b-it-q8_0",
				messages: [
					{
						role: "system",
						content:
							"You are a professional translator specialising in network engineering and software localisation, with expertise in FRP, port forwarding, firewalls, and socket programming terminology. Translate English to Simplified Chinese. Return only a JSON array of translated strings, nothing else.",
					},
					{
						role: "system",
						content: md,
					},
					{
						role: "user",
						content: prompt,
					},
				],
			});

			const content = response.choices[0]?.message?.content;
			if (!content) {
				throw new Error("No response from OpenAI API");
			}
			console.log(content);

			let jsonContent = content.trim();
			if (jsonContent.startsWith("```")) {
				jsonContent = jsonContent
					.replace(/^```(?:json)?\n?/, "")
					.replace(/\n?```$/, "");
			}

			const translations = JSON.parse(jsonContent) as string[];

			if (
				!Array.isArray(translations) ||
				translations.length !== texts.length
			) {
				throw new Error(
					`Expected ${texts.length} translations, got ${translations.length}`,
				);
			}

			const resultMap = new Map<string, string>();
			for (let i = 0; i < texts.length; i++) {
				const original = texts[i];
				const translated = translations[i];
				if (original && translated) {
					resultMap.set(original, translated);
				}
			}

			return resultMap;
		} catch (error) {
			if (error instanceof Error) {
				throw new Error(`Translation failed: ${error.message}`);
			}
			throw new Error("Translation failed with unknown error");
		}
	}
}
