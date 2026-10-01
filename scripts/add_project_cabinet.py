#!/usr/bin/env python3
"""
Регистрирует кабинет за проектом (project_cabinets в БД проекта). Единственный способ завести
кабинет: через форму загрузки кабинеты не создаются (решение владельца, ТЗ 04), опечатка на форме
не должна рождать новый кабинет. От реестра зависят переключатель кабинета на «Загрузке» и
серверная проверка кабинета.

Идемпотентно: повторный запуск ничего не меняет. Кабинет уникален В ПРЕДЕЛАХ площадки
(ключ (кабинет, площадка)); у одного кабинета может быть несколько площадок.

Примеры:
    python3 scripts/add_project_cabinet.py --project cloudsix --cabinet CloudNew --platform wb --platform ozon
    python3 scripts/add_project_cabinet.py --project cloudsix --cabinet HomeMaster --platform ozon --dry-run

Запускать на сервере (корневой .env, ClickHouse слушает только 127.0.0.1) под root.
"""

import argparse
import logging
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "src"))

from dotenv_safe import load_dotenv  # noqa: E402

load_dotenv(ROOT_DIR / ".env")

import ch_connect  # noqa: E402,F401  (ключи ClickHouse по проектам — через wb_core.get_client)
from ch_control import get_control_client  # noqa: E402
from wb_core import get_client  # noqa: E402

PLATFORMS = ("wb", "ozon")      # площадки с адаптером загрузки (webapp/doors.py)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("add_project_cabinet")


def validate(cabinet: str, platforms: list) -> list:
    """Возвращает список причин отказа (пусто — всё в порядке)."""
    errors = []
    if not cabinet or cabinet != cabinet.strip() or len(cabinet) > 64:
        errors.append("Имя кабинета пустое, с пробелами по краям или длиннее 64 символов.")
    unknown = [p for p in platforms if p not in PLATFORMS]
    if unknown:
        errors.append(f"Неизвестная площадка: {', '.join(unknown)} (допустимо: {', '.join(PLATFORMS)}).")
    if not platforms:
        errors.append("Не указана площадка (--platform).")
    return errors


def missing_pairs(existing: set, cabinet: str, platforms: list) -> list:
    """Пары (кабинет, площадка), которых ещё нет в реестре."""
    return [(cabinet, p) for p in dict.fromkeys(platforms) if (cabinet, p) not in existing]


def project_id(slug: str) -> int:
    rows = get_control_client().query(
        "SELECT id FROM projects FINAL WHERE slug = {slug:String}", parameters={"slug": slug}).result_rows
    if not rows:
        raise SystemExit(f"Проект «{slug}» не найден в control.projects.")
    return rows[0][0]


def main() -> int:
    ap = argparse.ArgumentParser(description="Зарегистрировать кабинет за проектом")
    ap.add_argument("--project", required=True, help="slug проекта (cloudsix, realt)")
    ap.add_argument("--cabinet", required=True, help="имя кабинета точно как в отчётах/API")
    ap.add_argument("--platform", action="append", default=[], help="wb | ozon (можно несколько раз)")
    ap.add_argument("--dry-run", action="store_true", help="только показать, что будет добавлено")
    args = ap.parse_args()

    errors = validate(args.cabinet, args.platform)
    if errors:
        for e in errors:
            log.error(e)
        return 2

    pid = project_id(args.project)
    client = get_client(database=args.project)
    existing = {(r[0], r[1]) for r in client.query(
        "SELECT cabinet, platform FROM project_cabinets FINAL").result_rows}
    owners = {r[0]: r[1] for r in client.query(
        "SELECT cabinet, project_id FROM project_cabinets FINAL").result_rows}
    if args.cabinet in owners and owners[args.cabinet] != pid:
        log.error("Кабинет «%s» уже закреплён за другим проектом (id=%s).", args.cabinet, owners[args.cabinet])
        return 2

    todo = missing_pairs(existing, args.cabinet, args.platform)
    if not todo:
        log.info("Кабинет «%s» уже зарегистрирован на: %s. Менять нечего.", args.cabinet, ", ".join(args.platform))
        return 0
    for cabinet, platform in todo:
        log.info("%s: %s / %s -> проект %s (id=%s)", "ДОБАВИЛ БЫ" if args.dry_run else "Добавляю",
                 cabinet, platform, args.project, pid)
    if not args.dry_run:
        client.insert("project_cabinets", [[c, pid, p] for c, p in todo],
                      column_names=["cabinet", "project_id", "platform"])
        log.info("Готово. Кабинеты проекта: %s", sorted({r[0] for r in client.query(
            "SELECT cabinet FROM project_cabinets FINAL").result_rows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
