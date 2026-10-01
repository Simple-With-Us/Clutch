import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The model-picker decoration script is embedded as a Swift string literal in
 *  ClutchWindow.swift, so the only honest unit test extracts the functions
 *  from that file and runs them against a minimal fake DOM.  Extraction is by
 *  brace counting from each `const name = () => {` marker. */

const SWIFT = readFileSync(
  join(__dirname, "..", "src", "web", "dock-app", "ClutchWindow.swift"),
  "utf8",
);

function extractConstFn(source: string, name: string): string {
  const marker = `const ${name} = () => {`;
  const start = source.indexOf(marker);
  if (start === -1) throw new Error(`${name} not found in ClutchWindow.swift`);
  let depth = 0;
  for (let i = source.indexOf("{", start); i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return source.slice(start, i + 2); // include the ";"
    }
  }
  throw new Error(`${name}: unbalanced braces`);
}

function extractConstArray(source: string, name: string): string {
  const marker = `const ${name} = [`;
  const start = source.indexOf(marker);
  if (start === -1) throw new Error(`${name} not found`);
  let depth = 0;
  for (let i = source.indexOf("[", start); i < source.length; i++) {
    const ch = source[i];
    if (ch === "[") depth++;
    else if (ch === "]") {
      depth--;
      if (depth === 0) return source.slice(start, i + 2);
    }
  }
  throw new Error(`${name}: unbalanced brackets`);
}

interface FakeEl {
  tagName: string;
  textContent: string;
  children: FakeEl[];
  dataset: Record<string, string>;
  style: { cssText: string; setProperty: (...args: string[]) => void };
  title: string;
  attrs: Record<string, string>;
  setAttribute: (k: string, v: string) => void;
  insertBefore: (node: FakeEl, ref: FakeEl | null) => void;
  appendChild: (node: FakeEl) => void;
  readonly firstChild: FakeEl | null;
}

function makeEl(tagName: string, textContent = ""): FakeEl {
  const el: FakeEl = {
    tagName,
    textContent,
    children: [],
    dataset: {},
    style: { cssText: "", setProperty: () => {} },
    title: "",
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    insertBefore(node, ref) {
      const i = ref ? this.children.indexOf(ref) : 0;
      this.children.splice(i < 0 ? 0 : i, 0, node);
    },
    appendChild(node) { this.children.push(node); },
    get firstChild() { return this.children[0] ?? null; },
  };
  return el;
}

function loadPickerFns(elements: FakeEl[]) {
  const document = {
    querySelectorAll: () => elements,
    createElement: (tag: string) => makeEl(tag),
  };
  const code = [
    "const text = (s) => (s || '').toString();",
    "const MINIMAX_MARK = 'data:mm';",
    "const DEEPSEEK_MARK = 'data:ds';",
    extractConstArray(SWIFT, "MODEL_ROWS"),
    extractConstArray(SWIFT, "DISALLOWED_MODELS"),
    extractConstFn(SWIFT, "markPickerHeadings"),
    extractConstFn(SWIFT, "markPickerModelRows"),
    "return { markPickerHeadings, markPickerModelRows };",
  ].join("\n");
  return new Function("document", code)(document) as {
    markPickerHeadings: () => void;
    markPickerModelRows: () => void;
  };
}

describe("ClutchWindow model-picker decoration", () => {
  it("applies badges to model rows: the heading pass must not consume them", () => {
    // Regression: markPickerHeadings matched 'MiniMax-*'/'DeepSeek-*' rows and
    // inserted a logo child, and markPickerModelRows skips elements that
    // already have children, so no badge ever applied.
    const rows = [
      makeEl("div", "MiniMax-M3.1-Flash-Preview"),
      makeEl("div", "DeepSeek-V4.1-Flash"),
      makeEl("span", "MiniMax-M2.7-highspeed"),
    ];
    const { markPickerHeadings, markPickerModelRows } = loadPickerFns(rows);
    markPickerHeadings();
    markPickerModelRows();
    const badges = rows.map(
      (row) => row.children.find((c) => c.dataset.clutchModelBadge === "1")?.textContent,
    );
    expect(badges).toEqual(["Preview", "Multimodal", "2x Cost"]);
  });

  it("leaves model rows untouched in the heading pass", () => {
    const row = makeEl("div", "MiniMax-M3");
    const { markPickerHeadings } = loadPickerFns([row]);
    markPickerHeadings();
    expect(row.children).toHaveLength(0);
    expect(row.dataset.clutchMmPicker).toBeUndefined();
    expect(row.textContent).toBe("MiniMax-M3");
  });

  it("still rewrites bare provider headings to brand case with a logo", () => {
    const mm = makeEl("div", "minimax");
    const ds = makeEl("span", "deepseek");
    const { markPickerHeadings } = loadPickerFns([mm, ds]);
    markPickerHeadings();
    expect(mm.textContent).toBe("MiniMax");
    expect(mm.dataset.clutchMmPicker).toBe("1");
    expect(mm.firstChild?.tagName).toBe("img");
    expect(mm.firstChild?.dataset.clutchMmPickerMark).toBe("1");
    expect(ds.textContent).toBe("DeepSeek");
    expect(ds.dataset.clutchDsPicker).toBe("1");
    expect(ds.firstChild?.dataset.clutchDsPickerMark).toBe("1");
  });
});
