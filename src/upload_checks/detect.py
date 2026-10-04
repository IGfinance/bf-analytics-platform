"""Автоопределение кабинета по самому файлу (WB детальный, WB сводный, Ozon «Начисления»).

В файлах нет названия кабинета, зато есть то, что однозначно указывает на него и уже лежит в БД проекта:
  * WB: номер отчёта глобально уникален, и каждый еженедельный отчёт попадает в базу через API
    (cron раз в сутки) с привязкой к кабинету; у детального отчёта есть ещё «Код номенклатуры» (nmId);
  * Ozon: SKU — числовой идентификатор товара у продавца; он есть в каталоге API, в истории загруженных
    «Начислений» и в отчёте о реализации. (Проверено 2026-10-04 на семи реальных файлах: у победителя
    97–100 % SKU файла, у остальных кабинетов 0.)

Принцип безопасности: определяем только при ЯВНОМ преимуществе одного кабинета, иначе None — тогда
пользователь выбирает вручную. Кандидаты ограничены кабинетами текущего проекта (чужие не раскрываем).
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd

MAX_IDS = 800          # сколько уникальных идентификаторов из файла достаточно для решения


@dataclass
class Detection:
    cabinet: str | None
    reason: str = ""                       # по-русски, показывается пользователю
    details: dict = field(default_factory=dict)


# --------------------------------------------------------------------------- чтение файла

def _norm(h) -> str:
    return re.sub(r"\s+", " ", str(h).strip())


def _column(path: Path, header_row: int, aliases: list) -> pd.Series | None:
    """Колонка файла по любому из заголовков-алиасов; None, если такой нет."""
    want = {_norm(a) for a in aliases}
    headers = list(pd.read_excel(path, sheet_name=0, header=header_row, nrows=0).columns)
    for h in headers:
        if _norm(h) in want:
            return pd.read_excel(path, sheet_name=0, header=header_row, usecols=[h], dtype=str).iloc[:, 0]
    return None


def _aliases(core_module, canonical: str) -> list:
    import yaml
    with open(core_module.MAPPING_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)["columns"][canonical]["aliases"]


def wb_detail_features(path: Path) -> dict:
    import wb_core
    feats = {"report_number": None, "items": []}
    try:
        feats["report_number"] = wb_core.extract_report_number(Path(path).name)
    except ValueError:
        pass
    col = _column(path, 0, _aliases(wb_core, "nomenclature_code"))
    if col is not None:
        vals = [re.sub(r"\.0$", "", str(v).strip()) for v in col.dropna().unique()]
        feats["items"] = [v for v in vals if v.isdigit()][:MAX_IDS]
    return feats


def wb_summary_features(path: Path) -> dict:
    import wb_summary_core as core
    col = _column(path, 0, ["№ отчета"])
    nums = []
    if col is not None:
        for v in col.dropna().unique():
            try:
                nums.append(int(float(v)))
            except ValueError:
                pass
    return {"report_numbers": nums[:MAX_IDS]}


def ozon_features(path: Path) -> dict:
    import ozon_core
    col = _column(path, 1, _aliases(ozon_core, "sku"))
    skus = []
    if col is not None:
        for v in col.dropna().unique():
            s = re.sub(r"\.0$", "", str(v).strip())
            if s.isdigit() and int(s) > 0:
                skus.append(int(s))
    return {"skus": skus[:MAX_IDS]}


# --------------------------------------------------------------------------- решение

def decide(counts: dict, total: int, allowed) -> str | None:
    """Победитель — кабинет проекта, у которого не меньше половины идентификаторов файла и не меньше
    чем втрое больше, чем у следующего. Иначе None (неоднозначно или данных нет)."""
    allowed = set(allowed)
    counts = {c: n for c, n in counts.items() if c in allowed and n > 0}
    if not counts or total <= 0:
        return None
    ranked = sorted(counts.items(), key=lambda x: -x[1])
    best_c, best_n = ranked[0]
    second = ranked[1][1] if len(ranked) > 1 else 0
    if best_n * 2 >= total and best_n >= 3 * second:
        return best_c
    return None


# --------------------------------------------------------------------------- знания из БД

class ClickHouseKnowledge:
    """Что уже лежит в БД проекта (клиент подключён к БД проекта, права только на чтение достаточны)."""

    def __init__(self, client):
        self.client = client

    def report_cabinets(self, numbers: list) -> dict:
        if not numbers:
            return {}
        # плоские строки, а не groupUniqArray: не зависим от того, как драйвер отдаёт массивы
        rows = self.client.query(
            "SELECT DISTINCT report_number, cabinet FROM ("
            " SELECT report_number, cabinet FROM wb_reports WHERE report_number IN {ns:Array(UInt64)}"
            " UNION ALL SELECT report_number, cabinet FROM wb_report_summary WHERE report_number IN {ns:Array(UInt64)}"
            " UNION ALL SELECT report_id AS report_number, cabinet FROM wb_api_report_summary WHERE report_id IN {ns:Array(UInt64)}"
            ")", parameters={"ns": [int(n) for n in numbers]}).result_rows
        out: dict = {}
        for n, cab in rows:
            out.setdefault(int(n), set()).add(cab)
        return out

    def wb_item_counts(self, items: list) -> dict:
        if not items:
            return {}
        rows = self.client.query(
            "SELECT cabinet, uniqExact(item) FROM ("
            " SELECT cabinet, nomenclature_code AS item FROM wb_reports WHERE nomenclature_code IN {it:Array(String)}"
            " UNION ALL SELECT cabinet, toString(nm_id) AS item FROM wb_api_realization WHERE toString(nm_id) IN {it:Array(String)}"
            ") GROUP BY cabinet", parameters={"it": list(items)}).result_rows
        return {cab: int(n) for cab, n in rows}

    def ozon_sku_counts(self, skus: list) -> dict:
        if not skus:
            return {}
        rows = self.client.query(
            "SELECT cabinet, uniqExact(s) FROM ("
            " SELECT cabinet, toInt64OrZero(sku) AS s FROM ozon_reports WHERE toInt64OrZero(sku) IN {sk:Array(Int64)}"
            " UNION ALL SELECT cabinet, sku AS s FROM ozon_products WHERE sku IN {sk:Array(Int64)}"
            " UNION ALL SELECT cabinet, sku AS s FROM ozon_realization WHERE sku IN {sk:Array(Int64)}"
            ") GROUP BY cabinet", parameters={"sk": [int(s) for s in skus]}).result_rows
        return {cab: int(n) for cab, n in rows}


# --------------------------------------------------------------------------- вход

def detect(kind: str, path: Path, knowledge, allowed) -> Detection:
    """kind: wb_detail | wb_summary | ozon. Никогда не бросает исключений: сбой чтения → Detection(None)."""
    try:
        if kind == "wb_detail":
            f = wb_detail_features(path)
            if f["report_number"] is not None:
                known = knowledge.report_cabinets([f["report_number"]])
                counts = Counter(known.get(f["report_number"], ()))
                cab = decide(dict(counts), 1, allowed)
                if cab:
                    return Detection(cab, f"по номеру отчёта № {f['report_number']} — он уже есть в данных кабинета «{cab}»",
                                     {"by": "report_number", "report_number": f["report_number"]})
            if f["items"]:
                counts = knowledge.wb_item_counts(f["items"])
                cab = decide(counts, len(f["items"]), allowed)
                if cab:
                    return Detection(cab, f"по товарам файла: {counts[cab]} из {len(f['items'])} кодов номенклатуры принадлежат кабинету «{cab}»",
                                     {"by": "nomenclature", "matched": counts[cab], "total": len(f["items"])})
        elif kind == "wb_summary":
            f = wb_summary_features(path)
            known = knowledge.report_cabinets(f["report_numbers"])
            counts = Counter(c for cabs in known.values() for c in cabs)
            cab = decide(dict(counts), len(f["report_numbers"]), allowed)
            if cab:
                return Detection(cab, f"по номерам отчётов: {counts[cab]} из {len(f['report_numbers'])} уже есть в данных кабинета «{cab}»",
                                 {"by": "report_numbers", "matched": counts[cab], "total": len(f["report_numbers"])})
        elif kind == "ozon":
            f = ozon_features(path)
            counts = knowledge.ozon_sku_counts(f["skus"])
            cab = decide(counts, len(f["skus"]), allowed)
            if cab:
                return Detection(cab, f"по SKU товаров: {counts[cab]} из {len(f['skus'])} принадлежат кабинету «{cab}»",
                                 {"by": "sku", "matched": counts[cab], "total": len(f["skus"])})
    except Exception:  # определение — подсказка, а не условие загрузки
        import logging
        logging.getLogger(__name__).exception("Не удалось определить кабинет по файлу %s", path)
    return Detection(None, "кабинет по файлу определить не удалось")
