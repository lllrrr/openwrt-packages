import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseSync } from "@swc/core";

/**
 * Extracts translation strings from _() function calls in the codebase.
 * Uses SWC to parse TypeScript/JavaScript files and find all translation calls.
 */

/**
 * Recursively finds all TypeScript and JavaScript files in a directory.
 * @param dir - The directory to search
 * @param fileList - Accumulator for found files
 * @returns Array of file paths
 */
function findSourceFiles(dir: string, fileList: string[] = []): string[] {
	try {
		const files = readdirSync(dir);

		for (const file of files) {
			const filePath = join(dir, file);

			try {
				const stat = statSync(filePath);

				if (stat.isDirectory()) {
					// Skip node_modules, .git, and other common directories
					if (
						!file.startsWith(".") &&
						file !== "node_modules" &&
						file !== "dist" &&
						file !== "build"
					) {
						findSourceFiles(filePath, fileList);
					}
				} else if (stat.isFile()) {
					const ext = extname(file);
					// Include .ts, .tsx, .js, .jsx files
					if ([".ts", ".tsx", ".js", ".jsx"].includes(ext)) {
						fileList.push(filePath);
					}
				}
			} catch (err) {
				console.warn(`Warning: Could not access ${filePath}:`, err);
			}
		}
	} catch (err) {
		console.error(`Error reading directory ${dir}:`, err);
	}

	return fileList;
}

/**
 * Visitor function to traverse the AST and extract translation strings.
 * Looks for CallExpression nodes where the callee is '_' and extracts string arguments.
 * @param node - The AST node to visit
 * @param translations - Set to accumulate unique translation strings
 */
function visitNode(node: unknown, translations: Set<string>): void {
	if (!node || typeof node !== "object") {
		return;
	}

	const astNode = node as Record<string, unknown>;

	// Check if this is a call expression with callee '_'
	if (astNode.type === "CallExpression") {
		const callee = astNode.callee as Record<string, unknown> | undefined;

		// Check if callee is an Identifier named '_'
		if (callee?.type === "Identifier" && callee.value === "_") {
			// Extract the first argument if it's a string literal
			const args = astNode.arguments as
				| Array<Record<string, unknown>>
				| undefined;
			if (args && args.length > 0) {
				const firstArg = args[0];
				if (firstArg?.expression) {
					const expr = firstArg.expression as Record<string, unknown>;
					if (expr.type === "StringLiteral" && expr.value) {
						translations.add(expr.value as string);
					} else {
						console.warn(
							`Warning: _() call with non-string argument found. ${JSON.stringify(expr)}`,
						);
					}
				}
			}
		}
	}

	// Recursively visit all properties of the node
	for (const key in astNode) {
		if (Object.hasOwn(astNode, key)) {
			const value = astNode[key];

			if (Array.isArray(value)) {
				for (const item of value) {
					visitNode(item, translations);
				}
			} else if (value && typeof value === "object") {
				visitNode(value, translations);
			}
		}
	}
}

/**
 * Parses a single file and extracts translation strings from _() calls.
 * @param filePath - Path to the file to parse
 * @param translations - Set to accumulate unique translation strings
 */
function extractFromFile(filePath: string, translations: Set<string>): void {
	try {
		// Read file content
		const fileSrc = readFileSync(filePath, "utf-8");
		// Parse the file with SWC
		const ast = parseSync(`(()=>{${fileSrc}})()`, {
			syntax:
				filePath.endsWith(".tsx") || filePath.endsWith(".jsx")
					? "typescript"
					: "typescript",
			tsx: filePath.endsWith(".tsx") || filePath.endsWith(".jsx"),
			decorators: true,
			dynamicImport: true,
		});

		// Visit all nodes in the AST
		visitNode(ast, translations);
	} catch (err) {
		console.warn(`Warning: Could not parse ${filePath}:`, err);
	}
}

/**
 * Main function to extract translations from the codebase.
 * Scans the parent directory for source files and outputs results to translations.json.
 */
function main(): void {
	console.log("Starting translation extraction...");

	// Scan the parent directory (project root)
	const currentDir = dirname(fileURLToPath(import.meta.url));
	const projectRoot = join(currentDir, "..");
	console.log(`Scanning directory: ${projectRoot}`);

	// Find all source files
	const sourceFiles = findSourceFiles(join(projectRoot, "htdocs"));
	console.log(`Found ${sourceFiles.length} source files`);

	// Extract translations from all files
	const translations = new Set<string>();

	for (const file of sourceFiles) {
		extractFromFile(file, translations);
	}

	console.log(`Extracted ${translations.size} unique translations`);

	// Sort translations alphabetically
	const sortedTranslations = Array.from(translations)
		.sort()
		.filter((str) => str.trim() !== "" && str.trim() !== "-"&& str.trim() !== "+");

	// Write to output file
	const outputPath = join(projectRoot, "translations.json");
	const output = {
		translations: sortedTranslations,
	};

	writeFileSync(outputPath, JSON.stringify(output, null, 2), "utf-8");
	console.log(`Wrote translations to ${outputPath}`);
}

// Run the extraction
main();
