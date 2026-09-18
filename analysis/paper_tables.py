#!/usr/bin/env python3
"""논문용 표·그림 데이터 생성. 출력: paper/ (CSV + 마크다운)

  표 A  지터 유무별 TC1/TC5 p99 (아키텍처 × 300/400/500 VUs)            세션 exp_20260915_030551
  표 B  풀 크기별 달성 처리량·p99·DB 스로틀링 (640 / 800 rps)            세션 exp_de_20260916_1154
  표 C  적정 풀에서의 처리 한계                                          세션 exp_de_caph2_20260918_1436 (쿼리 수 보정 조건, 주 표)
                                                                         + exp_de_20260916_1154 · exp_de_cap_20260918_0345 (보정 전, 참고)
  표 D  실험 A(tc5 vs tc5_slim) · 실험 E(19 vs 24 쿼리) 요약              세션 exp_20260915_030551 + exp_de_e2_20260917_1243
  그림 1  풀 크기 대비 달성 처리량 (800 rps)
  그림 2  rate 대비 달성 처리량과 API/DB CPU (적정 풀)
  그림 3  지터 유무별 p99 (500 VUs)

모든 셀은 3회 평균과 [최소–최대]. 폐쇄 루프(실험 A/B) 지연은 VU 유지 구간(steady) 기준.
"""

import csv
import math
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "paper"
CSVD = ROOT / "csv_results"
S_ABC = "exp_20260915_030551"
S_D = "exp_de_20260916_1154"
S_E2 = "exp_de_e2_20260917_1243"
S_CAP = "exp_de_cap_20260918_0345"
S_CAPH2 = "exp_de_caph2_20260918_1436"
ARCHS = ("rest", "graphql", "grpc")
ARCH_LABEL = {"rest": "REST", "graphql": "GraphQL", "grpc": "gRPC"}
POOLS = ("20:20", "50:50", "100:100", "500:100", "500:500")
TC_API = {"tc1": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
          "tc5": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"}}


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return math.nan


def load(session, name):
    p = CSVD / session / name
    with p.open(newline="") as f:
        return list(csv.DictReader(f))


def mmm(rows, key, scale=1.0):
    """3회 평균, 최소, 최대"""
    v = [num(r.get(key)) * scale for r in rows]
    v = [x for x in v if not math.isnan(x)]
    if not v:
        return (math.nan,) * 3
    return (st.fmean(v), min(v), max(v))


def cell(t, nd=1, suffix=""):
    if math.isnan(t[0]):
        return "–"
    return f"{t[0]:.{nd}f}{suffix} [{t[1]:.{nd}f}–{t[2]:.{nd}f}]"


def cond(rows, **kw):
    return [r for r in rows if all(str(r.get(k)) == str(v) for k, v in kw.items())]


def emit(name, header, rows, md_title, md_head, md_rows, notes=()):
    OUT.mkdir(exist_ok=True)
    with (OUT / f"{name}.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    md = [md_title, "", "표기: 3회 평균 [최소–최대]", ""] + md_head + md_rows
    if notes:
        md += [""] + [f"> {n}" for n in notes]
    (OUT / f"{name}.md").write_text("\n".join(md) + "\n")
    print(f"[완료] paper/{name}.csv, paper/{name}.md ({len(rows)}행)")


# --------------------------------------------------------------------- 표 A
def table_a():
    c = load(S_ABC, "summary_conditions.csv")
    header = ["tc", "arch", "vus", "jitter", "p99_mean_ms", "p99_min_ms", "p99_max_ms",
              "mean_mean_ms", "p50_mean_ms", "p95_mean_ms", "reps", "source_session"]
    rows, md = [], []
    for tc in ("tc1", "tc5"):
        for arch in ARCHS:
            for vus in ("300", "400", "500"):
                cells = {}
                for jit in ("jitter0", "jitter1"):
                    r = cond(c, exp="B", arch=arch, cond=jit, level=vus, window="steady", tc=tc, api=TC_API[tc][arch])
                    if not r:
                        continue
                    r = r[0]
                    cells[jit] = r
                    rows.append([tc, arch, vus, "없음" if jit == "jitter0" else "있음",
                                 num(r["p99_avg"]), num(r["p99_min"]), num(r["p99_max"]),
                                 num(r["mean_avg"]), num(r["p50_avg"]), num(r["p95_avg"]), r["reps"], S_ABC])
                if len(cells) == 2:
                    a, b = cells["jitter0"], cells["jitter1"]
                    ratio = num(b["p99_avg"]) / num(a["p99_avg"])
                    md.append(f"| {tc.upper()} | {ARCH_LABEL[arch]} | {vus} | "
                              f"{num(a['p99_avg']):.2f} [{num(a['p99_min']):.2f}–{num(a['p99_max']):.2f}] | "
                              f"{num(b['p99_avg']):.2f} [{num(b['p99_min']):.2f}–{num(b['p99_max']):.2f}] | {ratio:.2f}배 |")
    emit("table_a_jitter_p99", header, rows,
         "# 표 A. 지터 유무별 p99 (TC1·TC5, 폐쇄 루프, VU 유지 구간)",
         ["| TC | 아키텍처 | VUs | p99 지터 없음 (ms) | p99 지터 있음 (ms) | 비율 |", "|---|---|---|---|---|---|"], md,
         [f"출처 세션 `{S_ABC}`. 지터 없음 = 반복 끝 `sleep(1)`, 지터 있음 = `sleep(Math.random()*2)`(평균 1초 동일).",
          "폐쇄 루프이므로 부하는 VU 수로 주어지며, 두 조건의 처리량은 같다(유지 구간 초당 약 290/385/480 반복)."])


# --------------------------------------------------------------------- 표 B
def table_b():
    runs = [r for r in load(S_D, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    header = ["rate", "arch", "pool_open", "pool_idle", "achieved_mean", "achieved_min", "achieved_max",
              "p99_mean_ms", "p99_min_ms", "p99_max_ms", "db_throttle_mean_pct", "db_throttle_min_pct", "db_throttle_max_pct",
              "api_throttle_mean_pct", "pool_wait_ms_per_iter_mean", "new_db_sessions_mean", "procarray_max_mean",
              "collapse_or_saturated_runs", "reps", "source_session"]
    rows, md = [], []
    for rate in ("640", "800"):
        dur = 180 if rate == "640" else 60
        for arch in ARCHS:
            for pool in POOLS:
                rs = cond(runs, arch=arch, pool=pool, rate=rate, light="0")
                if not rs:
                    continue
                ach, p99 = mmm(rs, "completed_per_scheduled_sec"), mmm(rs, "k6_p99_ms")
                thr = mmm(rs, "db_throttled_period_ratio", 100)
                api = mmm(rs, "api_throttled_period_ratio", 100)
                pw = st.fmean([num(r["pool_wait_sec"]) * 1000 / (num(r["completed_per_scheduled_sec"]) * dur) for r in rs])
                bad = sum(r["verdict"] in ("collapse", "saturated") for r in rs)
                rows.append([rate, arch, *pool.split(":"), *ach, *p99, *thr, api[0], pw,
                             mmm(rs, "pg_sessions_opened")[0], mmm(rs, "pg_max_procarray")[0], bad, len(rs), S_D])
                md.append(f"| {rate} | {ARCH_LABEL[arch]} | {pool} | {cell(ach, 0)} | {cell(p99)} | {cell(thr, 1, '%')} | {bad}/{len(rs)} |")
    emit("table_b_pool_size", header, rows,
         "# 표 B. 풀 크기별 달성 처리량·p99·DB CPU 스로틀링 (개방 루프)",
         ["| 목표 rate | 아키텍처 | 풀 (open:idle) | 달성 iter/s | p99 (ms) | DB 스로틀링 | 붕괴·포화/실행 |",
          "|---|---|---|---|---|---|---|"], md,
         [f"출처 세션 `{S_D}`. 640 rps 는 180초, 800 rps 는 60초 실행.",
          "붕괴 = 초당 완료 반복 수가 목표의 50% 미만인 구간 5초 이상(활성 VU ≥ 600) 또는 dropped ≥ 1%(포화 아닐 때).",
          "CSV 에는 API 스로틀링·풀 대기(ms/반복)·새 DB 연결 수·ProcArray 대기도 포함."])


# --------------------------------------------------------------------- 표 C
def table_c():
    d_runs = [r for r in load(S_D, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    cap_runs = [r for r in load(S_CAP, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    h2_runs = [r for r in load(S_CAPH2, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    header = ["block", "condition", "pool", "arch", "light", "rate", "achieved_mean", "achieved_min", "achieved_max",
              "achieved_ratio_mean_pct", "p50_mean_ms", "p95_mean_ms", "p99_mean_ms", "p99_min_ms", "p99_max_ms",
              "api_cpu_mean_pct", "api_cap_share_mean_pct", "db_cpu_mean_pct", "db_throttle_mean_pct", "reps", "source_session"]
    rows, md_main, md_ref = [], [], []

    def add(block, label, pool, arch, light, rate, src, session, md):
        rs = cond(src, arch=arch, pool=pool, rate=rate, light=light)
        if not rs:
            return
        ach, p99 = mmm(rs, "completed_per_scheduled_sec"), mmm(rs, "k6_p99_ms")
        ratio = ach[0] / rate * 100
        api_cpu, db_cpu = mmm(rs, "api_cpu_mean_pct"), mmm(rs, "db_cpu_mean_pct")
        api_cap = st.fmean([num(r["api_cpu_saturated_sec"]) / 60 * 100 for r in rs])
        thr = mmm(rs, "db_throttled_period_ratio", 100)
        p50, p95 = mmm(rs, "k6_p50_ms"), mmm(rs, "k6_p95_ms")
        rows.append([block, label, pool, arch, light, rate, *ach, ratio, p50[0], p95[0], *p99,
                     api_cpu[0], api_cap, db_cpu[0], thr[0], len(rs), session])
        md.append(f"| {label} | {pool} | {rate} | {cell(ach, 0)} | {ratio:.1f}% | {p50[0]:.1f} | {cell(p99)} | "
                  f"{api_cpu[0]:.0f}% | {api_cap:.0f}% | {db_cpu[0]:.0f}% | {thr[0]:.1f}% |")

    # 주 표: 반복당 쿼리 수를 19개로 맞춘 조건 (풀 50:50, 같은 세션 안에서 비교)
    for label, arch, light in (("REST (19쿼리)", "rest", "0"), ("gRPC (19쿼리)", "grpc", "0"),
                               ("GraphQL light (19쿼리)", "graphql", "1"), ("GraphQL 기존 (24쿼리)", "graphql", "0")):
        for rate in (800, 900, 1000, 1100):
            add("보정 조건", label, "50:50", arch, light, rate, h2_runs, S_CAPH2, md_main)
    # 참고: 보정 전 측정 (GraphQL 24쿼리, 풀 20:20·50:50)
    for pool in ("20:20", "50:50"):
        for arch in ARCHS:
            for rate, src, session in ((800, d_runs, S_D), (900, cap_runs, S_CAP), (1000, cap_runs, S_CAP),
                                       (1100, cap_runs, S_CAP), (1200, cap_runs, S_CAP)):
                add("보정 전", ARCH_LABEL[arch], pool, arch, "0", rate, src, session, md_ref)

    emit("table_c_capacity", header, rows,
         "# 표 C. 처리 한계 (개방 루프, 60초)",
         ["## C-1. 반복당 쿼리 수를 19개로 맞춘 조건 (풀 50:50, 단일 세션)", "",
          "| 조건 | 풀 | 목표 rate | 달성 iter/s | 달성률 | p50 (ms) | p99 (ms) | API CPU | API 상한 도달 | DB CPU | DB 스로틀링 |",
          "|---|---|---|---|---|---|---|---|---|---|---|"], md_main + [""] +
         ["## C-2. 보정 전 측정 (참고)", "",
          "| 아키텍처 | 풀 | 목표 rate | 달성 iter/s | 달성률 | p50 (ms) | p99 (ms) | API CPU | API 상한 도달 | DB CPU | DB 스로틀링 |",
          "|---|---|---|---|---|---|---|---|---|---|---|"] + md_ref,
         [f"C-1 출처 세션 `{S_CAPH2}`(2026-09-18, 48회). GraphQL light 는 `GQL_TC3_LIGHT=1` 로 반복당 쿼리를 24 → 19개로 맞춘 조건.",
          f"C-2 출처: 800 rps 는 `{S_D}`, 900~1200 rps 는 `{S_CAP}`. GraphQL 은 24쿼리 조건이다.",
          "CPU 는 컨테이너 제한 200%(2코어) 기준. 상한 도달 시간 = CPU 가 제한의 95% 이상인 시간이 실행에서 차지하는 비율.",
          "목표 미달 기준은 달성률 95% 미만(실행 전 고정)."])


# --------------------------------------------------------------------- 표 D
def table_d():
    c = load(S_ABC, "summary_conditions.csv")
    e2 = [r for r in load(S_E2, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    header = ["experiment", "condition", "load", "metric", "mean", "min", "max", "unit", "reps", "source_session"]
    rows, md = [], []
    # 실험 A: REST tc5 (전체 객체) vs tc5_slim (GraphQL TC5 와 같은 필드)
    for vus in ("300", "400", "500"):
        got = {}
        for tc, label in (("tc5", "tc5 (전체 객체, 7회 SELECT *)"), ("tc5_slim", "tc5_slim (필드 축소, 4회 컬럼 지정)")):
            r = cond(c, exp="A", arch="rest", cond="slim", level=vus, window="steady", tc=tc, api="rest")
            if not r:
                continue
            r = r[0]
            got[tc] = r
            for metric, key in (("mean", "mean"), ("p50", "p50"), ("p95", "p95"), ("p99", "p99")):
                rows.append(["A", label, f"{vus} VUs", metric, num(r[f"{key}_avg"]), num(r[f"{key}_min"]), num(r[f"{key}_max"]), "ms", r["reps"], S_ABC])
        if len(got) == 2:
            a, b = got["tc5"], got["tc5_slim"]
            md.append(f"| A | REST {vus} VUs | p50 {num(a['p50_avg']):.2f} → {num(b['p50_avg']):.2f} ({num(b['p50_avg'])/num(a['p50_avg'])-1:+.0%}) | "
                      f"p99 {num(a['p99_avg']):.2f} [{num(a['p99_min']):.2f}–{num(a['p99_max']):.2f}] → "
                      f"{num(b['p99_avg']):.2f} [{num(b['p99_min']):.2f}–{num(b['p99_max']):.2f}] ({num(b['p99_avg'])/num(a['p99_avg'])-1:+.0%}) |")
    # 실험 E: GraphQL 24쿼리 vs 19쿼리 (풀 50:50)
    for rate in ("640", "800"):
        got = {}
        for light, label in (("0", "GraphQL 기존 (24 쿼리)"), ("1", "GraphQL light (19 쿼리)")):
            rs = cond(e2, arch="graphql", pool="50:50", rate=rate, light=light)
            if not rs:
                continue
            got[light] = rs
            for metric, key, sc in (("achieved", "completed_per_scheduled_sec", 1), ("p99", "k6_p99_ms", 1),
                                    ("db_cpu", "db_cpu_mean_pct", 1), ("api_throttle", "api_throttled_period_ratio", 100)):
                t = mmm(rs, key, sc)
                rows.append(["E", label, f"{rate} rps", metric, *t, {"achieved": "iter/s", "p99": "ms"}.get(metric, "%"), len(rs), S_E2])
        if len(got) == 2:
            a, b = mmm(got["0"], "k6_p99_ms"), mmm(got["1"], "k6_p99_ms")
            da, db_ = mmm(got["0"], "db_cpu_mean_pct")[0], mmm(got["1"], "db_cpu_mean_pct")[0]
            md.append(f"| E | GraphQL {rate} rps (풀 50:50) | 달성 {mmm(got['0'], 'completed_per_scheduled_sec')[0]:.0f} → "
                      f"{mmm(got['1'], 'completed_per_scheduled_sec')[0]:.0f} iter/s (동일) | "
                      f"p99 {cell(a)} → {cell(b)} ({b[0]/a[0]-1:+.0%}), DB CPU {da:.0f}% → {db_:.0f}% |")
    emit("table_d_experiments_a_e", header, rows,
         "# 표 D. 실험 A(응답 필드 축소)와 실험 E(GraphQL 쿼리 수 보정) 요약",
         ["| 실험 | 조건 | 중앙 지연 변화 | 꼬리 지연·자원 변화 |", "|---|---|---|---|"], md,
         [f"실험 A 출처 세션 `{S_ABC}`(폐쇄 루프, VU 유지 구간). 실험 E 출처 세션 `{S_E2}`(개방 루프, 풀 50:50).",
          "실험 A 의 tc5_slim 은 GraphQL TC5 와 같은 필드를 반환하며 DB 조회가 7회 SELECT * → 4회 컬럼 지정으로 줄어든 조건.",
          "실험 E 의 light 는 GraphQL TC3 를 REST·gRPC 와 같은 DB 작업(반복당 24 → 19 쿼리)으로 맞춘 조건."])


# --------------------------------------------------------------------- 그림 1~3
def figures():
    OUT.mkdir(exist_ok=True)
    runs = [r for r in load(S_D, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    # 그림 1: 풀 크기(x, 로그축 권장) 대비 달성 처리량 (800 rps)
    with (OUT / "fig1_pool_vs_throughput_800rps.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["arch", "pool", "pool_open_x", "pool_idle", "achieved_mean", "achieved_min", "achieved_max",
                    "p99_mean_ms", "db_throttle_mean_pct", "api_throttle_mean_pct", "pool_wait_ms_per_iter_mean", "bottleneck"])
        for arch in ARCHS:
            for pool in POOLS:
                rs = cond(runs, arch=arch, pool=pool, rate="800", light="0")
                if not rs:
                    continue
                ach = mmm(rs, "completed_per_scheduled_sec")
                thr, api = mmm(rs, "db_throttled_period_ratio", 100)[0], mmm(rs, "api_throttled_period_ratio", 100)[0]
                p99 = mmm(rs, "k6_p99_ms")[0]
                pw = st.fmean([num(r["pool_wait_sec"]) * 1000 / (num(r["completed_per_scheduled_sec"]) * 60) for r in rs])
                if thr >= 50:
                    b = "DB 경합"
                elif api >= 90 and thr < 30 and pw >= 10 and p99 >= 100:
                    b = "API 측 대기"
                elif ach[0] / 800 >= 0.99 and p99 < 100:
                    b = "정상"
                else:
                    b = "혼합"
                w.writerow([arch, pool, pool.split(":")[0], pool.split(":")[1], *ach, p99, thr, api, pw, b])
    print("[완료] paper/fig1_pool_vs_throughput_800rps.csv")

    # 그림 2: rate 대비 달성 처리량과 API/DB CPU (적정 풀 20:20, 50:50)
    cap = [r for r in load(S_CAP, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    h2 = [r for r in load(S_CAPH2, "summary_de_runs.csv") if r.get("clock_ok") != "0"]
    with (OUT / "fig2_rate_vs_throughput_cpu.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["block", "condition", "pool", "arch", "light", "rate_x", "achieved_mean", "achieved_min", "achieved_max",
                    "achieved_ratio_pct", "p99_mean_ms", "api_cpu_mean_pct", "api_cap_share_pct",
                    "db_cpu_mean_pct", "db_cap_share_pct", "db_throttle_mean_pct", "source_session"])

        def line(block, label, pool, arch, light, rate, src, session, dur):
            rs = cond(src, arch=arch, pool=pool, rate=rate, light=light)
            if not rs:
                return
            ach = mmm(rs, "completed_per_scheduled_sec")
            w.writerow([block, label, pool, arch, light, rate, *ach, ach[0] / rate * 100, mmm(rs, "k6_p99_ms")[0],
                        mmm(rs, "api_cpu_mean_pct")[0], st.fmean([num(r["api_cpu_saturated_sec"]) / dur * 100 for r in rs]),
                        mmm(rs, "db_cpu_mean_pct")[0], st.fmean([num(r["db_cpu_saturated_sec"]) / dur * 100 for r in rs]),
                        mmm(rs, "db_throttled_period_ratio", 100)[0], session])

        for label, arch, light in (("REST (19쿼리)", "rest", "0"), ("gRPC (19쿼리)", "grpc", "0"),
                                   ("GraphQL light (19쿼리)", "graphql", "1"), ("GraphQL 기존 (24쿼리)", "graphql", "0")):
            for rate in (800, 900, 1000, 1100):
                line("보정 조건", label, "50:50", arch, light, rate, h2, S_CAPH2, 60)
        for pool in ("20:20", "50:50"):
            for arch in ARCHS:
                for rate, src, session in ((640, runs, S_D), (800, runs, S_D), (900, cap, S_CAP),
                                           (1000, cap, S_CAP), (1100, cap, S_CAP), (1200, cap, S_CAP)):
                    line("보정 전", ARCH_LABEL[arch], pool, arch, "0", rate, src, session, 180 if rate == 640 else 60)
    print("[완료] paper/fig2_rate_vs_throughput_cpu.csv")

    # 그림 3: 지터 유무별 p99 (500 VUs, 전 TC)
    c = load(S_ABC, "summary_conditions.csv")
    with (OUT / "fig3_jitter_p99_500vus.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["arch", "tc", "api_tag", "jitter", "p99_mean_ms", "p99_min_ms", "p99_max_ms",
                    "p50_mean_ms", "p95_mean_ms", "source_session"])
        for arch in ARCHS:
            for r in sorted((x for x in c if x["exp"] == "B" and x["arch"] == arch and x["level"] == "500"
                             and x["window"] == "steady"), key=lambda x: (x["tc"], x["cond"])):
                w.writerow([arch, r["tc"], r["api"], "없음" if r["cond"] == "jitter0" else "있음",
                            num(r["p99_avg"]), num(r["p99_min"]), num(r["p99_max"]), num(r["p50_avg"]), num(r["p95_avg"]), S_ABC])
    print("[완료] paper/fig3_jitter_p99_500vus.csv")


if __name__ == "__main__":
    table_a(); table_b(); table_c(); table_d(); figures()
