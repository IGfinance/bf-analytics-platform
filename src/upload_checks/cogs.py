"""Источник «Себестоимость, еженедельная матрица» (wb_cogs_weekly) для проверок загрузки.

Файл — матрица «СС <проект> от <дата>.xlsx», лист «CC общ»: артикулы в строках, недели
(понедельник–воскресенье) в столбцах, значение — себестоимость ЕДИНИЦЫ товара. Каждая выгрузка
содержит все недели с начала года, поэтому еженедельная загрузка в основном перекрывает старое.

Правила (как у остальных дверей, ТЗ 04):
  * структура не та / нет недель / нет листа → ОШИБКА до записи (чужой файл не загружается);
  * неизменённые значения не перезаписываются (остаётся исходный source_file), пишутся только
    новые и изменённые; изменение истории — предупреждение с примерами: оно пересчитает прошлую
    валовую прибыль;
  * отрицательные и нулевые значения — предупреждения, а не отказ: в настоящем файле на 2026-10-04
    5 450 нулей из 20 920 (снятые/ещё не закупленные товары) и 22 отрицательных у двух артикулов
    (май 2026); нули при продажах почти не встречаются (15 ед. из 140 067);
  * после записи — «честные пробелы»: сколько проданного осталось без себестоимости (считается
    нулём, см. cogs_qty_uncovered в метриках) и какие артикулы.
"""

from __future__ import annotations

import logging
from datetime import date, timedelta
from pathlib import Path

import wb_core
import wb_cogs_core as core
from upload_checks.core import (
    CheckResult, FileOutcome, UploadRejected, ERROR, INFO, WARN, has_errors, persist,
)

log = logging.getLogger(__name__)

SOURCE = "cogs_weekly"
TOLERANCE = 0.005            # рублей: разница меньше — значение «без изменений»
MANY_CHANGED_SHARE = 0.30    # изменилось больше трети уже загруженных значений — похоже на чужую матрицу
STALE_DAYS = 14              # последняя неделя файла старше этого — файл не свежий
EXAMPLES = 5
SKU_BATCH = 500              # артикулов в одном запросе существующих значений


def _as_date(v):
    """Дата из ответа БД: драйвер отдаёт date, но тип не должен влиять на сравнение, иначе при
    несовпадении типов все значения молча стали бы «новыми»."""
    if isinstance(v, str):
        return date.fromisoformat(v[:10])
    return v.date() if hasattr(v, "date") else v


def _fmt_week(d) -> str:
    return d.strftime("%d.%m.%Y")


def _examples(items, fmt) -> str:
    shown = ", ".join(fmt(x) for x in items[:EXAMPLES])
    return shown + (f" … (всего {len(items)})" if len(items) > EXAMPLES else "")


def check_file(path: Path, sheet: str = core.DEFAULT_SHEET):
    """Структурные проверки без БД: (rows, stats, results). При ошибке структуры rows=None."""
    try:
        rows, stats = core.analyze_file(path, sheet)
    except (ValueError, RuntimeError, FileNotFoundError) as e:
        return None, None, [CheckResult(
            "not_a_cogs_file", ERROR,
            f"Файл не похож на матрицу себестоимости: {e}. Ожидается лист «{sheet}»: артикулы в строках, "
            "недели (с понедельника по воскресенье) в столбцах. Файл не загружен.")]

    results = []
    if stats["duplicate_skus"]:
        results.append(CheckResult(
            "duplicate_skus", WARN,
            "Артикулы повторяются в файле (останется последнее значение): "
            + _examples(stats["duplicate_skus"], str), {"count": len(stats["duplicate_skus"])}))
    if stats["bad_cells"]:
        results.append(CheckResult(
            "non_numeric_cells", WARN,
            f"Нечисловые значения в {len(stats['bad_cells'])} ячейках пропущены: "
            + _examples(stats["bad_cells"], lambda x: f"{x[0]} / {_fmt_week(x[1])} = «{x[2]}»"),
            {"count": len(stats["bad_cells"])}))
    if stats["negative"]:
        skus = sorted({x[0] for x in stats["negative"]})
        results.append(CheckResult(
            "negative_cost", WARN,
            f"Отрицательная себестоимость в {len(stats['negative'])} ячейках (артикулы: {_examples(skus, str)}) — "
            "значения загружены как есть, проверьте файл.",
            {"cells": len(stats["negative"]), "skus": skus}))
    return rows, stats, results


def compare_with_db(client, rows: list) -> dict:
    """Что из файла новое, что без изменений, что изменилось относительно wb_cogs_weekly."""
    skus = sorted({r[0] for r in rows})
    existing = {}
    for i in range(0, len(skus), SKU_BATCH):
        for sku, week, cost in client.query(
                "SELECT sku, week_start, unit_cost FROM wb_cogs_weekly FINAL WHERE sku IN {s:Array(String)}",
                parameters={"s": skus[i:i + SKU_BATCH]}).result_rows:
            existing[(sku, _as_date(week))] = float(cost)
    new, same, changed = [], 0, []
    for r in rows:
        old = existing.get((r[0], r[1]))
        if old is None:
            new.append(r)
        elif abs(old - r[4]) < TOLERANCE:
            same += 1
        else:
            changed.append((r, old))
    max_week = client.query("SELECT max(week_start) FROM wb_cogs_weekly").result_rows[0][0]
    max_week = _as_date(max_week) if max_week else None
    return {"new": new, "same": same, "changed": changed, "existing": len(existing), "db_max_week": max_week}


def db_results(rows: list, stats: dict, cmp: dict, today: date | None = None) -> list:
    today = today or date.today()
    results = []
    weeks = stats["weeks"]
    first, last = weeks[0][1], weeks[-1][2]
    changed = cmp["changed"]
    results.append(CheckResult(
        "summary", INFO,
        f"Недель в файле: {len(weeks)} ({_fmt_week(first)} – {_fmt_week(last)}), артикулов: {stats['skus']}. "
        f"Новых значений: {len(cmp['new'])}, без изменений (не перезаписаны): {cmp['same']}, изменено: {len(changed)}.",
        {"new": len(cmp["new"]), "same": cmp["same"], "changed": len(changed)}))
    if changed:
        by_diff = sorted(changed, key=lambda x: -abs(x[0][4] - x[1]))
        skus = {c[0][0] for c in changed}
        results.append(CheckResult(
            "changed_history", WARN,
            f"Изменилась себестоимость у {len(changed)} значений ({len(skus)} артикулов) — прошлая валовая прибыль "
            "за эти недели пересчитается. Больше всего: "
            + _examples(by_diff, lambda x: f"{x[0][5]} / {_fmt_week(x[0][1])}: {x[1]:g} → {x[0][4]:g}"),
            {"changed": len(changed), "skus": len(skus)}))
        if cmp["existing"] and len(changed) / max(cmp["existing"], 1) > MANY_CHANGED_SHARE:
            results.append(CheckResult(
                "many_changed", WARN,
                f"Изменилось {len(changed)} из {cmp['existing']} уже загруженных значений "
                f"({len(changed) * 100 // cmp['existing']} %) — убедитесь, что это тот файл."))
    if last < today - timedelta(days=STALE_DAYS):
        results.append(CheckResult(
            "stale_file", WARN,
            f"В файле нет последних недель: последняя неделя заканчивается {_fmt_week(last)}, сегодня {_fmt_week(today)}. "
            "Продажи новых недель останутся без себестоимости."))
    if cmp["db_max_week"] and weeks[-1][1] < cmp["db_max_week"]:
        results.append(CheckResult(
            "older_than_db", WARN,
            f"В базе уже есть более поздние недели (до {_fmt_week(cmp['db_max_week'])}), чем в этом файле "
            f"(до {_fmt_week(weeks[-1][1])}) — возможно, загружена старая выгрузка."))
    return results


def coverage_results(client) -> list:
    """«Честные пробелы» после записи: проданное без себестоимости (считается нулём) и продажи
    в неделях с нулевой себестоимостью. Сбой запросов — не ошибка загрузки."""
    results = []
    try:
        gaps = []
        for view in ("wb_metrics_by_sku_month", "ozon_metrics_by_sku_month"):
            try:
                rows = client.query(
                    f"SELECT sku, sum(cogs_qty_uncovered) AS uq, sum(sales_amount) AS rev FROM {view} "
                    "WHERE month >= toDateTime(toStartOfMonth(today() - 90)) + INTERVAL 12 HOUR AND sku != 'без артикула' "
                    "GROUP BY sku HAVING uq > 0 ORDER BY rev DESC").result_rows
                gaps += [(view.split("_")[0], s, float(q), float(r)) for s, q, r in rows]
            except Exception:
                log.info("Нет вьюхи %s в этой БД — покрытие по ней не считаем", view)
        if gaps:
            total_q = sum(g[2] for g in gaps)
            results.append(CheckResult(
                "uncovered_sales", WARN,
                f"Проданное без себестоимости за последние ~3 месяца: {len(gaps)} артикулов, {total_q:,.0f} ед. — "
                "они считаются по нулю (валовая прибыль завышена). Крупнейшие по выручке: "
                + _examples(gaps, lambda g: f"{g[1]} ({g[0].upper()}, {g[2]:,.0f} ед.)"),
                {"skus": len(gaps), "units": total_q}))
        else:
            results.append(CheckResult("uncovered_sales", INFO, "Проданного без себестоимости за последние ~3 месяца нет."))
        zero = client.query(
            "SELECT lowerUTF8(trim(r.supplier_article)) AS sku, sum(r.qty) AS q FROM wb_reports AS r "
            "INNER JOIN (SELECT sku, week_start FROM wb_cogs_weekly FINAL WHERE unit_cost = 0) AS w "
            "ON lowerUTF8(trim(r.supplier_article)) = w.sku AND toMonday(r.sale_date) = w.week_start "
            "WHERE lowerUTF8(trim(r.payment_reason)) = 'продажа' AND r.sale_date >= today() - 90 "
            "GROUP BY sku ORDER BY q DESC").result_rows
        if zero:
            results.append(CheckResult(
                "sales_with_zero_cost", WARN,
                f"Продажи в неделях с НУЛЕВОЙ себестоимостью (последние ~3 месяца): {len(zero)} артикулов, "
                f"{sum(float(z[1]) for z in zero):,.0f} ед. — проверьте, это не пропуск. "
                + _examples(zero, lambda z: f"{z[0]} ({float(z[1]):,.0f} ед.)")))
    except Exception:
        log.exception("Не удалось посчитать покрытие себестоимости")
    return results


def ingest(files: list, *, log_fn=print, database: str | None = None, user_id=None,
           project: str | None = None, client=None, sheet: str = core.DEFAULT_SHEET, **_) -> dict:
    """Проверяет файл(ы) и пишет в wb_cogs_weekly только новые и изменённые значения.

    Жёсткая ошибка любого файла отклоняет пакет (UploadRejected): в базу ничего не пишется."""
    client = client or wb_core.get_client(database=database)
    project = project or database or ""
    outcomes = {Path(p).name: FileOutcome(source_file=Path(p).name) for p in files}
    parsed = {}

    def _reject():
        persist(client, outcomes.values(), user_id=user_id, project=project, cabinet="", source=SOURCE)
        raise UploadRejected([r for o in outcomes.values() for r in o.results])

    for p in files:
        name = Path(p).name
        rows, stats, results = check_file(Path(p), sheet)
        outcomes[name].results.extend(results)
        if rows is not None:
            parsed[name] = (rows, stats)
            outcomes[name].rows_in_file = len(rows)
    if any(has_errors(o.results) for o in outcomes.values()):
        _reject()

    total_written = 0
    for name, (rows, stats) in parsed.items():
        cmp = compare_with_db(client, rows)
        outcomes[name].results.extend(db_results(rows, stats, cmp))
        to_write = cmp["new"] + [c[0] for c in cmp["changed"]]
        if to_write:
            client.insert("wb_cogs_weekly", to_write, column_names=core.COLUMNS)
        outcomes[name].rows_written = len(to_write)
        outcomes[name].duplicates_skipped = cmp["same"]
        total_written += len(to_write)
        log_fn(f"{name}: записано {len(to_write)} значений (новых {len(cmp['new'])}, изменённых {len(cmp['changed'])}), "
               f"без изменений {cmp['same']}.")

    cov = coverage_results(client)
    for o in outcomes.values():
        o.results.extend(cov)
    persist(client, outcomes.values(), user_id=user_id, project=project, cabinet="", source=SOURCE)

    return {
        "files": len(files), "rows": total_written,
        "rows_in_file": sum(o.rows_in_file for o in outcomes.values()),
        "duplicates_skipped": sum(o.duplicates_skipped for o in outcomes.values()),
        "unmapped_columns": [],
        "outcomes": [
            {"source_file": o.source_file, "rows_in_file": o.rows_in_file, "rows_written": o.rows_written,
             "duplicates_skipped": o.duplicates_skipped, "results": [r.as_dict() for r in o.results]}
            for o in outcomes.values()],
    }
