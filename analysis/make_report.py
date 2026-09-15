#!/usr/bin/env python3
"""summary_*.csv 로부터 실험 A/B/C 보고서(report.md)를 생성합니다.

사용법: make_report.py csv_results/exp_<session>
- 폐쇄 루프(A, B) 지연은 steady 구간(VU 목표치 유지 30초) 기준, 3회 평균 [최소–최대]
- 개방 루프(C) 처리량·dropped·전체 TC 백분위수는 k6 요약(JSON) 기준 (InfluxDB 쓰기 실패 영향 없음)
- 개방 루프 TC 별 지연은 InfluxDB 완전성이 99.9% 이상인 조건만 표시
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path

ARCHS = ("rest", "graphql", "grpc")
TC_API = {  # tc → arch 별 api 태그 (TC3 는 REST/gRPC 의 두 번째 호출을 대표로 사용)
    "tc1": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
    "tc2": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
    "tc3": {"rest": "rest_part2", "graphql": "graphql", "grpc": "grpc_part2"},
    "tc4": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
    "tc5": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
    "tc6": {"rest": "rest", "graphql": "graphql", "grpc": "grpc"},
    "tc7": {"rest": "rest_error", "graphql": "graphql_error", "grpc": "grpc_error"},
}


def load(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def rng(vals, nd=2):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "–"
    avg = sum(vals) / len(vals)
    return f"{avg:.{nd}f} [{min(vals):.{nd}f}–{max(vals):.{nd}f}]"


def cond_cell(r, stat, nd=2):
    return f"{float(r[stat + '_avg']):.{nd}f} [{float(r[stat + '_min']):.{nd}f}–{float(r[stat + '_max']):.{nd}f}]"


def main():
    d = Path(sys.argv[1])
    conds = {(r["exp"], r["arch"], r["cond"], r["level"], r["window"], r["tc"], r["api"]): r
             for r in load(d / "summary_conditions.csv")}
    open_rows = load(d / "summary_open_loop.csv")
    diag = {r["run_id"]: r for r in load(d / "summary_diagnostics.csv")}
    res = defaultdict(dict)
    for r in load(d / "summary_resources.csv"):
        res[r["run_id"]][r["role"]] = r
    manifest = load(d / "manifest.csv")

    out = []
    w = out.append
    w(f"# 실험 A/B/C 결과 보고서 — 세션 `{d.name}`\n")
    w(f"- 실행 {len(manifest)}회, {manifest[0]['started']} ~ {manifest[-1]['ended']}, k6 비정상 종료 "
      f"{sum(1 for m in manifest if m['k6_exit'] != '0')}회")
    w("- 폐쇄 루프 지연: VU 목표치 유지 구간(steady) 기준. 표기는 `3회 평균 [최소–최대]`, 단위 ms")
    w("- 개방 루프 처리량·dropped·전체 TC 백분위수: k6 요약(JSON) 기준\n")

    # ---------------------------------------------------------------- A
    w("## 실험 A — REST tc5 vs tc5_slim (같은 실행 안의 짝 비교)\n")
    w("| VUs | 조건 | mean | p50 | p95 | p99 |")
    w("|---|---|---|---|---|---|")
    for v in ("300", "400", "500"):
        rows = [("REST tc5 (전체 객체)", conds[("A", "rest", "slim", v, "steady", "tc5", "rest")]),
                ("REST tc5_slim", conds[("A", "rest", "slim", v, "steady", "tc5_slim", "rest")]),
                ("참고: GraphQL tc5 (실험 B jitter0)", conds[("B", "graphql", "jitter0", v, "steady", "tc5", "graphql")]),
                ("참고: gRPC tc5 (실험 B jitter0)", conds[("B", "grpc", "jitter0", v, "steady", "tc5", "grpc")])]
        for label, r in rows:
            w(f"| {v} | {label} | {cond_cell(r, 'mean')} | {cond_cell(r, 'p50')} | {cond_cell(r, 'p95')} | {cond_cell(r, 'p99')} |")
    w("\nslim 적용 시 변화율 (3회 평균 기준, 음수 = 감소):\n")
    w("| VUs | mean | p50 | p95 | p99 |")
    w("|---|---|---|---|---|")
    for v in ("300", "400", "500"):
        a = conds[("A", "rest", "slim", v, "steady", "tc5", "rest")]
        b = conds[("A", "rest", "slim", v, "steady", "tc5_slim", "rest")]
        cells = [f"{(float(b[s + '_avg']) / float(a[s + '_avg']) - 1) * 100:+.0f}%" for s in ("mean", "p50", "p95", "p99")]
        w(f"| {v} | " + " | ".join(cells) + " |")

    # ---------------------------------------------------------------- B
    w("\n## 실험 B — 반복 대기 지터\n")
    w("### TC1 (steady)\n")
    w("| VUs | 아키텍처 | 지터 | mean | p50 | p95 | p99 | p99 변동폭(최대-최소) |")
    w("|---|---|---|---|---|---|---|---|")
    for v in ("300", "400", "500"):
        for a in ARCHS:
            for c, label in (("jitter0", "없음"), ("jitter1", "있음")):
                r = conds[("B", a, c, v, "steady", "tc1", a)]
                w(f"| {v} | {a} | {label} | {cond_cell(r, 'mean')} | {cond_cell(r, 'p50')} | {cond_cell(r, 'p95')} | {cond_cell(r, 'p99')} | {float(r['p99_range']):.2f} |")
    w("\n### 전 TC p99 (steady, 3회 평균): 지터 없음 → 있음\n")
    w("| VUs | 아키텍처 | " + " | ".join(TC_API) + " |")
    w("|---|---|" + "---|" * len(TC_API))
    for v in ("300", "400", "500"):
        for a in ARCHS:
            cells = []
            for tc, apis in TC_API.items():
                r0 = conds[("B", a, "jitter0", v, "steady", tc, apis[a])]
                r1 = conds[("B", a, "jitter1", v, "steady", tc, apis[a])]
                cells.append(f"{float(r0['p99_avg']):.1f} → {float(r1['p99_avg']):.1f}")
            w(f"| {v} | {a} | " + " | ".join(cells) + " |")

    # ---------------------------------------------------------------- 전체 조건 표 (A, B)
    w("\n## 조건별 전 TC 지연 (A, B, steady)\n")
    w("| 실험 | VUs | 아키텍처 | 조건 | TC | api | mean | p50 | p95 | p99 | 실패율 |")
    w("|---|---|---|---|---|---|---|---|---|---|---|")
    for key in sorted(k for k in conds if k[0] in "AB" and k[4] == "steady"):
        r = conds[key]
        w(f"| {key[0]} | {key[3]} | {key[1]} | {key[2]} | {key[5]} | {key[6]} | {cond_cell(r, 'mean')} | {cond_cell(r, 'p50')} | {cond_cell(r, 'p95')} | {cond_cell(r, 'p99')} | {float(r['fail_rate_avg']):.3f} |")

    # ---------------------------------------------------------------- C
    w("\n## 실험 C — 개방 루프 (constant-arrival-rate, 60초)\n")
    w("| 목표 rate | 아키텍처 | 완료 iter/s (예정 60초 기준) | dropped | dropped / 목표 | 전 TC p50 | 전 TC p99 | API CPU% | DB CPU% | k6 CPU% (평균/최대) | InfluxDB 완전성 |")
    w("|---|---|---|---|---|---|---|---|---|---|---|")
    by = defaultdict(list)
    for r in open_rows:
        by[(int(r["rate_target"]), r["arch"])].append(r)
    for (rate, arch), rs in sorted(by.items()):
        runs = [r["run_id"] for r in rs]
        api = [num(res[x]["api"]["cpu_mean_pct"]) for x in runs]
        db = [num(res[x]["db"]["cpu_mean_pct"]) for x in runs]
        k6 = [num(res[x]["k6"]["cpu_mean_pct"]) for x in runs if "k6" in res[x]]
        k6max = max((num(res[x]["k6"]["cpu_max_pct"]) for x in runs if "k6" in res[x]), default=0)
        comp = min(num(r["influx_completeness"]) for r in rs)
        w(f"| {rate} | {arch} | {rng([num(r['k6_completed_per_scheduled_sec']) for r in rs], 0)} | "
          f"{rng([num(r['k6_summary_dropped']) for r in rs], 0)} | {rng([num(r['k6_dropped_ratio_of_target']) * 100 for r in rs], 1)}% | "
          f"{rng([num(r['k6_all_tc_p50_ms']) for r in rs])} | {rng([num(r['k6_all_tc_p99_ms']) for r in rs], 1)} | "
          f"{sum(api) / len(api):.0f} | {sum(db) / len(db):.0f} | {sum(k6) / len(k6):.0f} / {k6max:.0f} | "
          f"{'완전' if comp >= 0.999 else f'최소 {comp * 100:.1f}% ⚠'} |")

    w("\n### 개방 루프 TC 별 p99 (InfluxDB 완전한 조건만, 3회 평균 [최소–최대])\n")
    w("| 목표 rate | 아키텍처 | tc1 | tc3 | tc5 | tc6 |")
    w("|---|---|---|---|---|---|")
    for (rate, arch), rs in sorted(by.items()):
        if min(num(r["influx_completeness"]) for r in rs) < 0.999:
            continue
        cells = []
        for tc in ("tc1", "tc3", "tc5", "tc6"):
            r = conds.get(("C", arch, "open", str(rate), "all", tc, TC_API[tc][arch]))
            cells.append(cond_cell(r, "p99") if r else "–")
        w(f"| {rate} | {arch} | " + " | ".join(cells) + " |")

    # ---------------------------------------------------------------- 변동폭
    w("\n## 실행 간 변동 폭 (같은 조건 3회의 최대−최소, A·B steady)\n")
    w("| 통계 | 조건 수 | 변동폭 중앙값 (ms) | 변동폭 90백분위 (ms) | 최대 변동폭 (ms) | 최대인 조건 |")
    w("|---|---|---|---|---|---|")
    ab = [r for k, r in conds.items() if k[0] in "AB" and k[4] == "steady"]
    for stat in ("mean", "p50", "p95", "p99"):
        vals = sorted(((float(r[stat + "_range"]), r) for r in ab), key=lambda x: x[0])
        med = vals[len(vals) // 2][0]
        p90 = vals[int(len(vals) * 0.9)][0]
        top = vals[-1][1]
        w(f"| {stat} | {len(vals)} | {med:.2f} | {p90:.2f} | {vals[-1][0]:.2f} | {top['exp']} {top['arch']} {top['cond']} {top['level']}VUs {top['tc']} |")

    # ---------------------------------------------------------------- 진단
    w("\n## 멈춤/붕괴 진단\n")
    w("초당 완료 요청 수가 중앙값의 절반 미만으로 떨어진 초가 5초 이상인 실행 (InfluxDB 불완전 실행 제외):\n")
    w("| 실행 | 절반 미만 초 | 최저 초 | DB 활성 세션 최대 | LWLock 대기 최대 | Lock 대기 | 1초 초과 SQL | 체크포인트 | 호스트 swap-out 최대(KB/s) |")
    w("|---|---|---|---|---|---|---|---|---|")
    for rid, r in sorted(diag.items(), key=lambda kv: (kv[1]["exp"], int(kv[1]["level"]), kv[1]["arch"], kv[1]["rep"])):
        if (num(r["secs_below_half_median"]) or 0) >= 5 and (num(r["influx_completeness"]) or 0) >= 0.999:
            w(f"| {rid.rsplit('_', 2)[0]} | {r['secs_below_half_median']} | {r['worst_second'][11:19]} | {r['pg_active_max']} | "
              f"{r['pg_lwlock_wait_max']} | {r['pg_lock_wait_max']} | {r['db_slow_statements']} | {r['db_checkpoints']} | {r['host_swap_io_max']} |")

    (d / "report.md").write_text("\n".join(out) + "\n")
    print(f"[완료] {d / 'report.md'}")


if __name__ == "__main__":
    main()
