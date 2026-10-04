"""Каталог «Дверей» — точек загрузки данных в проект (ТЗ 04, блок C).

Дверь = отдельный блок на странице «Загрузка». Две категории:
  standard — стандартные (шаблонные, универсальные): формат файла одинаков у всех
             проектов (отчёты площадок WB/Ozon, банковская выписка 1С, карточные PDF);
  custom   — индивидуальные: построены под конкретного клиента/источник
             (выгрузка Клиентикс).
Отнесение к категории — единственное место: PLATFORM_DOORS (kind) и SOURCE_KINDS.
Состояние для проекта (какие двери активны) считает doors_state(): чистая функция
без обращений к БД и Flask, чтобы страницы «Загрузка» и «Проекты» не расходились.
"""

from __future__ import annotations

STANDARD, CUSTOM = "standard", "custom"

# Все известные платформе площадки и те, для которых есть адаптер (ТЗ 01/Ozon).
ALL_PLATFORMS = {
    "wb": "Wildberries",
    "ozon": "Ozon",
}
SUPPORTED_PLATFORMS = {"wb", "ozon"}

# Двери площадок (кабинетные): активны, если у проекта есть кабинеты этой площадки.
PLATFORM_DOORS = (
    {"key": "wb_detail", "label": "Детальный отчёт WB", "platform": "wb", "kind": STANDARD,
     "endpoint": "upload_detail", "input_id": "files-detail", "input_name": "files", "multiple": True,
     "description": "Загрузите файлы детальных отчётов (xlsx) — данные сохранятся в wb_reports."},
    {"key": "wb_summary", "label": "Сводный отчёт + сверка", "platform": "wb", "kind": STANDARD,
     "endpoint": "upload_summary", "input_id": "file-summary", "input_name": "file", "multiple": False,
     "description": "Загрузите «Еженедельный сводный отчёт» (xlsx) — данные сохранятся в wb_report_summary, "
                    "автоматически запустится сверка с wb_reports."},
    {"key": "ozon_accruals", "label": "Начисления Ozon", "platform": "ozon", "kind": STANDARD,
     "endpoint": "upload_ozon", "input_id": "files-ozon", "input_name": "files", "multiple": True,
     "description": "Загрузите файлы «Начисления» (xlsx) из кабинета Ozon — данные сохранятся в ozon_reports."},
)

# Источники без кабинета (project_sources). Какие умеет парсить код — по наличию endpoint.
SOURCE_META = {
    "bank_1c": {"label": "Банковская выписка 1С", "accept": ".txt",
                "endpoint": "upload_bank", "description":
                "Файлы выписок 1С (txt) — данные сохранятся в bank_statements."},
    "card_pdf": {"label": "Карточная выписка PDF", "accept": ".pdf",
                 "endpoint": "upload_card", "description":
                 "PDF-справки о движении средств по картам — данные сохранятся в card_statements."},
    "klientiks": {"label": "Выгрузка Клиентикс", "accept": ".csv",
                  "endpoint": "upload_klientiks", "description":
                  "CSV-выгрузка визитов из Клиентикс — данные сохранятся в klientiks_operations."},
    "cogs_weekly": {"label": "Себестоимость, еженедельная матрица", "accept": ".xlsx",
                    "endpoint": "upload_cogs", "description":
                    "Файл «СС … от …» (лист «CC общ»): себестоимость единицы по артикулам и неделям — данные "
                    "сохранятся в wb_cogs_weekly. Записываются только новые и изменённые значения; "
                    "после загрузки показывается, какие артикулы остались без себестоимости."},
}
SUPPORTED_SOURCES = {key for key, meta in SOURCE_META.items() if "endpoint" in meta}

# Категория источника; всё, чего здесь нет, — индивидуальная дверь.
SOURCE_KINDS = {"bank_1c": STANDARD, "card_pdf": STANDARD, "klientiks": CUSTOM}


def source_kind(key: str) -> str:
    return SOURCE_KINDS.get(key, CUSTOM)


def doors_state(platforms, sources) -> list:
    """Двери в порядке показа (сначала стандартные, затем индивидуальные) с флагом
    active для проекта. platforms — площадки с кабинетами, sources — включённые
    источники (project_sources). Источник, включённый у проекта, но неизвестный коду,
    попадает в индивидуальные как неактивный (unsupported) — не пропадает молча."""
    platforms, sources = set(platforms), set(sources)
    doors = []
    for d in PLATFORM_DOORS:
        doors.append({"key": d["key"], "label": d["label"], "kind": d["kind"], "source": False,
                      "active": d["platform"] in platforms, "supported": True})
    keys = list(SOURCE_META) + sorted(k for k in sources if k not in SOURCE_META)
    for key in keys:
        meta = SOURCE_META.get(key, {})
        doors.append({"key": key, "label": meta.get("label", key), "kind": source_kind(key), "source": True,
                      "active": key in sources and key in SUPPORTED_SOURCES,
                      "supported": key in SUPPORTED_SOURCES, "enabled": key in sources})
    # устойчивая сортировка: standard раньше custom, внутри — порядок каталога
    return sorted(doors, key=lambda d: 0 if d["kind"] == STANDARD else 1)
