#!/usr/bin/env python3
"""
Парсер банковских выписок в формате 1С (txt, CamlExchange, кодировка 1251).

В отличие от исходного конвертера (FinanceBlackSite/src/scripts/1c_statement.py),
этот вариант не обрезает набор колонок до фиксированного списка — вытягивает все
поля, реально встретившиеся в файле. Известные поля (сумма, дата, контрагент и его
реквизиты) размечаются в канонические колонки таблицы bank_statements; всё
остальное (статус составителя, показатели КБК/ОКАТО, вид оплаты и т.п.) уходит в
extra_columns — тот же паттерн, что и extra_columns в wb_core.py для отчётов WB.
"""

from __future__ import annotations

import os
import re
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent

CANONICAL_KEYS = {
    "Номер", "Дата", "Сумма",
    "ДатаПоступило", "Плательщик", "Плательщик1", "ПлательщикИНН", "ПлательщикСчет",
    "ПлательщикБанк1", "ПлательщикБИК", "ПлательщикКПП",
    "ДатаСписано", "Получатель", "Получатель1", "ПолучательИНН", "ПолучательСчет",
    "ПолучательБанк1", "ПолучательБИК", "ПолучательКПП",
    "НазначениеПлатежа", "ВидОплаты", "Очередность",
    "РасчСчет", "СекцияДокумент",
}


def parse_ru_date(value: str):
    value = (value or "").strip()
    if not value:
        return None
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


def parse_amount(value: str):
    value = (value or "").strip()
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_1c_file(filepath: Path) -> list[dict]:
    """Разбирает один txt-файл 1С и возвращает список строк-транзакций."""
    with open(filepath, encoding="1251") as f:
        content = list(filter(None, f.read().split("\n")))

    header_sender = ""
    account_number = ""
    operations: list[dict] = []
    operation: dict = {}
    operations_flag = False

    for line in content:
        if line.startswith("Отправитель=") and not header_sender:
            header_sender = line.split("=", 1)[1].strip()

        if "РасчСчет" in line and not account_number:
            try:
                _, value = line.split("=", 1)
                account_number = value.strip()
            except ValueError:
                pass

        if line == "КонецРасчСчет":
            operations_flag = True
            continue

        if not operations_flag:
            continue

        if line.startswith("СекцияДокумент"):
            operation = {}

        if "=" in line:
            key, value = line.split("=", 1)
        else:
            key, value = line, ""
        operation[key] = value.strip()

        if line == "КонецДокумента":
            operations.append(operation)
            operation = {}

    rows = []
    for row_num, txn in enumerate(operations, start=1):
        acct = txn.get("РасчСчет", account_number)
        receiver_account = txn.get("ПолучательСчет", "")
        is_incoming = receiver_account == acct

        if is_incoming:
            direction = "in"
            effective_date = parse_ru_date(txn.get("ДатаПоступило", ""))
            amount = parse_amount(txn.get("Сумма", ""))
            signed_amount = amount
            counterparty = txn.get("Плательщик") or txn.get("Плательщик1") or ""
            counterparty_inn = txn.get("ПлательщикИНН", "")
            counterparty_account = txn.get("ПлательщикСчет", "")
            counterparty_bank = txn.get("ПлательщикБанк1", "")
            counterparty_bik = txn.get("ПлательщикБИК", "")
            counterparty_kpp = txn.get("ПлательщикКПП", "")
        else:
            direction = "out"
            effective_date = parse_ru_date(txn.get("ДатаСписано", ""))
            amount = parse_amount(txn.get("Сумма", ""))
            signed_amount = -amount if amount is not None else None
            counterparty = txn.get("Получатель") or txn.get("Получатель1") or ""
            counterparty_inn = txn.get("ПолучательИНН", "")
            counterparty_account = txn.get("ПолучательСчет", "")
            counterparty_bank = txn.get("ПолучательБанк1", "")
            counterparty_bik = txn.get("ПолучательБИК", "")
            counterparty_kpp = txn.get("ПолучательКПП", "")

        extra = {k: v for k, v in txn.items() if k not in CANONICAL_KEYS and v}

        rows.append({
            "account_number": acct,
            "source_bank": header_sender,
            "doc_type": txn.get("СекцияДокумент", ""),
            "doc_number": txn.get("Номер", ""),
            "doc_date": parse_ru_date(txn.get("Дата", "")),
            "effective_date": effective_date,
            "direction": direction,
            "amount": amount,
            "signed_amount": signed_amount,
            "counterparty": counterparty,
            "counterparty_inn": counterparty_inn,
            "counterparty_account": counterparty_account,
            "counterparty_bank": counterparty_bank,
            "counterparty_bik": counterparty_bik,
            "counterparty_kpp": counterparty_kpp,
            "payment_purpose": txn.get("НазначениеПлатежа", ""),
            "payment_kind": txn.get("ВидОплаты", ""),
            "priority": txn.get("Очередность", ""),
            "row_num": row_num,
            "extra_columns": extra,
            "source_file": filepath.name,
        })

    return rows


def parse_dir(input_dir: Path) -> list[dict]:
    rows = []
    for path in sorted(input_dir.glob("*.txt")):
        rows.extend(parse_1c_file(path))
    return rows


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: bank_statement_1c.py <input_dir>", file=sys.stderr)
        sys.exit(1)

    all_rows = parse_dir(Path(sys.argv[1]))
    extra_keys = sorted({k for r in all_rows for k in r["extra_columns"]})
    print(f"Файлов: {len(list(Path(sys.argv[1]).glob('*.txt')))}")
    print(f"Строк (транзакций): {len(all_rows)}")
    print(f"Ключи, ушедшие в extra_columns: {extra_keys}")
