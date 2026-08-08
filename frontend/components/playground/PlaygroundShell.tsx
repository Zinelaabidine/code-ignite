"use client";

import dynamic from "next/dynamic";
import { useState } from "react";

import LanguageSelect from "@/components/playground/LanguageSelect";
import OutputPane from "@/components/playground/OutputPane";
import RunButton from "@/components/playground/RunButton";
import { useRun } from "@/lib/runs/useRun";

// The build is a static export; CodeMirror has no useful server render and
// touches browser APIs at module scope, so it must never be part of the
// server/first-load bundle. See EditorPane.tsx.
const EditorPane = dynamic(() => import("@/components/playground/EditorPane"), {
  ssr: false,
  loading: () => (
    <div className="flex h-full items-center justify-center rounded-xl border border-[var(--nord-hairline)] bg-[var(--nord-bg-2)] text-sm text-[var(--nord-slate)]">
      Loading editor…
    </div>
  ),
});

const STARTER_CODE: Record<string, string> = {
  python: 'print("Hello, world!")\n',
};

type PlaygroundShellProps = {
  apiBaseUrl: string;
};

export default function PlaygroundShell({ apiBaseUrl }: PlaygroundShellProps) {
  const [language, setLanguage] = useState("python");
  const [code, setCode] = useState(STARTER_CODE[language] ?? "");
  const { state, run } = useRun(apiBaseUrl);

  const busy = state.status === "submitting" || state.status === "polling";

  function handleLanguageChange(next: string): void {
    setLanguage(next);
    setCode(STARTER_CODE[next] ?? "");
  }

  return (
    <main className="flex min-h-screen w-full flex-col gap-4 px-4 py-6 sm:px-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-lg font-semibold text-[var(--nord-ink)]">
          Playground
        </h1>
        <div className="flex items-center gap-3">
          <LanguageSelect
            value={language}
            onChange={handleLanguageChange}
            disabled={busy}
          />
          <RunButton state={state} onRun={() => run(language, code)} />
        </div>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="min-h-[320px] lg:min-h-0">
          <EditorPane
            language={language}
            value={code}
            onChange={setCode}
            readOnly={busy}
          />
        </div>
        <div className="min-h-[320px] lg:min-h-0">
          <OutputPane state={state} />
        </div>
      </div>
    </main>
  );
}
