#!/usr/bin/env python3
"""실험 D/E 결과 집계 (표준 라이브러리만 사용).

입력: experiments_de.sh 가 만든 csv_results/exp_<session>/<run_id>/
출력 (세션 폴더):
  summary_de_runs.csv        실행 1회 별: 붕괴 판정, 처리량·dropped·백분위수(k6 요약), 원인 지표
  summary_de_tc.csv          실행 1회 × (tc, api) 별 지연 (InfluxDB 원시 데이터)
  summary_de_conditions.csv  조건 별 (exp, arch, pool, rate, light) 3회 집계
  summary_de_throttle.csv    풀 크기 × rate × 아키텍처 별 DB/API CPU 스로틀링 비율
  gate.txt                   중단 조건 판정 (기준 조건 풀 500:100, 480 rps) — 아키텍처별
  gate_eligible.txt          실험 D 인과 판정 대상 아키텍처 (기준 조건에서 붕괴가 1회 이상 관측된 것)

시계: clock_checks.csv(풀 블록 전환마다 기록)를 실행 시각과 맞춰, 실행이 속한 검사 구간의 드리프트를
      clock_drift_pct 로 붙임. |드리프트| > 3% 인 구간의 실행은 clock_ok=0 (사용 금지)

붕괴 판정 기준 (계획에서 고정):
  붕괴 구간  1초 완료 반복 수 < 목표 rate × 50% 가 5초 이상 연속, 그 구간에 활성 VU >= 600
  붕괴 실행  붕괴 구간 1개 이상, 또는 480 rps 에서 dropped/목표 >= 1%
  안정       붕괴 구간 없음, dropped/목표 < 0.1%, 전체 TC p99 < 50 ms
  그 외      저하(degraded)
"""

import csv
import gzip
import json
import math
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summarize_experiments as se  # noqa: E402  (A/B/C 집계기의 함수 재사용, 파일은 수정하지 않음)

COLLAPSE_RATIO = 0.5
COLLAPSE_MIN_SECS = 5
COLLAPSE_MIN_VUS = 600
DROP_COLLAPSE_480 = 0.01
STABLE_DROP = 0.001
STABLE_P99_MS = 50
CLOCK_DRIFT_MAX_PCT = 3.0
CLOCK_MIN_INTERVAL_S = 120
BASELINE = {"pool": "500:100", "rate": "480", "light": "0"}
CPU_SATURATED_USEC_PER_SEC = 1.9e6  # 2코어 제한의 95%


def read_csv_any(path):
    """plain 또는 .gz CSV 를 읽음. experiments_de.sh 는 원시 지표를 gzip 으로 저장."""
    gz = Path(str(path) + ".gz") if not str(path).endswith(".gz") else Path(path)
    if gz.exists():
        with gzip.open(gz, "rt", newline="") as f:
            return list(csv.DictReader(f))
    if Path(path).exists():
        with open(path, newline="") as f:
            return list(csv.DictReader(f))
    return []


def read_influx_any(path):
    rows = read_csv_any(path)
    for r in rows:
        r["_t"] = se.parse_time(r["time"])
        r["_v"] = float(r["value"]) if r.get("value") not in (None, "") else math.nan
    return rows


# A/B/C 집계기의 summarize_run 이 gzip 원시 데이터를 읽도록 읽기 함수만 교체
se.read_influx_csv = read_influx_any


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return math.nan


def duration_sec(s):
    s = s.strip()
    if s.endswith("m"):
        return int(s[:-1]) * 60
    if "m" in s:
        m, sec = s.rstrip("s").split("m")
        return int(m) * 60 + int(sec or 0)
    return int(s.rstrip("s"))


def container_ips(run_dir):
    ips = {}
    p = run_dir / "container_ips.txt"
    if p.exists():
        for line in p.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                ips[parts[0]] = parts[1]
    return ips


def collapse_episodes(run, run_dir, rate, dur):
    """1초 단위 완료 반복 수로 붕괴 구간을 찾음."""
    iters = read_influx_any(run_dir / "iterations.csv")
    if not iters:
        return [], math.nan, [], math.nan
    vus = read_influx_any(run_dir / "vus.csv")
    # 시작 시각은 첫 반복 기준 (vus 지표는 첫 반복보다 약 1초 늦게 기록됨)
    t0 = min(int(r["_t"].timestamp()) for r in iters + vus)
    per_sec = defaultdict(float)
    for r in iters:
        per_sec[int(r["_t"].timestamp())] += r["_v"]
    vus_by_sec = defaultdict(float)
    for r in vus:
        s = int(r["_t"].timestamp())
        vus_by_sec[s] = max(vus_by_sec[s], r["_v"])
    # 첫·마지막 1초는 경계에 걸리므로 제외. graceful stop 구간(예정 시간 이후)도 제외
    secs = list(range(t0 + 1, t0 + dur - 1))
    counts = [per_sec.get(s, 0.0) for s in secs]

    def vus_near(s):
        vals = [vus_by_sec[x] for x in (s - 1, s, s + 1) if x in vus_by_sec]
        return max(vals) if vals else math.nan

    episodes, start = [], None
    for s, c in zip(secs + [None], counts + [None]):
        low = s is not None and c < rate * COLLAPSE_RATIO
        if low and start is None:
            start = s
        elif not low and start is not None:
            end = (s if s is not None else secs[-1] + 1) - 1
            length = end - start + 1
            peak_vus = max(vus_near(x) for x in range(start, end + 1))
            if length >= COLLAPSE_MIN_SECS and (math.isnan(peak_vus) or peak_vus >= COLLAPSE_MIN_VUS):
                episodes.append({"start_offset_s": start - t0, "length_s": length, "peak_vus": peak_vus,
                                 "min_iter_per_s": min(per_sec.get(x, 0.0) for x in range(start, end + 1))})
            start = None
    mean = statistics.fmean(counts) if counts else math.nan
    cv = statistics.pstdev(counts) / mean if counts and mean else math.nan
    return episodes, cv, counts, max((r["_v"] for r in vus), default=math.nan)


def cgroup_summary(path):
    rows = read_csv_any(path)
    rows = [r for r in rows if r.get("epoch", "").isdigit() and r.get("usage_usec", "").isdigit()]
    if len(rows) < 2:
        return {}
    first, last = rows[0], rows[-1]

    def d(k):
        return int(last[k]) - int(first[k])

    wall = int(last["epoch"]) - int(first["epoch"])
    saturated = 0
    for a, b in zip(rows, rows[1:]):
        dt = int(b["epoch"]) - int(a["epoch"])
        if dt > 0 and (int(b["usage_usec"]) - int(a["usage_usec"])) / dt >= CPU_SATURATED_USEC_PER_SEC:
            saturated += dt
    return {
        "samples": len(rows),
        "cpu_mean_pct": d("usage_usec") / wall / 1e4 if wall else math.nan,
        "throttled_period_ratio": d("nr_throttled") / d("nr_periods") if d("nr_periods") else math.nan,
        "throttled_sec": d("throttled_usec") / 1e6,
        "cpu_saturated_sec": saturated,
    }


def pool_summary(path):
    stats = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            i = line.find("{")
            if i >= 0:
                try:
                    stats.append(json.loads(line[i:]))
                except json.JSONDecodeError:
                    pass
    if len(stats) < 2:
        return {"pool_samples": len(stats)}
    first, last = stats[0], stats[-1]
    return {
        "pool_samples": len(stats),
        "pool_max_open": max(s["open"] for s in stats),
        "pool_max_in_use": max(s["in_use"] for s in stats),
        "pool_wait_count": last["wait_count"] - first["wait_count"],
        "pool_wait_sec": (last["wait_duration_us"] - first["wait_duration_us"]) / 1e6,
        "pool_max_idle_closed": last["max_idle_closed"] - first["max_idle_closed"],
    }


def pg_summary(run_dir, target_ip):
    per_time = defaultdict(lambda: defaultdict(int))
    for r in read_csv_any(run_dir / "pg_activity.csv"):
        try:
            n = int(r["count"])
        except (KeyError, ValueError):
            continue
        cur = per_time[r["time"]]
        cur["backends"] += n
        if r["client_addr"] == target_ip:
            cur["target_conns"] += n
            if r["state"] == "active":
                cur["target_active"] += n
        if r["wait_event_type"] == "LWLock" and r["wait_event"] == "ProcArray":
            cur["procarray"] += n
        if r["wait_event_type"] in ("LWLock", "Lock", "IO"):
            cur["lock_like"] += n
    out = {"pg_samples": len(per_time)}
    for k in ("backends", "target_conns", "target_active", "procarray", "lock_like"):
        out[f"pg_max_{k}"] = max((c[k] for c in per_time.values()), default=math.nan)
    db = read_csv_any(run_dir / "pg_db_stats.csv")
    db = [r for r in db if r.get("sessions", "").isdigit()]
    out["pg_db_stats_samples"] = len(db)
    out["pg_sessions_opened"] = int(db[-1]["sessions"]) - int(db[0]["sessions"]) if len(db) >= 2 else math.nan
    return out


def sample_interval_check(run_dir):
    """1초 간격 수집기의 실제 샘플 간격 중앙값·최대 (초)."""
    out = {}
    for name, key, parse in (
        ("pg_activity.csv", "time", lambda v: se.parse_time(v + "+09:00").timestamp()),
        ("pg_db_stats.csv", "time", lambda v: se.parse_time(v + "+09:00").timestamp()),
        ("cgroup_db.csv", "epoch", float),
        ("cgroup_api.csv", "epoch", float),
    ):
        ts = sorted({parse(r[key]) for r in read_csv_any(run_dir / name) if r.get(key)})
        gaps = [b - a for a, b in zip(ts, ts[1:])]
        out[f"interval_{name.split('.')[0]}"] = (f"{statistics.median(gaps):.2f}/{max(gaps):.2f}" if gaps else "")
    lines = [ln for ln in (run_dir / "pool_stats.log").read_text().splitlines()] if (run_dir / "pool_stats.log").exists() else []
    ms = [json.loads(ln[ln.find("{"):])["unix_ms"] / 1000 for ln in lines if "{" in ln]
    gaps = [b - a for a, b in zip(ms, ms[1:])]
    out["interval_pool_stats"] = f"{statistics.median(gaps):.2f}/{max(gaps):.2f}" if gaps else ""
    return out


def summarize_run(run, run_dir):
    rate = int(run["rate"])
    dur = duration_sec(run["duration"])
    m = json.loads((run_dir / "k6_summary.json").read_text())["metrics"] if (run_dir / "k6_summary.json").exists() else {}
    durm = m.get("http_req_duration") or m.get("grpc_req_duration") or {}
    dropped = m.get("dropped_iterations", {}).get("count", 0)
    completed = m.get("iterations", {}).get("count", 0)
    drop_ratio = dropped / (rate * dur)
    episodes, cv, _, active_vus_max = collapse_episodes(run, run_dir, rate, dur)
    p99 = durm.get("p(99)", math.nan)

    if episodes or (rate == 480 and drop_ratio >= DROP_COLLAPSE_480):
        verdict = "collapse"
    elif drop_ratio < STABLE_DROP and p99 < STABLE_P99_MS:
        verdict = "stable"
    else:
        verdict = "degraded"

    ips = container_ips(run_dir)
    target = {"rest": "benchmark_rest", "graphql": "benchmark_graphql", "grpc": "benchmark_grpc"}[run["arch"]]
    row = {k: run[k] for k in ("run_id", "exp", "arch", "pool_open", "pool_idle", "rate", "duration", "light", "rep")}
    row.update({
        "pool": f"{run['pool_open']}:{run['pool_idle']}",
        "verdict": verdict,
        "collapse_episodes": len(episodes),
        "collapse_total_s": sum(e["length_s"] for e in episodes),
        "first_collapse_offset_s": episodes[0]["start_offset_s"] if episodes else "",
        "completed_per_scheduled_sec": completed / dur,
        "dropped": dropped,
        "dropped_ratio": drop_ratio,
        "iter_per_sec_cv": cv,
        "k6_p50_ms": durm.get("med", math.nan),
        "k6_p95_ms": durm.get("p(95)", math.nan),
        "k6_p99_ms": p99,
        "k6_p999_ms": durm.get("p(99.9)", math.nan),
        "k6_active_vus_max": active_vus_max,  # vus 지표의 최대 (vus_max 는 사전 할당 수라 항상 PRE_VUS)
        "influx_completeness": num(run["influx_completeness"]),
        "mem_available_kb": run["mem_available_kb"],
        "swap_used_kb": run["swap_used_kb"],
        "cache_dropped": run["cache_dropped"],
    })
    for prefix, name in (("db", "cgroup_db.csv"), ("api", "cgroup_api.csv")):
        for k, v in cgroup_summary(run_dir / name).items():
            row[f"{prefix}_{k}"] = v
    row.update(pg_summary(run_dir, ips.get(target, "")))
    row.update(pool_summary(run_dir / "pool_stats.log"))
    row.update(sample_interval_check(run_dir))
    return row


def fmt(v):
    if isinstance(v, float):
        return "" if math.isnan(v) else f"{v:.4f}"
    return v


def write_csv(path, rows):
    if not rows:
        print(f"  - {path.name}: 데이터 없음")
        return
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(r.get(k, "")) for k in keys})
    print(f"  - {path.name}: {len(rows)}행")


def load_clock_checks(d):
    rows = []
    for r in read_csv_any(d / "clock_checks.csv"):
        try:
            rows.append({"id": r["check_id"], "realtime": float(r["realtime"]), "interval": num(r["interval_mono_s"]),
                         "drift": num(r["drift_pct_interval"]), "freq": r.get("ntp_freq_ppm", ""), "leap": r.get("chrony_leap", "")})
        except (KeyError, ValueError):
            continue
    return sorted(rows, key=lambda x: x["realtime"])


def clock_state(checks, started, ended):
    """실행 구간 [started, ended] 를 덮는 검사 구간(직전 검사 ≤ started, 다음 검사 ≥ ended)의 드리프트."""
    if not checks:
        return {"clock_check_id": "", "clock_drift_pct": math.nan, "clock_ok": ""}
    try:
        t0 = datetime.strptime(started, "%Y-%m-%dT%H:%M:%S%z").timestamp()
        t1 = datetime.strptime(ended, "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except ValueError:
        return {"clock_check_id": "", "clock_drift_pct": math.nan, "clock_ok": ""}
    before = [c for c in checks if c["realtime"] <= t0]
    after = [c for c in checks if c["realtime"] >= t1]
    if not before or not after:
        return {"clock_check_id": "", "clock_drift_pct": math.nan, "clock_ok": "unchecked"}
    c = after[0]
    if math.isnan(c["interval"]) or c["interval"] < CLOCK_MIN_INTERVAL_S:
        ok = "short_interval"
    else:
        ok = "1" if abs(c["drift"]) <= CLOCK_DRIFT_MAX_PCT else "0"
    return {"clock_check_id": f"{before[-1]['id']}-{c['id']}", "clock_drift_pct": c["drift"], "clock_ok": ok,
            "chrony_ntp_freq_ppm": c["freq"], "chrony_leap": c["leap"]}


def med_range(vals):
    vals = [v for v in vals if isinstance(v, (int, float)) and not math.isnan(v)]
    if not vals:
        return math.nan, math.nan, math.nan
    return statistics.median(vals), min(vals), max(vals)


def main():
    d = Path(sys.argv[1])
    with (d / "manifest.csv").open(newline="") as f:
        manifest = [r for r in csv.DictReader(f) if not r["run_id"].endswith("_incomplete")]

    checks = load_clock_checks(d)
    runs, tc_rows = [], []
    for run in manifest:
        run_dir = d / run["run_id"]
        if not run_dir.is_dir():
            print(f"  [경고] 폴더 없음: {run_dir}")
            continue
        row = summarize_run(run, run_dir)
        row.update(clock_state(checks, run["started"], run["ended"]))
        runs.append(row)
        # 개방 루프이므로 exp 를 C 로 넘겨 전 구간(all) 집계를 사용
        for r in se.summarize_run({**run, "exp": "C", "level": run["rate"], "cond": f"p{run['pool_open']}i{run['pool_idle']}_light{run['light']}"}, run_dir):
            r["exp"] = run["exp"]
            tc_rows.append(r)

    base = [r for r in runs if all(r[k] == v for k, v in BASELINE.items())]
    eligible = sorted({r["arch"] for r in base if r["verdict"] == "collapse"})
    for r in runs:
        r["d_causal_target"] = "1" if r["arch"] in eligible else "0"

    conds = defaultdict(list)
    for r in runs:
        conds[(r["exp"], r["arch"], r["pool"], r["rate"], r["light"])].append(r)
    cond_rows = []
    for (exp, arch, pool, rate, light), all_rs in sorted(conds.items(), key=lambda kv: (kv[0][0], kv[0][1], int(kv[0][2].split(":")[0]), int(kv[0][2].split(":")[1]), int(kv[0][3]), kv[0][4])):
        rs = [r for r in all_rs if r.get("clock_ok") != "0"]  # 시계 드리프트 초과 구간의 실행은 집계에서 제외
        row = {"exp": exp, "arch": arch, "pool": pool, "rate": rate, "light": light, "reps": len(rs),
               "collapse_runs": sum(r["verdict"] == "collapse" for r in rs),
               "stable_runs": sum(r["verdict"] == "stable" for r in rs),
               "d_causal_target": "1" if arch in eligible else "0",
               "clock_bad_runs": sum(r.get("clock_ok") == "0" for r in all_rs)}
        for k in ("completed_per_scheduled_sec", "dropped_ratio", "k6_p50_ms", "k6_p99_ms", "iter_per_sec_cv", "k6_active_vus_max",
                  "db_throttled_period_ratio", "db_cpu_saturated_sec", "pg_max_target_conns", "pg_max_procarray",
                  "pg_sessions_opened", "pool_wait_count", "pool_wait_sec"):
            mdn, lo, hi = med_range([r.get(k, math.nan) for r in rs])
            row[f"{k}_median"], row[f"{k}_min"], row[f"{k}_max"] = mdn, lo, hi
        cond_rows.append(row)

    throttle = defaultdict(list)
    for r in runs:
        if r["light"] == "0" and r["rate"] in ("480", "800") and r.get("clock_ok") != "0":
            throttle[(r["pool"], r["rate"], r["arch"])].append(r)
    throttle_rows = []
    for (pool, rate, arch), rs in sorted(throttle.items(), key=lambda kv: (int(kv[0][0].split(":")[0]), int(kv[0][0].split(":")[1]), int(kv[0][1]), kv[0][2])):
        throttle_rows.append({
            "pool": pool, "rate": rate, "arch": arch, "reps": len(rs),
            "db_throttled_period_ratio_mean": statistics.fmean([r.get("db_throttled_period_ratio", math.nan) for r in rs]),
            "db_throttled_sec_mean": statistics.fmean([r.get("db_throttled_sec", math.nan) for r in rs]),
            "db_cpu_mean_pct_mean": statistics.fmean([r.get("db_cpu_mean_pct", math.nan) for r in rs]),
            "api_throttled_period_ratio_mean": statistics.fmean([r.get("api_throttled_period_ratio", math.nan) for r in rs]),
            "collapse_runs": sum(r["verdict"] == "collapse" for r in rs),
        })

    lines = [f"기준 조건 (풀 500:100, 480 rps, light0): {len(base)}회 실행, 붕괴 {sum(r['verdict'] == 'collapse' for r in base)}회 — 아키텍처별 판정"]
    for arch in ("rest", "graphql", "grpc"):
        rs = sorted((r for r in base if r["arch"] == arch), key=lambda x: x["rep"])
        n_collapse = sum(r["verdict"] == "collapse" for r in rs)
        status = "판정 대상" if arch in eligible else ("제외 (붕괴 미관측)" if rs else "실행 없음")
        lines.append(f"  {arch:8} {len(rs)}회 중 붕괴 {n_collapse}회 → {status}  "
                     + ", ".join(f"rep{r['rep']}={r['verdict']}(구간 {r['collapse_episodes']}, drop {r['dropped_ratio'] * 100:.2f}%, 시계 {r.get('clock_ok') or '-'})" for r in rs))
    if base:
        lines.append("실험 D 인과 판정 대상: " + (" ".join(eligible) if eligible else "없음 → 중단 조건 해당 (본 실험 진행하지 않음)"))
    (d / "gate.txt").write_text("\n".join(lines) + "\n")
    (d / "gate_eligible.txt").write_text(" ".join(eligible))
    bad_clock = [r["run_id"] for r in runs if r.get("clock_ok") == "0"]
    if bad_clock:
        lines.append(f"[경고] 시계 드리프트 3% 초과 구간의 실행 {len(bad_clock)}회: 분석에서 제외할 것")

    print(f"[집계] {d}")
    write_csv(d / "summary_de_runs.csv", runs)
    write_csv(d / "summary_de_tc.csv", tc_rows)
    write_csv(d / "summary_de_conditions.csv", cond_rows)
    write_csv(d / "summary_de_throttle.csv", throttle_rows)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
