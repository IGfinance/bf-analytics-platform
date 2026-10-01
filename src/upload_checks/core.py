"""Общие типы и проверки загрузки: результат проверки, отказ, журнал.

Правила (ТЗ 04):
  * error — загрузка отклоняется ДО записи (pre_ingest) либо данные записаны, но
    не сходятся (post_ingest, об этом сказано в сообщении);
  * warn  — стоит обратить внимание, загрузка идёт;
  * info  — справочно (например, число пропущенных дублей).
Дубли — НЕ ошибка: это info.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field, asdict
from typing import Iterable

import yaml

log = logging.getLogger(__name__)

INFO, WARN, ERROR = "info", "warn", "error"

JOURNAL_TABLE = "upload_checks"
JOURNAL_COLUMNS = [
    "user_id", "project", "cabinet", "source", "source_file", "check_name",
    "severity", "message", "rows_in_file", "rows_written", "duplicates_skipped",
]


@dataclass
class CheckResult:
    name: str
    severity: str
    message: str
    details: dict = field(default_factory=dict)

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class FileOutcome:
    """Итог по одному файлу: сколько строк было, сколько записано, сколько дублей."""
    source_file: str
    rows_in_file: int = 0
    rows_written: int = 0
    duplicates_skipped: int = 0
    results: list = field(default_factory=list)


class UploadRejected(Exception):
    """Жёсткая ошибка проверки файла: в базу ничего не записано."""

    def __init__(self, results: list):
        self.results = results
        super().__init__("; ".join(r.message for r in results if r.severity == ERROR))


def has_errors(results: Iterable[CheckResult]) -> bool:
    return any(r.severity == ERROR for r in results)


def normalize_header(header) -> str:
    """Та же нормализация, что в wb_core/ozon_core (двойные пробелы → один)."""
    return re.sub(r"\s+", " ", str(header).strip())


def load_column_specs(mapping_path) -> dict:
    """canonical -> {type, optional}. Из column_mapping_*.yaml; флаг optional: true
    помечает колонки, которых в части реальных файлов нет (WB: chrt_id и др.)."""
    with open(mapping_path, encoding="utf-8") as f:
        raw = yaml.safe_load(f)["columns"]
    return {
        canon: {"type": info["type"], "optional": bool(info.get("optional", False))}
        for canon, info in raw.items()
    }


def check_headers(headers: list, alias_to_canonical: dict, specs: dict) -> list:
    """Проверка заголовков файла против маппинга.

    * пропала обязательная денежная колонка (Float64) — error: иначе суммы молча
      станут NULL и метрики занизятся;
    * пропала прочая обязательная колонка — warn;
    * заголовок не из маппинга — warn (значения уйдут в extra_columns, но, если
      это деньги, метрики их не увидят).
    """
    results = []
    found = set()
    unmapped = []
    for h in headers:
        canon = alias_to_canonical.get(normalize_header(h))
        if canon:
            found.add(canon)
        else:
            unmapped.append(str(h))

    missing_money = [c for c, s in specs.items()
                     if not s["optional"] and s["type"] == "Float64" and c not in found]
    missing_other = [c for c, s in specs.items()
                     if not s["optional"] and s["type"] != "Float64" and c not in found]

    if missing_money:
        results.append(CheckResult(
            "missing_money_columns", ERROR,
            "В файле нет обязательных денежных колонок (возможно, переименованы): "
            + ", ".join(missing_money) + ". Файл не загружен — обновите маппинг колонок.",
            {"columns": missing_money},
        ))
    if missing_other:
        results.append(CheckResult(
            "missing_columns", WARN,
            "В файле нет колонок: " + ", ".join(missing_other),
            {"columns": missing_other},
        ))
    if unmapped:
        results.append(CheckResult(
            "unmapped_columns", WARN,
            "Неизвестные колонки (сохранены в extra_columns, в метриках не участвуют): "
            + ", ".join(unmapped),
            {"columns": unmapped},
        ))
    return results


def check_cabinet(cabinet: str, allowed: Iterable[str]) -> list:
    """Кабинет должен принадлежать проекту. Новых кабинетов через форму не создаём."""
    allowed = list(allowed)
    if cabinet in allowed:
        return []
    return [CheckResult(
        "cabinet_not_in_project", ERROR,
        f"Кабинет «{cabinet}» не относится к этому проекту. Выберите кабинет из списка.",
        {"allowed": allowed},
    )]


def persist(client, outcomes: Iterable[FileOutcome], *, user_id, project: str,
            cabinet: str, source: str) -> bool:
    """Пишет результаты в upload_checks БД проекта. Сбой журнала НЕ ломает загрузку
    (таблицы может ещё не быть) — только лог. Возвращает True, если записано."""
    rows = []
    for o in outcomes:
        results = o.results or [CheckResult("upload", INFO, "Проверки пройдены")]
        for r in results:
            rows.append([
                int(user_id or 0), project, cabinet, source, o.source_file, r.name,
                r.severity, r.message[:2000], o.rows_in_file, o.rows_written,
                o.duplicates_skipped,
            ])
    if not rows:
        return True
    try:
        client.insert(JOURNAL_TABLE, rows, column_names=JOURNAL_COLUMNS)
        return True
    except Exception:
        log.exception("Не удалось записать журнал загрузки в %s", JOURNAL_TABLE)
        return False
