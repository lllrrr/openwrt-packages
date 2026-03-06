declare global {
  type BaseProps = {
    children?: any;
    class?: string;
    id?: string;
    name?: string;
    style?: string;
  };
  function createJsxElement(tag: any, props: any, ...children: any[]): Node;
  const JSXFragment: unique symbol;
  type JSXElement<T extends HTMLElement> = Partial<
    Omit<T, keyof BaseProps> & BaseProps
  >;
  namespace JSX {
    type Element = HTMLElement;
    interface IntrinsicElements {
      // [elemName: string]: JSXElement<HTMLElement>;
      div: JSXElement<HTMLDivElement>;
      style: JSXElement<HTMLStyleElement>;
      strong: JSXElement<HTMLElement>;
      button: JSXElement<HTMLButtonElement>;
      span: JSXElement<HTMLSpanElement>;
      input: JSXElement<HTMLInputElement>;
      select: JSXElement<HTMLSelectElement>;
      option: JSXElement<HTMLOptionElement>;
      label: JSXElement<HTMLLabelElement>;
      form: JSXElement<HTMLFormElement>;
      h1: JSXElement<HTMLHeadingElement>;
      h2: JSXElement<HTMLHeadingElement>;
      h3: JSXElement<HTMLHeadingElement>;
      h4: JSXElement<HTMLHeadingElement>;
      h5: JSXElement<HTMLHeadingElement>;
      h6: JSXElement<HTMLHeadingElement>;
      br: JSXElement<HTMLBRElement>;
      em: JSXElement<HTMLElement>;
      tr: JSXElement<HTMLTableRowElement>;
      td: JSXElement<HTMLTableCellElement>;
      table: JSXElement<HTMLTableElement>;
      thead: JSXElement<HTMLTableSectionElement>;
      tbody: JSXElement<HTMLTableSectionElement>;
      th: JSXElement<HTMLTableCellElement>;
      textarea: JSXElement<HTMLTextAreaElement>;
      var: JSXElement<HTMLElement>;
      small: JSXElement<HTMLElement>;
      code: JSXElement<HTMLElement>;
      p: JSXElement<HTMLParagraphElement>;
      a: JSXElement<HTMLAnchorElement>;
    }
  }
}

export {};
