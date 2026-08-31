"use client";

import { go } from "@codemirror/lang-go";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import type { Extension } from "@codemirror/state";
import CodeMirror from "@uiw/react-codemirror";

type EditorPaneProps = {
  language: string;
  value: string;
  onChange: (value: string) => void;
  readOnly?: boolean;
};

/**
 * Keyed by `SUPPORTED_LANGUAGES[number]["value"]`, not typed against it
 * directly — this stays a plain `Record<string, ...>` so a language present
 * in `types/runs.ts` but missing a case here degrades to no highlighting
 * (see the component docstring) instead of a type error blocking the build.
 */
const LANGUAGE_EXTENSIONS: Record<string, () => Extension[]> = {
  python: () => [python()],
  node: () => [javascript()],
  typescript: () => [javascript({ typescript: true })],
  go: () => [go()],
  rust: () => [rust()],
};

/**
 * CodeMirror is a browser-only editor with no useful server render, and the
 * build is a static export — importing it at module scope would break
 * `next build`. The component that renders this one loads it via
 * `next/dynamic(..., { ssr: false })`, per stage 5 of the implementation
 * plan; this file itself stays a plain client component so it can also be
 * imported directly in tests without going through `next/dynamic`.
 *
 * One CodeMirror language package per entry in `SUPPORTED_LANGUAGES`
 * (types/runs.ts) except "typescript", which reuses `@codemirror/lang-javascript`
 * in its `typescript: true` mode rather than pulling in a separate package —
 * mirrors the backend registry, where `typescript` reuses the `node` image
 * (see `domain/languages.py`). A language with no case below still runs
 * fine end to end; it just falls back to the plain, unhighlighted extension
 * list, same as every language did before this file existed.
 */
export default function EditorPane({
  language,
  value,
  onChange,
  readOnly,
}: EditorPaneProps) {
  const extensions = LANGUAGE_EXTENSIONS[language]?.() ?? [];

  return (
    <div className="h-full overflow-hidden rounded-xl border border-[var(--nord-hairline)]">
      <CodeMirror
        value={value}
        height="100%"
        theme="light"
        extensions={extensions}
        readOnly={readOnly}
        onChange={onChange}
        basicSetup={{
          lineNumbers: true,
          foldGutter: true,
          highlightActiveLine: true,
        }}
        style={{ height: "100%", fontSize: "13px" }}
      />
    </div>
  );
}
