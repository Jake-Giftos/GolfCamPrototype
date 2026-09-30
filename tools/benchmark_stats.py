"""Accuracy statistics for GolfCam vs a reference launch monitor.

Usage: python tools/benchmark_stats.py shots.csv

Fill the ref_ball_speed_mph / ref_launch_deg columns in shots.csv first. Rows without a reference are skipped.
Only the standard library is used.
"""
import csv
import math
import statistics
import sys
from collections import defaultdict


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def stats(errors):
    n = len(errors)
    if n == 0:
        return None
    mae = sum(abs(e) for e in errors) / n
    rmse = math.sqrt(sum(e * e for e in errors) / n)
    bias = sum(errors) / n
    sd = statistics.stdev(errors) if n > 1 else 0.0
    return n, mae, rmse, bias, sd


def report(title, errors, unit):
    s = stats(errors)
    if not s:
        print(f"  {title:<22} no data")
        return
    n, mae, rmse, bias, sd = s
    print(f"  {title:<22} n={n:<3} MAE {mae:5.2f}{unit}  RMSE {rmse:5.2f}{unit}  bias {bias:+5.2f}{unit}  sd {sd:5.2f}{unit}")


def slope(xs, ys):
    if len(xs) < 3:
        return None
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    return None if sxx == 0 else sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx


def main(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("status") == "measured"]

    speed_err, launch_err = [], []
    by_club = defaultdict(lambda: ([], []))
    ref_speeds, speed_err_for_slope = [], []
    for r in rows:
        ours_s, ref_s = num(r["ball_speed_mph"]), num(r["ref_ball_speed_mph"])
        ours_l, ref_l = num(r["launch_deg"]), num(r["ref_launch_deg"])
        if ours_s is not None and ref_s is not None:
            e = ours_s - ref_s
            speed_err.append(e)
            by_club[r["club"]][0].append(e)
            ref_speeds.append(ref_s)
            speed_err_for_slope.append(e)
        if ours_l is not None and ref_l is not None:
            e = ours_l - ref_l
            launch_err.append(e)
            by_club[r["club"]][1].append(e)

    print(f"{len(rows)} measured shots in {path}\n")
    print("Ball speed (ours - reference):")
    report("all", speed_err, " mph")
    for club, (s, _) in sorted(by_club.items()):
        report(club, s, " mph")
    k = slope(ref_speeds, speed_err_for_slope)
    if k is not None:
        print(f"  speed-dependent error: {k * 100:+.2f} mph per 100 mph "
              f"(a pure scale error -> multiply our speed by {1 / (1 + k):.4f})")
    print("\nLaunch angle (ours - reference):")
    report("all", launch_err, " deg")
    for club, (_, l) in sorted(by_club.items()):
        report(club, l, " deg")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
