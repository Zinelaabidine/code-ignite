"use client";

import { python } from "@codemirror/lang-python";
import CodeMirror from "@uiw/react-codemirror";

type EditorPaneProps = {
  language: string;
  value: string;
  onChange: (value: string) => void;
  readOnly?: boolean;
};

/**
 * CodeMirror is a browser-only editor with no useful server render, and the
 * build is a static export — importing it at module scope would break
 * `next build`. The component that renders this one loads it via
 * `next/dynamic(..., { ssr: false })`, per stage 5 of the implementation
 * plan; this file itself stays a plain client component so it can also be
 * imported directly in tests without going through `next/dynamic`.
 *
 * `SUPPORTED_LANGUAGES` (types/runs.ts) has only "python" today, so this is
 * the only language extension wired in. Add the matching `@codemirror/lang-*`
 * package here when the backend registry grows one.
 */
export default function EditorPane({
  language,
  value,
  onChange,
  readOnly,
}: EditorPaneProps) {
  const extensions = language === "python" ? [python()] : [];

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
