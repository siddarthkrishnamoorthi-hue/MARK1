//+------------------------------------------------------------------+
//| ICT_Constants.mqh                                                 |
//| MARK1 ICT Expert Advisor — Single source of truth for constants  |
//| Copyright 2024-2025, MARK1 Project                               |
//+------------------------------------------------------------------+
#pragma once

/// @brief FIXED magic number. Never change — EA uses this to own its trades.
#define MARK1_MAGIC        20240001

/// @brief EA version string.
#define MARK1_VERSION      "4.0"

/// @brief Primary symbol this EA is tuned for.
#define MARK1_SYMBOL       "EURUSD"

/// @brief Broker GMT offset in seconds. 0 = true GMT broker.
#define MARK1_GMT_OFFSET   0

/// @brief Pip multiplier for 5-digit brokers (EURUSD digits=5 → 1 pip = 10 points).
#define MARK1_PIP_FACTOR   10
