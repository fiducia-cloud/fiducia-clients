/** Local projection adapter, not a wire contract, telemetry collector or auth boundary.
 * Supply the explicitly composed Claritas library/SDK; algorithms stay upstream.
 */
export type FiduciaMetric = "request_latency_ms" | "replication_lag_ms" | "queue_depth";
export interface FiduciaMetricSample {
  readonly nodeId: string;
  readonly region: string;
  readonly metric: FiduciaMetric;
  readonly unit: string;
  readonly at: number;
  readonly value: number | null;
}
export interface MetricWindow {
  readonly start: number;
  readonly end: number;
  readonly bucketMs: number;
  readonly minEntities: number;
}
type Projection = { entityId: string; cohortId: string; at: number; value: number | null };
/** Structural port for in-process calls; no duplicated Claritas wire declarations. */
export interface ClaritasTrendPort<Series> {
  cohortTrends(rows: readonly Projection[], window: MetricWindow): Series[];
  individualTrend(rows: readonly Projection[], id: string, window: Omit<MetricWindow, "minEntities">): Series;
  trendSvg(series: Series, title: string): string;
}
const metrics = {
  "request_latency_ms": {
    "unit": "ms",
    "min": 0,
    "max": 1000000000000000.0
  },
  "replication_lag_ms": {
    "unit": "ms",
    "min": 0,
    "max": 1000000000000000.0
  },
  "queue_depth": {
    "unit": "count",
    "min": 0,
    "max": 1000000000000000.0
  }
} as const;

export function createFiduciaMetricViews<Series>(viz: ClaritasTrendPort<Series>) {
  if (!viz || ![viz.cohortTrends, viz.individualTrend, viz.trendSvg].every(fn => typeof fn === "function"))
    throw new TypeError("Claritas trend SDK is required");
  const { cohortTrends, individualTrend, trendSvg } = viz;
  function project(rows: readonly FiduciaMetricSample[], metric: FiduciaMetric): Projection[] {
    if (!Array.isArray(rows) || rows.length > 50000 || !Object.hasOwn(metrics, metric))
      throw new TypeError("Invalid metric projection");
    const definition = metrics[metric];
    return rows.map(row => {
      if (!row || row.metric !== metric || row.unit !== definition.unit ||
          !(row.value === null || (typeof row.value === "number" && Number.isFinite(row.value) &&
            row.value >= definition.min && row.value <= definition.max)))
        throw new TypeError("Invalid metric projection");
      // Whitelist only chart inputs; never forward arbitrary source metadata.
      return { entityId: row.nodeId, cohortId: row.region, at: row.at, value: row.value };
    });
  }
  return Object.freeze({
    cohorts(rows: readonly FiduciaMetricSample[], metric: FiduciaMetric, window: MetricWindow) {
      return cohortTrends(project(rows, metric), window).map(series => ({
        series, svg: trendSvg(series, `${metric} (${metrics[metric].unit}), equal-entity mean`),
      }));
    },
    individual(rows: readonly FiduciaMetricSample[], metric: FiduciaMetric, id: string,
      window: Omit<MetricWindow, "minEntities">) {
      const series = individualTrend(project(rows, metric), id, window);
      return { series, svg: trendSvg(series, `${metric} (${metrics[metric].unit}), entity mean`) };
    },
  });
}
