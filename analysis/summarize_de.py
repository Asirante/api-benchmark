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
# 포화 판정: DB CPU 가 제한(2코어)의 95% 이상인 시간이 실행의 절반 이상이거나,
#            달성 처리량이 목표의 95% 미만이면서 초당 처리량이 안정적(변동계수 < 0.25)인 경우
SATURATED_CPU_FRACTION = 0.5
SATURATED_ACHIEVED = 0.95
SATURATED_CV = 0.25
# 가설 1 대체 판정(포화 구간 풀 비교) 기준
POOL_EFFECT_STRONG = 0.10   # 처리량 10% 이상 차이 + 3회 범위 비중첩 → 효과 확인
POOL_EFFECT_NONE = 0.05     # 5% 미만이거나 범위 중첩 → 차이 없음
SMALL_POOLS = ("20:20", "50:50", "100:100")
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

    achieved = completed / dur / rate if rate else math.nan
    cpu_sat_sec = cgroup_summary(run_dir / "cgroup_db.csv").get("cpu_saturated_sec", 0)
    saturated = (cpu_sat_sec >= SATURATED_CPU_FRACTION * dur) or (achieved < SATURATED_ACHIEVED and cv < SATURATED_CV)

    # 붕괴와 포화 구분: 붕괴는 처리량이 일시적으로 무너지는 현상, 포화는 상한에서 안정적으로 눌린 상태
    if episodes or (drop_ratio >= DROP_COLLAPSE_480 and not saturated):
        verdict = "collapse"
    elif drop_ratio < STABLE_DROP and p99 < STABLE_P99_MS:
        verdict = "stable"
    elif saturated:
        verdict = "saturated"
    else:
        verdict = "degraded"

    ips = container_ips(run_dir)
    target = {"rest": "benchmark_rest", "graphql": "benchmark_graphql", "grpc": "benchmark_grpc"}[run["arch"]]
    row = {k: run[k] for k in ("run_id", "exp", "arch", "pool_open", "pool_idle", "rate", "duration", "light", "rep")}
    row.update({
        "pool": f"{run['pool_open']}:{run['pool_idle']}",
        "verdict": verdict,
        "saturated": "1" if saturated else "0",
        "achieved_ratio": achieved,
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


def load_meta(d):
    meta = {}
    p = d / "session_meta.txt"
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k.strip()] = v.strip()
    return meta


def read_manifest(d):
    with (d / "manifest.csv").open(newline="") as f:
        return [r for r in csv.DictReader(f) if not r["run_id"].endswith("_incomplete")]


def overlaps(a, b):
    """두 구간 [min,max] 이 겹치는지"""
    return not (a[1] < b[0] or b[1] < a[0])


def pool_comparison(runs, rate, arch, base_pool="500:100"):
    """포화 구간에서 풀 크기별 비교 (가설 1 대체 판정). 3회 중앙값과 [최소,최대] 사용."""
    by_pool = defaultdict(list)
    for r in runs:
        if r["arch"] == arch and r["rate"] == str(rate) and r["light"] == "0" and r.get("clock_ok") != "0":
            by_pool[r["pool"]].append(r)
    out = {}
    for pool, rs in by_pool.items():
        g = [r["completed_per_scheduled_sec"] for r in rs]
        out[pool] = {
            "n": len(rs), "goodput": med_range(g),
            "p99": med_range([r["k6_p99_ms"] for r in rs]),
            "throttle": med_range([r.get("db_throttled_period_ratio", math.nan) for r in rs]),
            "sessions": med_range([r.get("pg_sessions_opened", math.nan) for r in rs]),
            "procarray": med_range([r.get("pg_max_procarray", math.nan) for r in rs]),
            "pool_wait": med_range([r.get("pool_wait_sec", math.nan) for r in rs]),
            "collapse": sum(r["verdict"] == "collapse" for r in rs),
            "saturated": sum(r["verdict"] == "saturated" for r in rs),
        }
    return out


def judge_pool_effect(cmp_, base_pool="500:100", cand_pools=SMALL_POOLS):
    """고정 판정 규칙:
       확인   후보 풀 중앙값이 기준 대비 +10% 이상 & 3회 범위 비중첩 & p99 중앙값이 더 낮음
       없음   |차이| < 5% 이거나 범위 중첩
       불확실 그 외"""
    if base_pool not in cmp_:
        return "데이터 없음", {}
    b = cmp_[base_pool]
    best, best_rel = None, -9
    for p in cand_pools:
        if p not in cmp_ or math.isnan(cmp_[p]["goodput"][0]) or math.isnan(b["goodput"][0]) or b["goodput"][0] == 0:
            continue
        rel = (cmp_[p]["goodput"][0] - b["goodput"][0]) / b["goodput"][0]
        if rel > best_rel:
            best, best_rel = p, rel
    if best is None:
        return "데이터 없음", {}
    c = cmp_[best]
    ov = overlaps(c["goodput"][1:], b["goodput"][1:])
    p99_better = c["p99"][0] < b["p99"][0]
    if best_rel >= POOL_EFFECT_STRONG and not ov and p99_better:
        verdict = "확인"
    elif abs(best_rel) < POOL_EFFECT_NONE or ov:
        verdict = "차이 없음"
    else:
        verdict = "불확실"
    return verdict, {"pool": best, "rel": best_rel, "overlap": ov, "p99_better": p99_better,
                     "base": b, "cand": c}


def main():
    d = Path(sys.argv[1])
    extra_dirs = [Path(x) for x in sys.argv[2:]]
    meta = load_meta(d)
    manifest = read_manifest(d)

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

    sweep_mode = meta.get("mode") == "sweep"
    baseline_pool = meta.get("baseline_pool", "500:100")
    # session_meta.txt 가 없는 이전 세션은 기준 풀에서 실제로 실행된 rate 를 기준 조건으로 봄
    gate_rates = (meta.get("gate_rates").split() if meta.get("gate_rates")
                  else sorted({r["rate"] for r in runs if r["pool"] == baseline_pool and r["light"] == "0"}, key=int))
    base_by_rate = {rate: [r for r in runs if r["pool"] == baseline_pool and r["rate"] == rate and r["light"] == "0"]
                    for rate in gate_rates}
    base = [r for rate in gate_rates for r in base_by_rate[rate]]
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

    lines = []
    for rate in gate_rates:
        rs_rate = base_by_rate[rate]
        if not rs_rate:
            continue
        lines.append(f"기준 조건 (풀 {baseline_pool}, {rate} rps, light0): {len(rs_rate)}회, 붕괴 {sum(r['verdict'] == 'collapse' for r in rs_rate)}회 — 아키텍처별 판정")
        for arch in ("rest", "graphql", "grpc"):
            rs = sorted((r for r in rs_rate if r["arch"] == arch), key=lambda x: x["rep"])
            if not rs:
                continue
            n_collapse = sum(r["verdict"] == "collapse" for r in rs)
            status = "판정 대상" if arch in eligible else "제외 (붕괴 미관측)"
            lines.append(f"  {arch:8} {len(rs)}회 중 붕괴 {n_collapse}회 → {status}  "
                         + ", ".join(f"rep{r['rep']}={r['verdict']}(구간 {r['collapse_episodes']}, drop {r['dropped_ratio'] * 100:.2f}%, "
                                     f"달성 {r['achieved_ratio'] * 100:.0f}%, 포화 {r['saturated']}, 시계 {r.get('clock_ok') or '-'})" for r in rs))
    if base:
        lines.append("가설 1 본 판정(붕괴) 대상: " + (" ".join(eligible) if eligible else "없음 → 붕괴 미재현"))
    if not sweep_mode:  # 스윕 세션에는 기준 조건 판정이 없음
        (d / "gate.txt").write_text("\n".join(lines) + "\n")
        (d / "gate_eligible.txt").write_text(" ".join(eligible))
    bad_clock = [r["run_id"] for r in runs if r.get("clock_ok") == "0"]
    if bad_clock:
        lines.append(f"[경고] 시계 드리프트 3% 초과 구간의 실행 {len(bad_clock)}회: 분석에서 제외할 것")

    # 가설 1 대체 판정: 포화 구간(SAT_RATE) 풀 크기 비교
    sat_rate = meta.get("sat_rate", "800")
    dec = [f"가설 1 대체 판정 — 포화 구간 {sat_rate} rps 풀 크기 비교 (3회 중앙값 [최소–최대])",
           f"  규칙: 작은 풀(20/50/100) 최선값이 {baseline_pool} 대비 처리량 +{POOL_EFFECT_STRONG:.0%} 이상 & 3회 범위 비중첩 & p99 더 낮음 → '확인'",
           f"        |차이| < {POOL_EFFECT_NONE:.0%} 이거나 범위 중첩 → '차이 없음', 그 외 '불확실'",
           f"        연결 반복 생성 여부: 500:500(유휴=최대, 재생성 없음) 을 {baseline_pool} 과 같은 규칙으로 비교"]
    sat_rows = []
    for arch in (meta.get("archs") or "rest graphql grpc").split():
        cmp_ = pool_comparison(runs, sat_rate, arch, baseline_pool)
        if not cmp_:
            continue
        for pool, v in sorted(cmp_.items(), key=lambda kv: int(kv[0].split(":")[0]) * 1000 + int(kv[0].split(":")[1])):
            sat_rows.append({"arch": arch, "pool": pool, "reps": v["n"], "collapse_runs": v["collapse"], "saturated_runs": v["saturated"],
                             **{f"{k}_{s}": v[k][i] for k in ("goodput", "p99", "throttle", "sessions", "procarray", "pool_wait")
                                for i, s in enumerate(("median", "min", "max"))}})
        verdict, det = judge_pool_effect(cmp_, baseline_pool)
        line = f"  {arch:8} 풀 축소 효과: {verdict}"
        if det:
            line += (f" (최선 {det['pool']} 처리량 {det['cand']['goodput'][0]:.0f} vs {baseline_pool} {det['base']['goodput'][0]:.0f}, "
                     f"{det['rel'] * 100:+.1f}%, 범위중첩 {'예' if det['overlap'] else '아니오'}, p99 더 낮음 {'예' if det['p99_better'] else '아니오'})")
        dec.append(line)
        v2, det2 = judge_pool_effect(cmp_, baseline_pool, ("500:500",))
        if det2:
            dec.append(f"           연결 반복 생성 영향: {v2} (500:500 처리량 {det2['cand']['goodput'][0]:.0f}, {det2['rel'] * 100:+.1f}%)")
    if not sweep_mode:
        (d / "h1_decision.txt").write_text("\n".join(dec) + "\n")
        write_csv(d / "summary_de_saturation.csv", sat_rows)
    else:
        lines, dec = [], []

    print(f"[집계] {d}")
    write_csv(d / "summary_de_runs.csv", runs)
    write_csv(d / "summary_de_tc.csv", tc_rows)
    write_csv(d / "summary_de_conditions.csv", cond_rows)
    write_csv(d / "summary_de_throttle.csv", throttle_rows)
    print("\n".join(lines))
    print("\n".join(dec))


if __name__ == "__main__":
    main()
