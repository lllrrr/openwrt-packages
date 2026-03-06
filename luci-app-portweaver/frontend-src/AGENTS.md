# AGENTS.md - PortWeaver Frontend (TypeScript)

## Overview

This is the LuCI web UI for PortWeaver, built with TypeScript and a custom JSX factory.
**CRITICAL**: This is NOT React. It is a thin wrapper around native DOM APIs using JSX syntax.

## Structure

The `frontend-src/` directory is organized as follows:
- `main.tsx`: Application entry point.
- `components/`: Reusable UI components.
- `modules/`: Business logic (e.g., RPC client).
- `types/`: TypeScript type definitions.
- `utils/`: Utility functions, including the JSX factory.

## Build & Development

**Always use pnpm, NOT npm.**

- **Install dependencies**: `pnpm install`
- **Build**: `pnpm build`
- **Type check**: `pnpm check`
- **Format**: `pnpm format`
- **Dev**: `pnpm dev`

## Core Architectural Rules (STRICT ENFORCEMENT)

### 1. DOM Manipulation: NO querySelector

**FORBIDDEN**:
- `document.querySelector(...)`
- `document.getElementById(...)`
- `this.element.querySelector(...)`
- `element.innerHTML = ...`

**REQUIRED**:
Store references to DOM elements directly in the `render()` method when they are created.

**❌ BAD Pattern:**
```typescript
render() {
  return <div id="status-display">Loading...</div>;
}

update(status) {
  // VIOLATION: DOM query is slow and brittle
  const el = document.getElementById('status-display'); 
  if (el) el.textContent = status;
}
```

**✅ GOOD Pattern:**
```typescript
private statusEl: HTMLElement;

render() {
  // Store reference directly during creation
  this.statusEl = <span>Loading...</span>;
  return <div>Status: {this.statusEl}</div>;
}

update(status) {
  // Update via stored reference
  if (this.statusEl) {
    this.statusEl.textContent = status;
  }
}
```

### 2. Component Structure

- **Classes**: Components are classes, not functions.
- **Render**: Must have a `render()` method returning `HTMLElement` (or `DocumentFragment`).
- **No Virtual DOM**: The JSX factory creates real DOM nodes immediately.
- **State**: There is no `setState` or automatic re-render. You must manually update specific DOM nodes when data changes.

### 3. Styling

- Use inline styles via the `style` attribute string or object.
- Avoid adding new CSS files unless absolutely necessary.

### 4. Error Handling

- **RPC Calls**: `rpcClient` calls return Promises. ALWAYS attach a `.catch()` handler.
- **UI Resilience**: If a component crashes, it shouldn't break the whole page.

## Anti-Patterns to Avoid

- **React Hooks**: No `useState`, `useEffect`, `useRef`, etc.
- **Complex Re-renders**: Do not re-render the entire component tree for simple value updates. Update the specific text node or attribute instead.
- **Unchecked Properties**: Always check if properties exist before accessing (e.g., `data?.result?.value`).

## Verification Checklist

Before marking a task as complete:
1. **Build**: Run `pnpm build` to ensure no compilation errors.
2. **Lint**: Run `pnpm check` to verify types and code style.
3. **Reference Check**: Did you use `querySelector`? If yes, REFACTOR IT immediately using the reference pattern.
