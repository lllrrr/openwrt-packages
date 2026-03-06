/**
 * Translator interface for translating text strings.
 */
export interface Translator {
	/**
	 * Translates an array of text strings.
	 *
	 * @param texts - Array of strings to translate
	 * @returns Promise resolving to a Map where keys are original texts and values are translations
	 */
	translate(texts: string[]): Promise<Map<string, string>>;
}
