"""
ICT_Analytics.py — MARK1 Trade Analytics
Phase 9, Item 1 of 4

Reads MARK1_Trades.csv produced by ICT_RiskManager.mqh,
computes per-model win rate, RR distribution, and draws an equity curve.

Requirements: pandas, matplotlib
    pip install pandas matplotlib
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path
from typing import Optional

# ------------------------------------------------------------------------------
# Optional imports — graceful degradation if not installed
# ------------------------------------------------------------------------------
try:
    import pandas as pd
    import matplotlib
    matplotlib.use("Agg")          # non-interactive backend; remove for interactive
    import matplotlib.pyplot as plt
    _HAVE_DEPS = True
except ImportError:
    _HAVE_DEPS = False
    print("[WARN] pandas / matplotlib not found. Install with: pip install pandas matplotlib")

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
DEFAULT_CSV_PATH = Path(__file__).parent.parent / "MARK1_Trades.csv"


def load_trades(csv_path: Path) -> "pd.DataFrame":
    """Load MARK1_Trades.csv into a DataFrame with typed columns."""
    if not csv_path.exists():
        raise FileNotFoundError(f"Trade log not found: {csv_path}")

    df = pd.read_csv(csv_path, parse_dates=["openTime", "closeTime"])

    # Normalise column names (lowercase, strip whitespace)
    df.columns = [c.strip().lower() for c in df.columns]

    # Ensure numeric columns
    for col in ("profit", "lots", "entry", "sl", "tp1", "tp2", "tp3",
                "closeprice", "pnlpips"):
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    # Compute RR from pnlPips / risk distance in pips
    if "rr" not in df.columns and {"entry", "sl", "pnlpips"}.issubset(df.columns):
        risk_pips = ((df["entry"] - df["sl"]).abs() * 10000).round(1)  # 5-digit pair
        risk_pips = risk_pips.replace(0, float("nan"))
        df["rr"] = df["pnlpips"].abs() / risk_pips
        df.loc[df["pnlpips"] <= 0, "rr"] = df.loc[df["pnlpips"] <= 0, "rr"] * -1

    return df


def compute_stats(df: "pd.DataFrame") -> dict:
    """Return a dict of aggregate statistics."""
    if df.empty:
        return {}

    total   = len(df)
    wins    = (df["profit"] > 0).sum() if "profit" in df.columns else 0
    losses  = (df["profit"] <= 0).sum() if "profit" in df.columns else 0
    win_pct = (wins / total * 100.0) if total else 0.0
    avg_rr  = df["rr"].mean() if "rr" in df.columns else 0.0
    net_pnl = df["profit"].sum() if "profit" in df.columns else 0.0

    return dict(total=total, wins=wins, losses=losses,
                win_pct=win_pct, avg_rr=avg_rr, net_pnl=net_pnl)


def per_model_stats(df: "pd.DataFrame") -> Optional["pd.DataFrame"]:
    """Group by model name and compute per-model statistics."""
    if "model" not in df.columns:
        print("[WARN] Column 'model' not found in CSV. Per-model stats skipped.")
        return None

    grp = df.groupby("model")
    agg_dict = dict(
        total=("profit", "count"),
        wins=("profit", lambda x: (x > 0).sum()),
        net_pnl=("profit", "sum"),
    )
    if "rr" in df.columns:
        agg_dict["avg_rr"] = ("rr", "mean")
    stats = grp.agg(**agg_dict)
    stats["win_pct"] = stats["wins"] / stats["total"] * 100.0
    return stats.reset_index()


def plot_equity_curve(df: "pd.DataFrame", out_path: Path) -> None:
    """Plot cumulative equity curve and save to file."""
    if "profit" not in df.columns:
        print("[WARN] 'profit' column missing — equity curve skipped.")
        return

    equity = df["profit"].cumsum()
    fig, ax = plt.subplots(figsize=(12, 5))
    ax.plot(equity.values, linewidth=1.5, color="steelblue")
    ax.axhline(0, color="red", linewidth=0.8, linestyle="--")
    ax.fill_between(range(len(equity)), equity.values, 0,
                    where=(equity.values >= 0), alpha=0.2, color="green")
    ax.fill_between(range(len(equity)), equity.values, 0,
                    where=(equity.values < 0),  alpha=0.2, color="red")
    ax.set_title("MARK1 Equity Curve")
    ax.set_xlabel("Trade #")
    ax.set_ylabel("Cumulative P&L (account currency)")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(str(out_path), dpi=150)
    print(f"[OK] Equity curve saved → {out_path}")
    plt.close(fig)


def plot_model_winrate(model_stats: "pd.DataFrame", out_path: Path) -> None:
    """Bar chart of win rate per model."""
    fig, ax = plt.subplots(figsize=(10, 5))
    bars = ax.bar(model_stats["model"], model_stats["win_pct"], color="steelblue")
    ax.axhline(50, color="orange", linestyle="--", linewidth=1, label="50% WR")
    ax.set_ylim(0, 100)
    ax.set_ylabel("Win Rate (%)")
    ax.set_title("Win Rate by ICT Entry Model")
    ax.legend()
    for bar, val in zip(bars, model_stats["win_pct"]):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + 1.5,
                f"{val:.1f}%",
                ha="center", fontsize=8)
    fig.tight_layout()
    fig.savefig(str(out_path), dpi=150)
    print(f"[OK] Model win-rate chart saved → {out_path}")
    plt.close(fig)


def main(csv_path: Path = DEFAULT_CSV_PATH) -> None:
    if not _HAVE_DEPS:
        sys.exit("[ERROR] Required packages missing. Run: pip install pandas matplotlib")

    print(f"[ICT_Analytics] Loading: {csv_path}")
    df = load_trades(csv_path)
    print(f"[ICT_Analytics] Loaded {len(df)} trades.")

    stats = compute_stats(df)
    print("\n=== Overall Statistics ===")
    for k, v in stats.items():
        print(f"  {k:12s}: {v:.2f}" if isinstance(v, float) else f"  {k:12s}: {v}")

    model_stats = per_model_stats(df)
    if model_stats is not None:
        print("\n=== Per-Model Statistics ===")
        print(model_stats.to_string(index=False))

    out_dir = csv_path.parent
    plot_equity_curve(df, out_dir / "MARK1_EquityCurve.png")
    if model_stats is not None:
        plot_model_winrate(model_stats, out_dir / "MARK1_ModelWinRate.png")


if __name__ == "__main__":
    csv_arg = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV_PATH
    main(csv_arg)
