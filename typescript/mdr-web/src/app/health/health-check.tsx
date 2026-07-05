"use client";

import { useCallback, useEffect, useState } from "react";

type Result =
  | { state: "loading" }
  | { state: "success"; status: number; body: unknown }
  | { state: "error"; status?: number; error: string };

// apiBaseUrl はサーバーコンポーネントが実行時に process.env.API_BASE_URL を読んで渡す。
// 未設定（null）なら設定エラーとして扱い、silent に別 API を叩かない。
export function HealthCheck({ apiBaseUrl }: { apiBaseUrl: string | null }) {
  const healthEndpoint = apiBaseUrl ? `${apiBaseUrl}/health` : null;

  // 未設定は初期化時点で設定エラーに確定させる。
  const [result, setResult] = useState<Result>(() =>
    healthEndpoint
      ? { state: "loading" }
      : { state: "error", error: "API_BASE_URL が設定されていません" },
  );

  // setResult は await 後にのみ呼ぶ（effect 内での同期 setState を避ける）。
  const runCheck = useCallback(async () => {
    if (!healthEndpoint) return;
    try {
      const res = await fetch(healthEndpoint, { cache: "no-store" });
      const body = await res.json().catch(() => null);
      if (!res.ok) {
        setResult({
          state: "error",
          status: res.status,
          error: `API responded with HTTP ${res.status}`,
        });
        return;
      }
      setResult({ state: "success", status: res.status, body });
    } catch (e) {
      // CORS ブロックやネットワーク到達不可はここに来る
      setResult({
        state: "error",
        error: e instanceof Error ? e.message : "Failed to reach the API",
      });
    }
  }, [healthEndpoint]);

  const handleRecheck = useCallback(() => {
    setResult({ state: "loading" });
    void runCheck();
  }, [runCheck]);

  useEffect(() => {
    // マウント時に疎通確認を実行する（外部 API の状態を React に同期する副作用）。
    // setState は runCheck 内の await 後にのみ行われるため同期的な連鎖描画は起きない。
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void runCheck();
  }, [runCheck]);

  return (
    <div className="flex flex-col flex-1 items-center justify-center bg-zinc-50 font-sans dark:bg-black">
      <main className="flex w-full max-w-2xl flex-col gap-8 px-8 py-16 sm:px-16">
        <div className="flex flex-col gap-2">
          <h1 className="text-3xl font-semibold tracking-tight text-black dark:text-zinc-50">
            API 疎通確認
          </h1>
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            バックエンドの疎通確認エンドポイントを叩いた結果を表示します。
          </p>
        </div>

        <div className="flex flex-col gap-6 rounded-2xl border border-black/[.08] bg-white p-6 dark:border-white/[.145] dark:bg-zinc-950">
          <div className="flex items-center justify-between gap-4">
            <StatusBadge result={result} />
            <button
              type="button"
              onClick={handleRecheck}
              disabled={result.state === "loading" || !healthEndpoint}
              className="flex h-10 items-center justify-center rounded-full bg-foreground px-5 text-sm font-medium text-background transition-colors hover:bg-[#383838] disabled:opacity-50 dark:hover:bg-[#ccc]"
            >
              {result.state === "loading" ? "確認中…" : "再確認"}
            </button>
          </div>

          <dl className="flex flex-col gap-4 text-sm">
            <Row label="Endpoint">
              <code className="font-mono text-zinc-700 dark:text-zinc-300">
                GET {healthEndpoint ?? "(API_BASE_URL 未設定)"}
              </code>
            </Row>
            {"status" in result && result.status !== undefined && (
              <Row label="HTTP Status">
                <code className="font-mono text-zinc-700 dark:text-zinc-300">
                  {result.status}
                </code>
              </Row>
            )}
            {result.state === "success" && (
              <Row label="Response">
                <pre className="overflow-x-auto rounded-lg bg-zinc-100 p-3 font-mono text-xs text-zinc-800 dark:bg-zinc-900 dark:text-zinc-200">
                  {JSON.stringify(result.body, null, 2)}
                </pre>
              </Row>
            )}
            {result.state === "error" && (
              <Row label="Error">
                <span className="text-red-600 dark:text-red-400">
                  {result.error}
                </span>
              </Row>
            )}
          </dl>
        </div>
      </main>
    </div>
  );
}

function StatusBadge({ result }: { result: Result }) {
  const styles: Record<Result["state"], { label: string; className: string }> = {
    loading: {
      label: "確認中",
      className:
        "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
    },
    success: {
      label: "接続成功",
      className:
        "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-400",
    },
    error: {
      label: "接続失敗",
      className: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-400",
    },
  };
  const { label, className } = styles[result.state];
  return (
    <span
      className={`inline-flex items-center rounded-full px-3 py-1 text-sm font-medium ${className}`}
    >
      {label}
    </span>
  );
}

function Row({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-500">
        {label}
      </dt>
      <dd className="text-zinc-900 dark:text-zinc-100">{children}</dd>
    </div>
  );
}
