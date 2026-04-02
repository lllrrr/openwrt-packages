/**
 * JSX Fragment symbol
 */
export const Fragment = Symbol.for("jsx.fragment");

function normalizeChildren(input: any[], out: any[] = []): any[] {
  for (const child of input) {
    if (child == null || typeof child === "boolean") continue;

    if (Array.isArray(child)) {
      normalizeChildren(child, out);
    } else {
      out.push(child);
    }
  }
  return out;
}

function createJsxNode(type: any, config: any): Node {
  const { children, ...props } = config || {};

  const childArray =
    children == null ? [] : Array.isArray(children) ? children : [children];
  const filteredChildren = normalizeChildren(childArray);

  if (type === Fragment) {
    const fragment = document.createDocumentFragment();
    fragment.append(...filteredChildren);
    return fragment;
  }

  if (typeof type === "function") {
    return type({ ...props, children: filteredChildren });
  }

  const eventHandlers: Record<string, any> = {};
  const finalProps = { ...props };

  for (const [key, value] of Object.entries(finalProps)) {
    if (key.startsWith("on") && typeof value === "function") {
      eventHandlers[key] = value;
      delete finalProps[key];
    } else if (typeof value === "boolean") {
      if (value) {
        finalProps[key] = key;
      } else {
        delete finalProps[key];
      }
    }
  }

  const hasProps = Object.keys(finalProps).length > 0;
  const element = !hasProps
    ? filteredChildren.length > 1
      ? E(type, {}, filteredChildren)
      : E(type, {}, filteredChildren[0])
    : filteredChildren.length > 1
      ? E(type, finalProps, filteredChildren)
      : E(type, finalProps, filteredChildren[0]);

  for (const [eventName, handler] of Object.entries(eventHandlers)) {
    const eventType = eventName.slice(2).toLowerCase();
    (element as HTMLElement).addEventListener(eventType, handler);
  }

  return element;
}

/**
 * JSX automatic runtime - production (single/no children)
 */
export function jsx(type: any, config: any): Node {
  return createJsxNode(type, config);
}

/**
 * JSX automatic runtime - production (multiple static children)
 */
export function jsxs(type: any, config: any): Node {
  return createJsxNode(type, config);
}

/**
 * JSX automatic runtime - development mode
 */
export function jsxDEV(type: any, config: any): Node {
  return createJsxNode(type, config);
}
