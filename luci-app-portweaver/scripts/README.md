# Translation Extraction Scripts

This directory contains scripts for extracting translation strings from the LuCI app codebase.

## Overview

The extraction script scans the project for `_()` function calls (the translation function) and extracts all string literals passed to it. The output is a JSON file containing all unique translation strings found in the codebase, sorted alphabetically.

**What it does:**
- Recursively scans all TypeScript/JavaScript files in the parent directory
- Uses SWC parser to analyze the AST (Abstract Syntax Tree)
- Finds all `_()` function calls and extracts string arguments
- Outputs unique translations to `translations.json` in the project root

**Files processed:**
- `.ts`, `.tsx`, `.js`, `.jsx` files
- Skips: `node_modules`, `.git`, `dist`, `build`, and hidden directories

## Installation

Install dependencies using pnpm:

```bash
pnpm install
```

This will install:
- `@swc/core` - Fast TypeScript/JavaScript parser
- `ts-node` - TypeScript execution environment
- `@biomejs/biome` - Code linting and formatting
- TypeScript and type definitions

## Usage

### Extract Translations

Run the extraction script:

```bash
pnpm start
```

This executes `extract-translations.ts` and generates `translations.json` in the parent directory.

**Output location:** `../translations.json`

**Output format:**
```json
{
  "translations": [
    "Add Rule",
    "Delete",
    "Enable",
    "Port Forwarding",
    ...
  ]
}
```

## Available Scripts

### `pnpm start`
Runs the translation extraction script. Scans the codebase and generates `translations.json`.

### `pnpm lint`
Runs Biome linter to check code quality. Reports issues without modifying files.

```bash
pnpm lint
```

### `pnpm format`
Formats all code files using Biome. Automatically fixes formatting issues.

```bash
pnpm format
```

### `pnpm check`
Runs Biome check with auto-fix enabled. Checks and fixes both linting and formatting issues.

```bash
pnpm check
```

### `pnpm lint:fix`
Alias for `pnpm check`. Runs Biome check with auto-fix.

```bash
pnpm lint:fix
```

## Output

The script generates `translations.json` in the project root directory (parent of `scripts/`):

```
luci-app-portweaver/
├── scripts/
│   ├── extract-translations.ts
│   ├── package.json
│   └── README.md
└── translations.json          ← Output file
```

The JSON file contains a single `translations` array with all unique translation strings sorted alphabetically.

## Development

The extraction script is written in TypeScript and uses:
- **SWC** for fast, reliable parsing of TypeScript/JavaScript
- **Node.js** file system APIs for directory traversal
- **ts-node** for direct TypeScript execution

Code quality is maintained with:
- **Biome** for linting and formatting
- **TypeScript** for type safety
- **ESM** module system (NodeNext)

## Translation Generation

### Overview

The translation generation script automates the process of creating `.po` (Portable Object) files for internationalization. It reads the extracted translation strings from `translations.json`, translates them using OpenAI's API, and generates properly formatted `.po` files for use in the LuCI application.

**What it does:**
- Reads source strings from `translations.json`
- Uses OpenAI API to translate strings to target languages (currently Simplified Chinese)
- Caches translations to avoid redundant API calls
- Generates `.po` files in the correct format for LuCI

### Setup

Before running the translation script, you need to configure your OpenAI API credentials:

1. Create a `.env` file in the `scripts/` directory:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and add your OpenAI API key:
   ```env
   OPENAI_API_KEY="your_api_key_here"
   OPENAI_API_URL="https://api.openai.com/v1"
   ```

**Configuration options:**
- `OPENAI_API_KEY` (required): Your OpenAI API key for authentication
- `OPENAI_API_URL` (optional): Custom API endpoint URL (defaults to OpenAI's official endpoint)

### Usage

Run the translation generation script:

```bash
pnpm translate
```

This executes `generate-po.ts` and generates `.po` files in the `po/` directory.

**Output location:** `../po/zh_Hans/portweaver.po`

**Output format:**
```po
msgid "Add Rule"
msgstr "添加规则"

msgid "Delete"
msgstr "删除"
```

### Caching

The script uses `translation.cache.json` to store previously translated strings. This provides several benefits:

- **Cost savings**: Avoids re-translating the same strings, reducing API usage
- **Speed**: Cached translations are retrieved instantly
- **Consistency**: Ensures the same source string always gets the same translation

The cache file is automatically created and updated during translation. You can safely commit it to version control to share translations across your team.

**Cache behavior:**
- First run: Translates all strings and creates the cache
- Subsequent runs: Only translates new strings not in the cache
- Manual cache clearing: Delete `translation.cache.json` to re-translate everything

### `pnpm translate`

Runs the translation generation script. Translates extracted strings and generates `.po` files.

```bash
pnpm translate
```

**Prerequisites:**
- `translations.json` must exist (run `pnpm start` first)
- `.env` file must be configured with `OPENAI_API_KEY`

## Troubleshooting

**Script fails to parse a file:**
The script will log a warning and continue processing other files. Check the console output for details.

**No translations found:**
Ensure your code uses the `_()` function for translations and passes string literals (not variables) as arguments.

**Output file not created:**
Check that you have write permissions in the parent directory and that the script completed without errors.

**Translation script fails with "OPENAI_API_KEY not found":**
Create a `.env` file in the `scripts/` directory with your OpenAI API key (see Setup section above).

**API rate limit errors:**
The script processes translations in batches. If you hit rate limits, wait a few minutes and run the script again. The cache will preserve already-translated strings.
