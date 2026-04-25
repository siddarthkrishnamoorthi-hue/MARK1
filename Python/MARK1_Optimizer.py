"""
MARK1_Optimizer.py — MARK1 Parameter Optimizer (Phase 9, Item 2 of 4)

Grid-searches key EA parameters by injecting values into the MARK1_Funded.set
file and running MT5 Strategy Tester via the official MetaTrader5 Python package.

Requirements:
    pip install MetaTrader5
    MT5 terminal must be running and logged in.

Usage:
    python MARK1_Optimizer.py [--set <path_to.set>] [--report <output.csv>]
"""
from __future__ import annotations

import argparse
import csv
import itertools
import sys
from pathlib import Path
from typing import Any

try:
    import MetaTrader5 as mt5
    _HAVE_MT5 = True
except ImportError:
    _HAVE_MT5 = False
    print("[WARN] MetaTrader5 package not installed. Install with: pip install MetaTrader5")

# ------------------------------------------------------------------------------
# Default .set file location
# ------------------------------------------------------------------------------
DEFAULT_SET_PATH = Path(__file__).parent.parent / "MARK1_Funded.set"
DEFAULT_REPORT   = Path(__file__).parent.parent / "MARK1_OptReport.csv"

# ------------------------------------------------------------------------------
# Parameter grid — (param_name, [values_to_test])
# Extend or narrow as needed.
# ------------------------------------------------------------------------------
PARAM_GRID: dict[str, list[Any]] = {
    "RiskPercent":      [0.25, 0.50, 0.75, 1.0],
    "MaxSpreadPips":    [2.0, 3.0, 4.0],
    "MaxConsecLosses":  [2, 3, 4],
    "MinConfluence":    [1, 2, 3],
    "MinRR":            [1.5, 2.0, 2.5],
}

# Which params to optimise simultaneously (Cartesian product)
ACTIVE_PARAMS = ["RiskPercent", "MaxSpreadPips", "MinRR"]

# ------------------------------------------------------------------------------
# .set file reader / writer
# ------------------------------------------------------------------------------

def _detect_set_encoding(path: Path) -> str:
    """Detect whether .set file is UTF-16 (BOM) or UTF-8."""
    with open(path, "rb") as f:
        bom = f.read(2)
    return "utf-16" if bom == b"\xff\xfe" else "utf-8"


def read_set_file(path: Path) -> dict[str, str]:
    """Parse MARK1 .set file into {param: value_string}."""
    enc = _detect_set_encoding(path)
    params: dict[str, str] = {}
    with open(path, "r", encoding=enc, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(";") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            # Strip trailing |flags if present
            val = val.split("||")[0].strip()
            params[key.strip()] = val
    return params


def write_set_file(path: Path, params: dict[str, str]) -> None:
    """Write params dict back to .set file preserving original encoding."""
    enc = _detect_set_encoding(path)
    with open(path, "r", encoding=enc, errors="replace") as f:
        lines = f.readlines()

    out_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(";") or "=" not in stripped:
            out_lines.append(line)
            continue
        key = stripped.split("=")[0].strip()
        if key in params:
            # Preserve ||flags suffix if present
            suffix = ""
            if "||" in stripped:
                suffix = "||" + stripped.split("||", 1)[1]
            line = f"{key}={params[key]}{suffix}\n"
        out_lines.append(line)

    with open(path, "w", encoding=enc) as f:
        f.writelines(out_lines)


def connect_mt5() -> bool:
    if not _HAVE_MT5:
        return False
    if not mt5.initialize():
        print(f"[ERROR] MT5 initialize() failed: {mt5.last_error()}")
        return False
    return True


def run_backtest_and_read_result(symbol: str, set_path: Path) -> dict[str, float]:
    """
    Placeholder: in a production integration this would call the MT5
    Strategy Tester via the terminal.exe /config approach or the
    mt5.optimizer_results() after submitting a tester job.

    Returns a dict with keys: profit_factor, net_profit, drawdown_pct, win_rate.
    """
    # Minimal stub — replace with actual mt5 tester call if available
    return {
        "profit_factor": 0.0,
        "net_profit":    0.0,
        "drawdown_pct":  0.0,
        "win_rate":      0.0,
    }


def optimize(set_path: Path,
             report_path: Path,
             symbol: str = "EURUSD",
             active_params: list[str] | None = None) -> None:
    """Run grid optimisation and write results to CSV."""
    if active_params is None:
        active_params = ACTIVE_PARAMS

    base_params = read_set_file(set_path)
    grid_values = [PARAM_GRID[p] for p in active_params]
    combinations = list(itertools.product(*grid_values))
    total = len(combinations)
    print(f"[Optimizer] {total} combinations over {active_params}")

    results = []
    try:
        for idx, combo in enumerate(combinations, start=1):
            param_dict = dict(zip(active_params, combo))
            print(f"  [{idx}/{total}] {param_dict}")

            # Apply combo to .set file
            test_params = base_params.copy()
            for k, v in param_dict.items():
                test_params[k] = str(v)
            write_set_file(set_path, test_params)

            # Run tester
            result = run_backtest_and_read_result(symbol, set_path)
            row = {**param_dict, **result}
            results.append(row)
    finally:
        # Always restore original params even if an exception occurs
        write_set_file(set_path, base_params)

    # Write report
    if results:
        fieldnames = list(results[0].keys())
        with open(report_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            w.writerows(results)
        print(f"[OK] Report written → {report_path}")

        # Best by profit factor (non-zero only)
        valid = [r for r in results if r.get("profit_factor", 0) > 0]
        if valid:
            best = max(valid, key=lambda r: r["profit_factor"])
            print(f"\n[Best] {best}")
        else:
            print("[INFO] No valid (non-zero) results — run with a real MT5 tester integration.")


def main() -> None:
    parser = argparse.ArgumentParser(description="MARK1 Grid Optimizer")
    parser.add_argument("--set",    type=Path, default=DEFAULT_SET_PATH,
                        help="Path to .set file (default: MARK1_Funded.set)")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT,
                        help="Output CSV report path")
    parser.add_argument("--symbol", type=str, default="EURUSD")
    args = parser.parse_args()

    if not args.set.exists():
        sys.exit(f"[ERROR] .set file not found: {args.set}")

    connected = connect_mt5()
    if not connected:
        print("[WARN] Running without live MT5 connection — backtest stubs will return zeros.")

    try:
        optimize(args.set, args.report, symbol=args.symbol)
    finally:
        if connected and _HAVE_MT5:
            mt5.shutdown()


if __name__ == "__main__":
    main()
