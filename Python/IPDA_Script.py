"""
IPDA_Script.py — MARK1 IPDA Level Calculator (Phase 9, Item 3 of 4)

Connects to a running MetaTrader 5 terminal, pulls EURUSD D1 rates,
and computes the ICT IPDA 20 / 40 / 60 bar high-low-equilibrium levels.
Prints a summary table and saves a chart of the levels on the D1 price series.

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
# Constants — match MQL5 definitions in ICT_IPDA.mqh
# ------------------------------------------------------------------------------
IPDA_20_BAR = 20
IPDA_40_BAR = 40
IPDA_60_BAR = 60
DEFAULT_SYMBOL = "EURUSD"


class IPDARange(NamedTuple):
    high20: float
    low20:  float
    high40: float
    low40:  float
    high60: float
    low60:  float
    eq20:   float
    eq40:   float
    eq60:   float


def compute_ipda(df: "pd.DataFrame") -> IPDARange:
    """
    Compute IPDA levels on a D1 DataFrame that has 'high' and 'low' columns.
    Uses the last (most recent) N bars, excluding the currently forming bar.
    """
    # Exclude last (in-progress) bar
    closed = df.iloc[:-1]
    if len(closed) < IPDA_60_BAR:
        raise ValueError(
            f"Need at least {IPDA_60_BAR} closed D1 bars, got {len(closed)}."
        )

    h20 = closed["high"].iloc[-IPDA_20_BAR:].max()
    l20 = closed["low"].iloc[-IPDA_20_BAR:].min()
    h40 = closed["high"].iloc[-IPDA_40_BAR:].max()
    l40 = closed["low"].iloc[-IPDA_40_BAR:].min()
    h60 = closed["high"].iloc[-IPDA_60_BAR:].max()
    l60 = closed["low"].iloc[-IPDA_60_BAR:].min()

    return IPDARange(
        high20=h20, low20=l20,
        high40=h40, low40=l40,
        high60=h60, low60=l60,
        eq20=(h20 + l20) / 2,
        eq40=(h40 + l40) / 2,
        eq60=(h60 + l60) / 2,
    )


def print_ipda_table(ipda: IPDARange, symbol: str) -> None:
    print(f"\n{'='*50}")
    print(f"  IPDA Levels — {symbol}  ({datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')})")
    print(f"{'='*50}")
    print(f"  {'Range':<8} {'High':>10} {'Equilibrium':>14} {'Low':>10}")
    print(f"  {'-'*44}")
    for bars, h, eq, l in [
        (20, ipda.high20, ipda.eq20, ipda.low20),
        (40, ipda.high40, ipda.eq40, ipda.low40),
        (60, ipda.high60, ipda.eq60, ipda.low60),
    ]:
        print(f"  {bars:<4} bar  {h:>10.5f}  {eq:>14.5f}  {l:>10.5f}")
    print(f"{'='*50}\n")


def plot_ipda(df: "pd.DataFrame", ipda: IPDARange, symbol: str, out_path: Path) -> None:
    """Draw D1 close prices with IPDA levels as horizontal lines."""
    closed = df.iloc[-IPDA_60_BAR - 10:-1]  # last 70 bars for context
    fig, ax = plt.subplots(figsize=(14, 6))
    ax.plot(closed.index, closed["close"], color="steelblue", linewidth=1.2, label="D1 Close")

    ax.axhline(ipda.high20, color="aqua",           ls="--", lw=1.2, label="20H")
    ax.axhline(ipda.low20,  color="aqua",           ls="--", lw=1.2, label="20L")
    ax.axhline(ipda.eq20,   color="aqua",           ls=":",  lw=0.8, label="EQ20")
    ax.axhline(ipda.high40, color="cornflowerblue", ls="--", lw=1.2, label="40H")
    ax.axhline(ipda.low40,  color="cornflowerblue", ls="--", lw=1.2, label="40L")
    ax.axhline(ipda.eq40,   color="cornflowerblue", ls=":",  lw=0.8, label="EQ40")
    ax.axhline(ipda.high60, color="mediumblue",     ls="--", lw=1.2, label="60H")
    ax.axhline(ipda.low60,  color="mediumblue",     ls="--", lw=1.2, label="60L")
    ax.axhline(ipda.eq60,   color="mediumblue",     ls=":",  lw=0.8, label="EQ60")

    ax.set_title(f"{symbol} D1 — IPDA 20/40/60 Bar Levels")
    ax.set_xlabel("Date")
    ax.set_ylabel("Price")
    ax.legend(loc="upper left", fontsize=7, ncol=3)
    ax.grid(alpha=0.2)
    fig.tight_layout()
    fig.savefig(str(out_path), dpi=150)
    print(f"[OK] IPDA chart saved → {out_path}")
    plt.close(fig)


def fetch_d1_rates(symbol: str, count: int = 200) -> "pd.DataFrame":
    """Pull D1 rates from connected MT5 terminal."""
    if not _HAVE_MT5:
        raise RuntimeError("MetaTrader5 package not installed.")
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_D1, 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No D1 rates returned for {symbol}. Error: {mt5.last_error()}")
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.set_index("time", inplace=True)
    return df


def main() -> None:
    parser = argparse.ArgumentParser(description="IPDA Level Calculator")
    parser.add_argument("--symbol", default=DEFAULT_SYMBOL, help="Trading symbol (default: EURUSD)")
    parser.add_argument("--out",    type=Path,
                        default=Path(__file__).parent.parent / "IPDA_Levels.png",
                        help="Output chart path")
    args = parser.parse_args()

    # Connect
    if _HAVE_MT5:
        if not mt5.initialize():
            sys.exit(f"[ERROR] MT5 initialize() failed: {mt5.last_error()}")
        print(f"[OK] Connected to MT5 {mt5.version()}")
    else:
        sys.exit("[ERROR] MetaTrader5 package required. Run: pip install MetaTrader5")

    try:
        df = fetch_d1_rates(args.symbol, count=200)
        print(f"[OK] Fetched {len(df)} D1 bars for {args.symbol}")
        ipda = compute_ipda(df)
        print_ipda_table(ipda, args.symbol)
        if _HAVE_PLOT:
            plot_ipda(df, ipda, args.symbol, args.out)
        else:
            print("[WARN] matplotlib not installed — chart skipped.")
    finally:
        if _HAVE_MT5:
            mt5.shutdown()


if __name__ == "__main__":
    main()
