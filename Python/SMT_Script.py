"""
SMT_Script.py — MARK1 SMT Divergence Scanner (Phase 9, Item 4 of 4)

Connects to a running MetaTrader 5 terminal, pulls EURUSD and GBPUSD H1 rates,
and detects Smart Money Technique (SMT) divergence between the two pairs.

Bullish SMT : EURUSD makes a lower low — GBPUSD does NOT  → potential long
Bearish SMT : EURUSD makes a higher high — GBPUSD does NOT → potential short

Prints detected divergences and optionally draws a comparative chart.

Requirements:
    pip install MetaTrader5 pandas matplotlib
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple

try:
    import MetaTrader5 as mt5
    _HAVE_MT5 = True
except ImportError:
    _HAVE_MT5 = False
    print("[WARN] MetaTrader5 package not installed. Install with: pip install MetaTrader5")

try:
    import pandas as pd
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    _HAVE_PLOT = True
except ImportError:
    _HAVE_PLOT = False

# ------------------------------------------------------------------------------
# Configuration — mirrors ICT_SMT.mqh defaults
# ------------------------------------------------------------------------------
DEFAULT_PRIMARY     = "EURUSD"
DEFAULT_CORRELATED  = "GBPUSD"
DEFAULT_LOOKBACK    = 10       # bars per comparison window
DEFAULT_SCAN_BARS   = 200      # total H1 bars to fetch


class SMTDivergence(NamedTuple):
    is_bullish:  bool
    eur_level:   float
    gbp_level:   float
    bar_index:   int
    bar_time:    datetime


def fetch_h1_rates(symbol: str, count: int) -> "pd.DataFrame":
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H1, 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No H1 rates returned for {symbol}. Error: {mt5.last_error()}")
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.set_index("time", inplace=True)
    return df


def scan_smt_divergences(
    eur: "pd.DataFrame",
    gbp: "pd.DataFrame",
    lookback: int,
    *,
    verbose: bool = False,
) -> list[SMTDivergence]:
    """
    Slide a window of `lookback` bars across both series and flag SMT divergences.
    Mirrors the logic in CSMTEngine::Scan() in ICT_SMT.mqh.
    """

    # Align indices to common timestamps
    common_idx = eur.index.intersection(gbp.index)
    eur = eur.loc[common_idx]
    gbp = gbp.loc[common_idx]

    if len(eur) < lookback * 2 + 1:
        raise ValueError(f"Not enough bars for SMT scan. Need {lookback * 2 + 1}, got {len(eur)}.")

    divergences: list[SMTDivergence] = []

    for i in range(lookback, len(eur) - lookback):
        # Current window
        eur_win  = eur.iloc[i - lookback + 1 : i + 1]
        gbp_win  = gbp.iloc[i - lookback + 1 : i + 1]
        # Previous window
        eur_prev = eur.iloc[i - lookback * 2 + 1 : i - lookback + 1]
        gbp_prev = gbp.iloc[i - lookback * 2 + 1 : i - lookback + 1]

        eur_low  = eur_win["low"].min()
        gbp_low  = gbp_win["low"].min()
        eur_plw  = eur_prev["low"].min()
        gbp_plw  = gbp_prev["low"].min()

        eur_high = eur_win["high"].max()
        gbp_high = gbp_win["high"].max()
        eur_phigh = eur_prev["high"].max()
        gbp_phigh = gbp_prev["high"].max()

        # Bullish SMT: EUR makes lower low, GBP does NOT
        if eur_low < eur_plw and gbp_low >= gbp_plw:
            dv = SMTDivergence(
                is_bullish=True,
                eur_level=eur_low,
                gbp_level=gbp_low,
                bar_index=i,
                bar_time=eur.index[i].to_pydatetime(),
            )
            divergences.append(dv)
            if verbose:
                print(f"  [Bullish SMT] {dv.bar_time:%Y-%m-%d %H:%M} "
                      f"EUR low={dv.eur_level:.5f}  GBP low={dv.gbp_level:.5f}")

        # Bearish SMT: EUR makes higher high, GBP does NOT
        elif eur_high > eur_phigh and gbp_high <= gbp_phigh:
            dv = SMTDivergence(
                is_bullish=False,
                eur_level=eur_high,
                gbp_level=gbp_high,
                bar_index=i,
                bar_time=eur.index[i].to_pydatetime(),
            )
            divergences.append(dv)
            if verbose:
                print(f"  [Bearish SMT] {dv.bar_time:%Y-%m-%d %H:%M} "
                      f"EUR high={dv.eur_level:.5f}  GBP high={dv.gbp_level:.5f}")

    return divergences


def print_summary(divs: list[SMTDivergence], eur_sym: str, gbp_sym: str) -> None:
    bullish = sum(1 for d in divs if d.is_bullish)
    bearish = len(divs) - bullish
    print(f"\n{'='*55}")
    print(f"  SMT Divergence Summary — {eur_sym} vs {gbp_sym}")
    print(f"  Scanned at: {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}")
    print(f"{'='*55}")
    print(f"  Total divergences : {len(divs)}")
    print(f"  Bullish SMT       : {bullish}  (potential longs)")
    print(f"  Bearish SMT       : {bearish}  (potential shorts)")
    print(f"{'='*55}")
    if divs:
        latest = divs[-1]
        dir_str = "BULLISH (Long)" if latest.is_bullish else "BEARISH (Short)"
        print(f"\n  Latest divergence : {dir_str}")
        print(f"  Time              : {latest.bar_time:%Y-%m-%d %H:%M}")
        print(f"  EUR level         : {latest.eur_level:.5f}")
        print(f"  GBP level         : {latest.gbp_level:.5f}")
    print()


def plot_smt(
    eur: "pd.DataFrame",
    gbp: "pd.DataFrame",
    divs: list[SMTDivergence],
    out_path: Path,
    eur_sym: str,
    gbp_sym: str,
) -> None:
    """Dual-panel chart: EUR close + GBP close, with SMT markers."""
    display_bars = 200
    eur_d = eur.tail(display_bars)
    gbp_d = gbp.tail(display_bars)

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    ax1.plot(eur_d.index, eur_d["close"], color="steelblue", lw=1.2, label=eur_sym)
    ax2.plot(gbp_d.index, gbp_d["close"], color="darkorange", lw=1.2, label=gbp_sym)

    for dv in divs:
        if dv.bar_time < eur_d.index[0]:
            continue
        marker_color = "lime" if dv.is_bullish else "red"
        arrow_code   = "▲" if dv.is_bullish else "▼"
        for ax, level in [(ax1, dv.eur_level), (ax2, dv.gbp_level)]:
            ax.annotate(arrow_code,
                        xy=(dv.bar_time, level),
                        fontsize=8, color=marker_color,
                        ha="center",
                        arrowprops=None)

    ax1.set_title(f"SMT Divergence — {eur_sym} vs {gbp_sym} (H1)")
    ax1.set_ylabel(eur_sym)
    ax1.legend(loc="upper left")
    ax1.grid(alpha=0.2)
    ax2.set_ylabel(gbp_sym)
    ax2.legend(loc="upper left")
    ax2.grid(alpha=0.2)
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(str(out_path), dpi=150)
    print(f"[OK] SMT chart saved → {out_path}")
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description="SMT Divergence Scanner")
    parser.add_argument("--primary",    default=DEFAULT_PRIMARY,    help="Primary symbol (EURUSD)")
    parser.add_argument("--correlated", default=DEFAULT_CORRELATED, help="Correlated symbol (GBPUSD)")
    parser.add_argument("--lookback",   type=int, default=DEFAULT_LOOKBACK,
                        help="Window size in bars for each comparison (default: 10)")
    parser.add_argument("--bars",       type=int, default=DEFAULT_SCAN_BARS,
                        help="H1 bars to fetch per symbol (default: 200)")
    parser.add_argument("--out",        type=Path,
                        default=Path(__file__).parent.parent / "SMT_Chart.png",
                        help="Output chart path")
    parser.add_argument("--verbose",    action="store_true",
                        help="Print each divergence as it is found")
    args = parser.parse_args()

    if not _HAVE_MT5:
        sys.exit("[ERROR] MetaTrader5 package required. Run: pip install MetaTrader5")

    if not mt5.initialize():
        sys.exit(f"[ERROR] MT5 initialize() failed: {mt5.last_error()}")
    print(f"[OK] Connected to MT5 {mt5.version()}")

    try:
        eur = fetch_h1_rates(args.primary,    args.bars)
        gbp = fetch_h1_rates(args.correlated, args.bars)
        print(f"[OK] {args.primary}: {len(eur)} bars  |  {args.correlated}: {len(gbp)} bars")

        divs = scan_smt_divergences(eur, gbp, args.lookback, verbose=args.verbose)
        print_summary(divs, args.primary, args.correlated)

        if _HAVE_PLOT:
            plot_smt(eur, gbp, divs, args.out, args.primary, args.correlated)
        else:
            print("[WARN] matplotlib not installed — chart skipped.")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
