import { connection } from "next/server";

import { HealthCheck } from "./health-check";

export default async function HealthPage() {
  // connection() で実行時レンダリングにし、process.env を build 時ではなく
  // runtime に読む（同一イメージを環境ごとの env で動かす / build once, deploy anywhere）。
  await connection();
  const apiBaseUrl = process.env.API_BASE_URL ?? null;

  return <HealthCheck apiBaseUrl={apiBaseUrl} />;
}
