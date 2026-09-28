#!/usr/bin/env python3
"""
Дозагрузка истории WB через финансовое API — по одному кабинету, кусками.

Зачем отдельно от ingest_wb_api.py: тот грузит ОДИН период одним вызовом, а
для истории за год нужно (а) резать период на куски, чтобы прерывание не
теряло всё, и (б) вести ОДИН ограничитель частоты на все куски — иначе первый
запрос каждого куска уходит без паузы и сразу ловит 429 (см. параметр pacer у
wb_api_core.ingest_period).

ПАРАЛЛЕЛЬНОСТЬ ПО КАБИНЕТАМ. Лимит WB (1 запрос/мин) привязан к ТОКЕНУ, а не
к IP — проверено 2026-09-27: два запроса подряд разными токенами оба вернули
200. Поэтому кабинеты грузятся ОДНОВРЕМЕННО, каждый своим процессом:
    for c in ARB CloudSix Feel Hauser INOVO Lampa NoxLab Torado; do
        nohup python3 scripts/backfill_wb_api.py --cabinet $c \
            --date-from 2024-12-01 --date-to 2026-09-27 > /tmp/bf_$c.log 2>&1 &
    done
Последовательно те же 407 отчётов заняли бы ~11 часов, параллельно — примерно
столько, сколько самый большой кабинет (CloudSix, ~1.5-2 часа).

НЕ запускайте два процесса на ОДИН кабинет: у них будут разные ограничители,
и они начнут отбирать друг у друга лимит, получая 429.

Загрузка идемпотентна (ReplacingMergeTree по cabinet+rrd_id и
cabinet+report_id), поэтому прерванный прогон можно просто повторить тем же
периодом — задвоения не будет.
"""

from __future__ import annotations

import argparse
import sys
import traceback
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
load_dotenv(REPO_ROOT / ".env")
sys.path.insert(0, str(REPO_ROOT / "src"))

from wb_api_core import _Pacer, ingest_period  # noqa: E402


def chunks(date_from: date, date_to: date, days: int):
    start = date_from
    while start <= date_to:
        stop = min(start + timedelta(days=days - 1), date_to)
        yield start, stop
        start = stop + timedelta(days=1)


def main():
    p = argparse.ArgumentParser(description="Дозагрузка истории WB API по кабинету")
    p.add_argument("--cabinet", required=True)
    p.add_argument("--date-from", required=True, help="YYYY-MM-DD")
    p.add_argument("--date-to", required=True, help="YYYY-MM-DD")
    p.add_argument("--chunk-days", type=int, default=90,
                   help="размер куска в днях (по умолчанию 90). Больше кусок — меньше "
                        "лишних запросов list, но грубее шаг восстановления после сбоя")
    p.add_argument("--database", help="БД проекта (по умолчанию CLICKHOUSE_DATABASE)")
    p.add_argument("--summary-only", action="store_true",
                   help="только сводки по отчётам, без строк детализации")
    args = p.parse_args()

    d_from = date.fromisoformat(args.date_from)
    d_to = date.fromisoformat(args.date_to)
    if d_from > d_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    def log(msg):
        print(f"[{args.cabinet}] {msg}", flush=True)

    # ОДИН ограничитель на все куски этого кабинета — см. шапку
    pacer = _Pacer(log=log)
    plan = list(chunks(d_from, d_to, args.chunk_days))
    log(f"дозагрузка {d_from}..{d_to}, кусков: {len(plan)} по {args.chunk_days} дн.")

    totals = {"reports": 0, "summary_rows": 0, "detailed_rows": 0}
    failed = []
    for i, (a, b) in enumerate(plan, 1):
        log(f"--- кусок {i}/{len(plan)}: {a}..{b}")
        try:
            r = ingest_period(args.cabinet, a, b, log=log, database=args.database,
                              with_detailed=not args.summary_only, pacer=pacer)
            for k in totals:
                totals[k] += r[k]
        except Exception as e:
            # один кусок не должен валить весь прогон: остальные куски
            # независимы, а этот можно повторить отдельно
            failed.append((a, b, str(e)[:200]))
            log(f"ОШИБКА на куске {a}..{b}: {e}")
            traceback.print_exc()

    log(f"ИТОГО отчётов {totals['reports']}, сводок {totals['summary_rows']}, "
        f"строк детализации {totals['detailed_rows']}")
    if failed:
        log(f"НЕУДАЧНЫХ КУСКОВ: {len(failed)}")
        for a, b, e in failed:
            log(f"  {a}..{b}: {e}")
        sys.exit(2)


if __name__ == "__main__":
    main()
