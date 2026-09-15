#!/usr/bin/env python3
"""summary_de_*.csv 로부터 실험 D/E 보고서(report_de.md)를 생성합니다.

사용법: make_report_de.py csv_results/exp_<session>
표기: 3회 중앙값 [최소–최대]. 처리량·dropped·백분위수는 k6 요약 기준.
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path

POOL_ORDER = ["20:20", "50:50", "100:100", "500:100", "500:500"]
ARCHS = ("rest", "graphql", "grpc")


def load(path):
    if not path.exists():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def cell(r, key, nd=1, scale=1.0, suffix=""):
    try:
        m, lo, hi = (float(r[f"{key}_{s}"]) * scale for s in ("median", "min", "max"))
    except (KeyError, ValueError):
        return "–"
    return f"{m:.{nd}f}{suffix} [{lo:.{nd}f}–{hi:.{nd}f}]"


def main():
    d = Path(sys.argv[1])
    conds = load(d / "summary_de_conditions.csv")
    throttle = load(d / "summary_de_throttle.csv")
    runs = load(d / "summary_de_runs.csv")
    idx = {(r["exp"], r["arch"], r["pool"], r["rate"], r["light"]): r for r in conds}

    out = []
    w = out.append
    w(f"# 실험 D/E 결과 보고서 — 세션 `{d.name}`\n")
    w(f"- 실행 {len(runs)}회. 표기는 `3회 중앙값 [최소–최대]`, 처리량·dropped·백분위수는 k6 요약 기준")
    w("- 붕괴 실행: 1초 완료 반복 수 < 목표의 50% 가 5초 이상(활성 VU ≥ 600) 또는 480 rps 에서 dropped ≥ 1%\n")

    eligible = set((d / "gate_eligible.txt").read_text().split()) if (d / "gate_eligible.txt").exists() else set(ARCHS)
    gate = d / "gate.txt"
    if gate.exists():
        w("## 중단 조건 (기준 조건 풀 500:100, 480 rps)\n")
        w("```\n" + gate.read_text().strip() + "\n```\n")

    w("## 실험 D — 풀 크기별 붕괴와 처리량\n")
    excluded = [a for a in ARCHS if a not in eligible]
    if excluded:
        w(f"> 인과 판정 제외: {', '.join(excluded)} (기준 조건에서 붕괴 미관측). 해당 행은 참고용으로만 표시\n")
    for rate in ("480", "800"):
        w(f"### {rate} rps\n")
        w("| 풀 (open:idle) | 아키텍처 | 붕괴/실행 | 완료 iter/s | dropped | 전 TC p99 ms | 1초 처리량 변동계수 | DB 스로틀링 주기 비율 | DB CPU 포화 초 | ProcArray 대기 최대 | 연결 생성 수 | 풀 대기 초 |")
        w("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for pool in POOL_ORDER:
            for arch in ARCHS:
                r = idx.get(("D", arch, pool, rate, "0"))
                if not r:
                    continue
                label = arch if arch in eligible else f"{arch} (제외)"
                w(f"| {pool} | {label} | {r['collapse_runs']}/{r['reps']} | {cell(r, 'completed_per_scheduled_sec', 0)} | "
                  f"{cell(r, 'dropped_ratio', 1, 100, '%')} | {cell(r, 'k6_p99_ms', 1)} | {cell(r, 'iter_per_sec_cv', 3)} | "
                  f"{cell(r, 'db_throttled_period_ratio', 1, 100, '%')} | {cell(r, 'db_cpu_saturated_sec', 0)} | "
                  f"{cell(r, 'pg_max_procarray', 0)} | {cell(r, 'pg_sessions_opened', 0)} | {cell(r, 'pool_wait_sec', 2)} |")
        w("")

    w("## 풀 크기별 DB CPU 스로틀링 (실험 D 전 구간, 3회 평균)\n")
    w("| 풀 | rate | 아키텍처 | 스로틀링 주기 비율 | 스로틀링 시간(초) | DB CPU 평균 % | API 스로틀링 주기 비율 | 붕괴 실행 |")
    w("|---|---|---|---|---|---|---|---|")
    for r in sorted(throttle, key=lambda r: (POOL_ORDER.index(r["pool"]) if r["pool"] in POOL_ORDER else 99, int(r["rate"]), r["arch"])):
        w(f"| {r['pool']} | {r['rate']} | {r['arch']} | {float(r['db_throttled_period_ratio_mean']) * 100:.1f}% | "
          f"{float(r['db_throttled_sec_mean']):.1f} | {float(r['db_cpu_mean_pct_mean']):.0f} | "
          f"{float(r['api_throttled_period_ratio_mean']) * 100:.1f}% | {r['collapse_runs']} |")

    w("\n## 실험 E — GraphQL TC3 쿼리 수 보정 (풀 500:100)\n")
    w("| rate | 조건 | 붕괴/실행 | 완료 iter/s | dropped | 전 TC p99 ms | DB 스로틀링 주기 비율 |")
    w("|---|---|---|---|---|---|---|")
    for rate in ("480", "640", "800"):
        rows = []
        for arch, light, label in (("graphql", "1", "GraphQL light (19 쿼리)"), ("graphql", "0", "GraphQL 기존 (24 쿼리)"),
                                   ("rest", "0", "REST"), ("grpc", "0", "gRPC")):
            exp = "E" if (light == "1" or rate == "640") else "D"
            r = idx.get((exp, arch, "500:100", rate, light))
            if r:
                rows.append(f"| {rate} | {label} | {r['collapse_runs']}/{r['reps']} | {cell(r, 'completed_per_scheduled_sec', 0)} | "
                            f"{cell(r, 'dropped_ratio', 1, 100, '%')} | {cell(r, 'k6_p99_ms', 1)} | {cell(r, 'db_throttled_period_ratio', 1, 100, '%')} |")
        out.extend(rows)

    w("\n## 시계 검사 (풀 블록 전환마다)\n")
    checks = []
    if (d / "clock_checks.csv").exists():
        with (d / "clock_checks.csv").open(newline="") as f:
            checks = list(csv.DictReader(f))
    if checks:
        w("| # | 시각 | 시점 | 구간(초) | 드리프트 % | 세션 누적 % | NTP 대비 속도 오차 ppm | NTP 대비 오프셋 s | PHC0 대비 오프셋 s | chrony 상태 |")
        w("|---|---|---|---|---|---|---|---|---|---|")
        for c in checks:
            w(f"| {c['check_id']} | {c['time']} | {c['label']} | {c['interval_mono_s']} | {c['drift_pct_interval']} | {c['drift_pct_session']} | "
              f"{c.get('ntp_freq_ppm', '')} | {c.get('ntp_offset_s', '')} | {c.get('phc_offset_s', '')} | {c.get('chrony_leap', '')} |")
    else:
        w("- clock_checks.csv 없음")

    w("\n## 데이터 품질\n")
    incomplete = [r["run_id"] for r in runs if r.get("influx_completeness") and float(r["influx_completeness"]) < 0.999]
    dropped_cache = sum(r.get("cache_dropped") == "1" for r in runs)
    w(f"- InfluxDB 저장률 0.999 미만 실행: {len(incomplete)}회 {incomplete if incomplete else ''}")
    w(f"- 실행 전 페이지 캐시 비우기 발생: {dropped_cache}회")
    bad_clock = [r["run_id"] for r in runs if r.get("clock_ok") == "0"]
    w(f"- 시계 드리프트 3% 초과 구간의 실행(집계 제외): {len(bad_clock)}회 {bad_clock if bad_clock else ''}")

    (d / "report_de.md").write_text("\n".join(out) + "\n")
    print(f"[완료] {d / 'report_de.md'}")


if __name__ == "__main__":
    main()
