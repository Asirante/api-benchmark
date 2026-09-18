#!/usr/bin/env python3
"""후속 분석 표 생성 (논문용).

  pool-size <세션> [--contrast-ref <세션>]
      풀 크기(20/50/100/500:100/500:500) × 아키텍처 × rate(640, 800) 달성 처리량·p99·병목 유형 표.
      480 rps 대조 행은 --contrast-ref 세션(풀 500:100)의 데이터를 출처와 함께 붙임.
  e2 <세션> [--ref <세션>]
      실험 E 재실행(풀 50:50): GraphQL light(19쿼리) vs 기존(24쿼리) 가설 2 판정.
      같은 세션에 REST·gRPC 가 없으면 --ref 세션의 같은 풀·rate 값을 참조로 사용.
  capacity <세션>
      적정 풀(20:20, 50:50)에서 rate 별 달성률로 실제 포화 지점과 DB/API CPU 상한 도달 여부.

입력은 summarize_de.py 가 만든 summary_de_runs.csv. 표기는 3회 중앙값 [최소–최대].
"""

import argparse
import csv
import math
import statistics
from pathlib import Path

ARCHS = ("rest", "graphql", "grpc")
POOL_ORDER = ("20:20", "50:50", "100:100", "500:100", "500:500")

# 병목 유형 판정 (조건별 3회 중앙값 기준, 실행 전 고정)
DB_CONTENTION_THROTTLE = 0.50   # DB CPU 스로틀링 주기 비율 ≥ 50% → DB 경합
API_WAIT_API_THROTTLE = 0.90    # API 스로틀링 ≥ 90%
API_WAIT_DB_THROTTLE = 0.30     #   & DB 스로틀링 < 30%
API_WAIT_POOL_MS = 10.0         #   & 풀 대기 ≥ 10 ms/반복
SLOW_P99_MS = 100.0             #   & p99 ≥ 100 ms → API 측 대기(API CPU·풀 대기)
OK_ACHIEVED = 0.99              # 달성률 ≥ 99% & p99 < 100 ms → 정상

# 가설 2 판정 (실행 전 고정)
H2_P99_SUPPORT = -0.30          # light 의 p99 가 기존 대비 30% 이상 감소 & 3회 범위 비중첩 → 쿼리 수가 원인으로 지지
H2_P99_NONE = 0.10              # |변화| < 10% 이거나 범위 중첩 → 차이 없음

# 가설 2 처리 한계 판정 (쿼리 수 보정 조건에서 아키텍처 간 차이가 남는지, 실행 전 고정)
H2_CAP_DIFF = 0.05             # 최대 달성 처리량 차이 5% 이상 & 3회 [최소–최대] 범위 비중첩 → 유의한 차이
                               #   차이 < 5% 이거나 범위 중첩 → 차이 없음 / 그 외 불확실

# 포화 판정
SATURATION_ACHIEVED = 0.95      # 달성률 중앙값 < 95% → 목표 미달
CPU_CAP_FRACTION = 0.50         # CPU 가 제한의 95% 이상인 시간이 실행의 50% 이상 → 상한 도달


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return math.nan


def overlaps(a, b):
    """두 구간 [min, max] 이 겹치는지"""
    return not (a[1] < b[0] or b[1] < a[0])


def load_runs(session):
    p = Path(session) / "summary_de_runs.csv"
    with p.open(newline="") as f:
        rows = list(csv.DictReader(f))
    return [r for r in rows if r.get("clock_ok") != "0"]


def mmm(rows, key, scale=1.0):
    vals = [num(r.get(key)) * scale for r in rows]
    vals = [v for v in vals if not math.isnan(v)]
    if not vals:
        return (math.nan, math.nan, math.nan)
    return (statistics.median(vals), min(vals), max(vals))


def fmt(t, nd=0, suffix=""):
    if math.isnan(t[0]):
        return "–"
    return f"{t[0]:.{nd}f}{suffix} [{t[1]:.{nd}f}–{t[2]:.{nd}f}]"


def duration_s(r):
    s = r.get("duration", "60s").strip()
    return int(s.rstrip("s")) if s.rstrip("s").isdigit() else 60


def condition_stats(rows, rate):
    it = [num(r["completed_per_scheduled_sec"]) * duration_s(r) for r in rows]
    pool_ms = [num(r.get("pool_wait_sec")) * 1000 / i if i else math.nan for r, i in zip(rows, it)]
    pool_ms = [v for v in pool_ms if not math.isnan(v)]
    return {
        "n": len(rows),
        "achieved": mmm(rows, "completed_per_scheduled_sec"),
        "achieved_ratio": mmm(rows, "completed_per_scheduled_sec", 1 / int(rate)),
        "p50": mmm(rows, "k6_p50_ms"),
        "p95": mmm(rows, "k6_p95_ms"),
        "p99": mmm(rows, "k6_p99_ms"),
        "db_thr": mmm(rows, "db_throttled_period_ratio"),
        "api_thr": mmm(rows, "api_throttled_period_ratio"),
        "db_cpu": mmm(rows, "db_cpu_mean_pct"),
        "api_cpu": mmm(rows, "api_cpu_mean_pct"),
        "db_cap_share": mmm([{"x": num(r.get("db_cpu_saturated_sec")) / duration_s(r)} for r in rows], "x"),
        "api_cap_share": mmm([{"x": num(r.get("api_cpu_saturated_sec")) / duration_s(r)} for r in rows], "x"),
        "procarray": mmm(rows, "pg_max_procarray"),
        "sessions": mmm(rows, "pg_sessions_opened"),
        "pool_wait_ms": (statistics.median(pool_ms), min(pool_ms), max(pool_ms)) if pool_ms else (math.nan,) * 3,
        "verdicts": {v: sum(r["verdict"] == v for r in rows) for v in ("stable", "degraded", "saturated", "collapse")},
    }


def bottleneck(c):
    if c["db_thr"][0] >= DB_CONTENTION_THROTTLE:
        return "DB 경합"
    if c["db_thr"][2] >= DB_CONTENTION_THROTTLE:  # 중앙값은 정상이지만 일부 실행이 DB 경합
        bad = c["verdicts"]["collapse"] + c["verdicts"]["saturated"]
        return f"간헐적 DB 경합 ({bad}/{c['n']})"
    if (c["api_thr"][0] >= API_WAIT_API_THROTTLE and c["db_thr"][0] < API_WAIT_DB_THROTTLE
            and c["pool_wait_ms"][0] >= API_WAIT_POOL_MS and c["p99"][0] >= SLOW_P99_MS):
        return "API 측 대기"
    if c["achieved_ratio"][0] >= OK_ACHIEVED and c["p99"][0] < SLOW_P99_MS:
        return "정상"
    return "혼합"


def select(runs, arch, pool, rate, light="0"):
    return [r for r in runs if r["arch"] == arch and r["pool"] == pool and r["rate"] == str(rate) and r["light"] == light]


def write_outputs(out_dir, name, header, rows, md_lines):
    with (out_dir / f"{name}.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    (out_dir / f"{name}.md").write_text("\n".join(md_lines) + "\n")
    print(f"[완료] {out_dir / name}.csv, .md")


# ---------------------------------------------------------------------------
def cmd_pool_size(args):
    d = Path(args.session)
    runs = load_runs(d)
    ref_runs = load_runs(args.contrast_ref) if args.contrast_ref else []
    header = ["rate", "arch", "pool", "source_session", "reps", "achieved_median", "achieved_min", "achieved_max",
              "p99_ms_median", "p99_ms_min", "p99_ms_max", "db_throttle_median", "api_throttle_median",
              "pool_wait_ms_per_iter_median", "procarray_max_median", "new_db_sessions_median", "bottleneck"]
    csv_rows, md = [], [f"# 풀 크기와 성능 (세션 `{d.name}`)", "",
                        "표기: 3회 중앙값 [최소–최대]. 병목 유형 규칙: DB 스로틀링 ≥ 50% → **DB 경합** / "
                        "API 스로틀링 ≥ 90% & DB 스로틀링 < 30% & 풀 대기 ≥ 10 ms/반복 & p99 ≥ 100 ms → **API 측 대기** / "
                        "달성률 ≥ 99% & p99 < 100 ms → **정상** / 그 외 **혼합**", ""]
    plan = [("640", POOL_ORDER, runs), ("800", POOL_ORDER, runs)]
    for rate, pools, src in plan:
        md += [f"## {rate} rps", "",
               "| 아키텍처 | 풀 | 붕괴·포화/실행 | 달성 iter/s | p99 ms | DB 스로틀링 | API 스로틀링 | 풀 대기 ms/반복 | ProcArray 대기 | 새 DB 연결 | 병목 유형 |",
               "|---|---|---|---|---|---|---|---|---|---|---|"]
        for arch in ARCHS:
            for pool in pools:
                rs = select(src, arch, pool, rate)
                if not rs:
                    continue
                c = condition_stats(rs, rate)
                b = bottleneck(c)
                bad = c["verdicts"]["collapse"] + c["verdicts"]["saturated"]
                md.append(f"| {arch} | {pool} | {bad}/{c['n']} | {fmt(c['achieved'])} | {fmt(c['p99'], 1)} | {c['db_thr'][0] * 100:.1f}% | "
                          f"{c['api_thr'][0] * 100:.1f}% | {fmt(c['pool_wait_ms'], 1)} | {fmt(c['procarray'])} | {fmt(c['sessions'])} | {b} |")
                csv_rows.append([rate, arch, pool, d.name, c["n"], *c["achieved"], *c["p99"], c["db_thr"][0], c["api_thr"][0],
                                 c["pool_wait_ms"][0], c["procarray"][0], c["sessions"][0], b])
        md.append("")
    # 480 rps 대조
    md += ["## 480 rps 대조 (용량의 약 70%)", "",
           "| 아키텍처 | 풀 | 데이터 출처 세션 | 달성 iter/s | p99 ms | DB 스로틀링 | DB CPU % | 새 DB 연결 |",
           "|---|---|---|---|---|---|---|---|"]
    for arch in ARCHS:
        for pool, src, name in (("20:20", runs, d.name), ("500:100", ref_runs, Path(args.contrast_ref).name if args.contrast_ref else "")):
            rs = select(src, arch, pool, "480")
            if not rs:
                continue
            c = condition_stats(rs, "480")
            note = f"`{name}`" + (" **(전날 세션)**" if name != d.name else "")
            md.append(f"| {arch} | {pool} | {note} | {fmt(c['achieved'])} | {fmt(c['p99'], 1)} | {c['db_thr'][0] * 100:.1f}% | {fmt(c['db_cpu'])} | {fmt(c['sessions'])} |")
            csv_rows.append(["480", arch, pool, name, c["n"], *c["achieved"], *c["p99"], c["db_thr"][0], c["api_thr"][0],
                             c["pool_wait_ms"][0], c["procarray"][0], c["sessions"][0], bottleneck(c)])
    md.append("")
    md.append("> 480 rps 의 풀 500:100 행은 세션 `de_20260916_0241`(2026-09-16 02:41 시작) 데이터입니다. "
              "풀 20:20 행과 같은 코드·이미지·시계 상태이지만 세션이 다르므로, 세션 간 차이를 배제할 수 없습니다.")
    write_outputs(d, "pool_size_table", header, csv_rows, md)


# ---------------------------------------------------------------------------
def cmd_e2(args):
    d = Path(args.session)
    runs = load_runs(d)
    ref = load_runs(args.ref) if args.ref else []
    pool = args.pool
    md = [f"# 실험 E 재실행 — 가설 2 판정 (풀 {pool}, 세션 `{d.name}`)", "",
          f"규칙(실행 전 고정): light(19쿼리)의 p99 중앙값이 기존(24쿼리) 대비 {abs(H2_P99_SUPPORT):.0%} 이상 감소 & 3회 범위 비중첩 → "
          f"**쿼리 수가 p99 차이의 원인으로 지지** / |변화| < {H2_P99_NONE:.0%} 이거나 범위 중첩 → **차이 없음** / 그 외 **불확실**.",
          "격차 해소율 = (기존 p99 − light p99) / (기존 p99 − REST·gRPC 중 높은 p99). API 스로틀링 ≥ 90% 인데 light 의 p99 가 여전히 높으면 "
          "남은 차이는 GraphQL 서버 처리 비용(API CPU)으로 해석.", ""]
    header = ["rate", "condition", "source_session", "reps", "achieved_median", "p99_median", "p99_min", "p99_max",
              "db_throttle_median", "api_throttle_median", "api_cpu_median", "db_cpu_median"]
    csv_rows = []
    for rate in args.rates.split():
        md += [f"## {rate} rps", "",
               "| 조건 | 데이터 출처 | 달성 iter/s | p99 ms | DB 스로틀링 | API 스로틀링 | API CPU % | DB CPU % |",
               "|---|---|---|---|---|---|---|---|"]
        stats = {}
        for label, arch, light in (("GraphQL light (19)", "graphql", "1"), ("GraphQL 기존 (24)", "graphql", "0"),
                                   ("REST", "rest", "0"), ("gRPC", "grpc", "0")):
            rs, src = select(runs, arch, pool, rate, light), d.name
            if not rs and ref:
                rs, src = select(ref, arch, pool, rate, light), Path(args.ref).name
            if not rs:
                continue
            c = condition_stats(rs, rate)
            stats[label] = c
            md.append(f"| {label} | `{src}`{' (참조 세션)' if src != d.name else ''} | {fmt(c['achieved'])} | {fmt(c['p99'], 1)} | "
                      f"{c['db_thr'][0] * 100:.1f}% | {c['api_thr'][0] * 100:.1f}% | {c['api_cpu'][0]:.0f} | {c['db_cpu'][0]:.0f} |")
            csv_rows.append([rate, label, src, c["n"], c["achieved"][0], *c["p99"], c["db_thr"][0], c["api_thr"][0], c["api_cpu"][0], c["db_cpu"][0]])
        lt, base = stats.get("GraphQL light (19)"), stats.get("GraphQL 기존 (24)")
        if lt and base:
            rel = (lt["p99"][0] - base["p99"][0]) / base["p99"][0]
            overlap = not (lt["p99"][2] < base["p99"][1] or base["p99"][2] < lt["p99"][1])
            if rel <= H2_P99_SUPPORT and not overlap:
                verdict = "쿼리 수가 p99 차이의 원인으로 지지"
            elif abs(rel) < H2_P99_NONE or overlap:
                verdict = "차이 없음"
            else:
                verdict = "불확실"
            refs = [stats[k]["p99"][0] for k in ("REST", "gRPC") if k in stats]
            gap = ""
            if refs and base["p99"][0] > max(refs):
                gap = f", 격차 해소율 {(base['p99'][0] - lt['p99'][0]) / (base['p99'][0] - max(refs)) * 100:.0f}%"
            thr_both = "달성률 모두 ≥ 99%" if min(lt["achieved_ratio"][0], base["achieved_ratio"][0]) >= OK_ACHIEVED else "달성률 차이 있음"
            residual = ""
            if lt["api_thr"][0] >= API_WAIT_API_THROTTLE and refs and lt["p99"][0] > max(refs) * 1.5:
                residual = " / light 에서도 API 스로틀링 ≥ 90% 이고 p99 가 REST·gRPC 의 1.5배 초과 → 남은 차이는 GraphQL 서버 처리 비용으로 해석"
            md += ["", f"**판정 ({rate} rps): {verdict}** (p99 {base['p99'][0]:.1f} → {lt['p99'][0]:.1f} ms, {rel * 100:+.0f}%, "
                       f"범위 중첩 {'예' if overlap else '아니오'}{gap}; {thr_both}; DB 스로틀링 {base['db_thr'][0] * 100:.1f}% → {lt['db_thr'][0] * 100:.1f}%){residual}"]
        md.append("")
    write_outputs(d, "e2_decision", header, csv_rows, md)


# ---------------------------------------------------------------------------
def cmd_capacity(args):
    d = Path(args.session)
    runs = load_runs(d)
    rates = sorted({int(r["rate"]) for r in runs})
    pools = [p for p in POOL_ORDER if any(r["pool"] == p for r in runs)]
    md = [f"# 적정 풀에서의 실제 처리 한계 (세션 `{d.name}`)", "",
          f"목표 미달: 달성률 중앙값 < {SATURATION_ACHIEVED:.0%}. CPU 상한 도달: CPU 가 제한(2코어)의 95% 이상인 시간이 실행의 {CPU_CAP_FRACTION:.0%} 이상.", ""]
    header = ["pool", "arch", "rate", "reps", "achieved_ratio_median", "achieved_median", "p99_median", "db_cpu_median",
              "db_cap_share_median", "db_throttle_median", "api_cpu_median", "api_cap_share_median", "api_throttle_median", "below_target"]
    csv_rows, summary = [], []
    for pool in pools:
        md += [f"## 풀 {pool}", "",
               "| 아키텍처 | rate | 달성률 | 달성 iter/s | p99 ms | DB CPU % | DB 상한 도달 | DB 스로틀링 | API CPU % | API 상한 도달 | API 스로틀링 | 판정(안/저/포/붕) |",
               "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        first_fail = {}
        for arch in ARCHS:
            for rate in rates:
                rs = select(runs, arch, pool, rate)
                if not rs:
                    continue
                c = condition_stats(rs, rate)
                below = c["achieved_ratio"][0] < SATURATION_ACHIEVED
                if below and arch not in first_fail:
                    first_fail[arch] = (rate, c)
                v = c["verdicts"]
                md.append(f"| {arch} | {rate} | {c['achieved_ratio'][0] * 100:.1f}% | {fmt(c['achieved'])} | {fmt(c['p99'], 1)} | {c['db_cpu'][0]:.0f} | "
                          f"{'예' if c['db_cap_share'][0] >= CPU_CAP_FRACTION else '아니오'} ({c['db_cap_share'][0] * 100:.0f}%) | {c['db_thr'][0] * 100:.1f}% | "
                          f"{c['api_cpu'][0]:.0f} | {'예' if c['api_cap_share'][0] >= CPU_CAP_FRACTION else '아니오'} ({c['api_cap_share'][0] * 100:.0f}%) | "
                          f"{c['api_thr'][0] * 100:.1f}% | {v['stable']}/{v['degraded']}/{v['saturated']}/{v['collapse']} |")
                csv_rows.append([pool, arch, rate, c["n"], c["achieved_ratio"][0], c["achieved"][0], c["p99"][0], c["db_cpu"][0],
                                 c["db_cap_share"][0], c["db_thr"][0], c["api_cpu"][0], c["api_cap_share"][0], c["api_thr"][0], int(below)])
        md.append("")
        for arch in ARCHS:
            if arch in first_fail:
                rate, c = first_fail[arch]
                where = [n for n, share in (("DB", c["db_cap_share"][0]), ("API", c["api_cap_share"][0])) if share >= CPU_CAP_FRACTION]
                summary.append(f"- 풀 {pool} · {arch}: **{rate} rps 에서 처음 목표 미달** (달성률 {c['achieved_ratio'][0] * 100:.1f}%, "
                               f"CPU 상한 도달: {', '.join(where) if where else '없음'})")
            else:
                summary.append(f"- 풀 {pool} · {arch}: 측정한 최고 rate({max(rates)} rps)까지 목표 달성 — 포화 미관측")
        all_fail = [rate for rate in rates if all(
            select(runs, a, pool, rate) and condition_stats(select(runs, a, pool, rate), rate)["achieved_ratio"][0] < SATURATION_ACHIEVED for a in ARCHS)]
        summary.append(f"- 풀 {pool}: 세 아키텍처가 모두 목표 미달인 최저 rate = "
                       + (f"**{min(all_fail)} rps**" if all_fail else f"없음 ({max(rates)} rps 까지 모두 미달인 지점 없음)"))
    md = md[:3] + ["", "## 요약", ""] + summary + [""] + md[3:]
    write_outputs(d, "capacity_table", header, csv_rows, md)


def cmd_capacity_h2(args):
    """쿼리 수를 19개로 맞춘 조건에서 처리 한계 재측정 (풀 고정, 같은 세션 안에서 비교)."""
    d = Path(args.session)
    runs = load_runs(d)
    pool = args.pool
    rates = sorted({int(r["rate"]) for r in runs})
    conds = [("GraphQL light (19쿼리)", "graphql", "1"), ("GraphQL 기존 (24쿼리)", "graphql", "0"),
             ("REST (19쿼리)", "rest", "0"), ("gRPC (19쿼리)", "grpc", "0")]
    header = ["condition", "arch", "light", "rate", "reps", "achieved_mean", "achieved_min", "achieved_max",
              "achieved_ratio_pct", "p50_mean_ms", "p95_mean_ms", "p99_mean_ms", "p99_min_ms", "p99_max_ms",
              "api_cpu_mean_pct", "api_cap_share_pct", "db_cpu_mean_pct", "db_throttle_mean_pct", "bottleneck", "source_session"]
    csv_rows, md = [], [f"# 쿼리 수 보정 조건의 처리 한계 (풀 {pool}, 세션 `{d.name}`)", "",
                        "표기: 3회 평균 [최소–최대]. 병목 유형·목표 미달 기준은 기존과 동일(실행 전 고정).", "",
                        "| 조건 | 목표 rate | 달성 iter/s | 달성률 | p50 | p95 | p99 | API CPU | API 상한 도달 | DB CPU | DB 스로틀링 | 병목 |",
                        "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    peak = {}
    for label, arch, light in conds:
        for rate in rates:
            rs = [r for r in runs if r["arch"] == arch and r["light"] == light and r["pool"] == pool and r["rate"] == str(rate)]
            if not rs:
                continue
            c = condition_stats(rs, rate)
            dur = duration_s(rs[0])
            api_cap = statistics.fmean([num(r["api_cpu_saturated_sec"]) / dur * 100 for r in rs])
            b = bottleneck(c)
            if label not in peak or c["achieved"][0] > peak[label]["achieved"][0]:
                peak[label] = {**c, "rate": rate, "bottleneck": b}
            md.append(f"| {label} | {rate} | {fmt(c['achieved'], 0)} | {c['achieved_ratio'][0] * 100:.1f}% | {c['p50'][0]:.1f} | "
                      f"{c['p95'][0]:.1f} | {fmt(c['p99'], 1)} | {c['api_cpu'][0]:.0f}% | {api_cap:.0f}% | {c['db_cpu'][0]:.0f}% | "
                      f"{c['db_thr'][0] * 100:.1f}% | {b} |")
            csv_rows.append([label, arch, light, rate, c["n"], *c["achieved"], c["achieved_ratio"][0] * 100,
                             c["p50"][0], c["p95"][0], *c["p99"], c["api_cpu"][0], api_cap, c["db_cpu"][0],
                             c["db_thr"][0] * 100, b, d.name])

    md += ["", "## 조건별 최대 달성 처리량 (평평해지는 값)", "",
           "| 조건 | 최대 달성 iter/s | 관측 rate | 병목 |", "|---|---|---|---|"]
    for label in [c[0] for c in conds if c[0] in peak]:
        p = peak[label]
        md.append(f"| {label} | {fmt(p['achieved'], 0)} | {p['rate']} rps | {p['bottleneck']} |")

    md += ["", "## 판정 (실행 전 고정한 규칙)", "",
           f"- 유의한 차이: 최대 달성 처리량 차이 {H2_CAP_DIFF:.0%} 이상 & 3회 [최소–최대] 범위 비중첩",
           f"- 차이 없음: 차이 {H2_CAP_DIFF:.0%} 미만 이거나 범위 중첩 / 그 외: 불확실", ""]
    light = peak.get("GraphQL light (19쿼리)")
    refs = {k: peak[k] for k in ("REST (19쿼리)", "gRPC (19쿼리)") if k in peak}
    if light and refs:
        lower_ref_label = min(refs, key=lambda k: refs[k]["achieved"][0])
        ref = refs[lower_ref_label]
        rel = (light["achieved"][0] - ref["achieved"][0]) / ref["achieved"][0]
        ov = overlaps(light["achieved"][1:], ref["achieved"][1:])
        if rel <= -H2_CAP_DIFF and not ov:
            verdict = "쿼리 수를 맞춘 뒤에도 GraphQL 의 처리 한계가 유의하게 낮음"
        elif abs(rel) < H2_CAP_DIFF or ov:
            verdict = "차이 없음 (쿼리 수를 맞추면 처리 한계가 REST·gRPC 수준)"
        else:
            verdict = "불확실"
        md.append(f"**핵심 질문 판정: {verdict}** — GraphQL light {light['achieved'][0]:.0f} "
                  f"[{light['achieved'][1]:.0f}–{light['achieved'][2]:.0f}] vs 낮은 쪽 기준 {lower_ref_label} "
                  f"{ref['achieved'][0]:.0f} [{ref['achieved'][1]:.0f}–{ref['achieved'][2]:.0f}] iter/s, "
                  f"{rel * 100:+.1f}%, 범위 중첩 {'예' if ov else '아니오'}")
    base = peak.get("GraphQL 기존 (24쿼리)")
    if light and base:
        rel = (light["achieved"][0] - base["achieved"][0]) / base["achieved"][0]
        ov = overlaps(light["achieved"][1:], base["achieved"][1:])
        eff = ("보정 효과 있음" if rel >= H2_CAP_DIFF and not ov
               else "차이 없음" if abs(rel) < H2_CAP_DIFF or ov else "불확실")
        md.append("")
        md.append(f"**보정 전후 (24 → 19쿼리): {eff}** — {base['achieved'][0]:.0f} "
                  f"[{base['achieved'][1]:.0f}–{base['achieved'][2]:.0f}] → {light['achieved'][0]:.0f} "
                  f"[{light['achieved'][1]:.0f}–{light['achieved'][2]:.0f}] iter/s, {rel * 100:+.1f}%, "
                  f"범위 중첩 {'예' if ov else '아니오'}")
    all_below = [rate for rate in rates if all(
        (lambda rs: rs and condition_stats(rs, rate)["achieved_ratio"][0] < SATURATION_ACHIEVED)(
            [r for r in runs if r["arch"] == a and r["light"] == l and r["pool"] == pool and r["rate"] == str(rate)])
        for _, a, l in conds)]
    md += ["", f"- 네 조건이 모두 목표 미달인 최저 rate: " + (f"**{min(all_below)} rps**" if all_below else "없음")]
    write_outputs(d, "capacity_h2", header, csv_rows, md)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pool-size"); p.add_argument("session"); p.add_argument("--contrast-ref")
    p = sub.add_parser("e2"); p.add_argument("session"); p.add_argument("--ref"); p.add_argument("--pool", default="50:50"); p.add_argument("--rates", default="640 800")
    p = sub.add_parser("capacity"); p.add_argument("session")
    p = sub.add_parser("capacity-h2"); p.add_argument("session"); p.add_argument("--pool", default="50:50")
    a = ap.parse_args()
    {"pool-size": cmd_pool_size, "e2": cmd_e2, "capacity": cmd_capacity, "capacity-h2": cmd_capacity_h2}[a.cmd](a)


if __name__ == "__main__":
    main()
