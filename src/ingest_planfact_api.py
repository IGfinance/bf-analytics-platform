#!/usr/bin/env python3
"""
Загрузка операций ПланФакта через API в planfact_operations_api (CLI-обёртка
над planfact_api_core.py). Идемпотентна: повторный прогон окна перезаписывает
строки и помечает удалённые в ПланФакте.

По умолчанию окно — с 1 января текущего года по конец следующего (плановые
операции) — для первичной/ручной загрузки. Регулярные прогоны задают окно
явно: scripts/cron_planfact_api_sync.sh weekly|monthly.

Примеры:
    python3 ingest_planfact_api.py --dry-run
    python3 ingest_planfact_api.py --date-from 2026-01-01 --date-to 2026-12-31
"""

import argparse
import os
import sys
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).parent.parent
load_dotenv(REPO_ROOT / ".env")

from planfact_api_core import get_client, sync  # noqa: E402


def main():
    today = date.today()
    parser = argparse.ArgumentParser(description="Загрузка операций ПланФакта (API) в ClickHouse")
    parser.add_argument("--date-from", default=f"{today.year}-01-01")
    parser.add_argument("--date-to", default=f"{today.year + 1}-12-31")
    parser.add_argument("--dry-run", action="store_true", help="Только скачать и разобрать, в ClickHouse не писать")
    parser.add_argument("--force-delete", action="store_true",
                        help="Разрешить пометить удалёнными >20%% строк окна (по умолчанию отказ — защита от сбоя API)")
    args = parser.parse_args()

    api_key = os.environ.get("PLANFACT_API")
    if not api_key:
        print("Ошибка: PLANFACT_API не задан в .env", file=sys.stderr)
        sys.exit(1)

    print(f"Окно {args.date_from} .. {args.date_to}")
    client = None if args.dry_run else get_client()
    s = sync(client, api_key, args.date_from, args.date_to, args.force_delete, args.dry_run)
    print(f"Операций: {s['operations']}, строк (частей): {s['rows']}, помечено удалёнными: {s['deleted']}"
          + (" (dry-run)" if args.dry_run else ""))


if __name__ == "__main__":
    main()
