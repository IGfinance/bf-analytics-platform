#!/usr/bin/env python3
"""
Резолвер API-ключей WB/Ozon по кабинету — источник правды: JSON-файл вне
git (secrets/, см. .gitignore), путь задаётся CABINET_API_KEYS_FILE
(по умолчанию secrets/cabinet_api_keys.json от корня репозитория).

Ключ верхнего уровня в JSON — бренд/название кабинета (то же значение,
что передаётся в --cabinet), НЕ фамилия владельца юрлица: кабинеты не
называются фамилиями (см. переписку 2026-09-20). Одна фамилия может
владеть несколькими кабинетами на одной площадке (напр. Казакова —
HomeMaster и X-Tech на Ozon), а один кабинет — иметь разные юрлица на
разных площадках (напр. NoxLab: Wb — Мамажанов, Ozon — Беркутова).
Поле legal_entity в каждой WB/Ozon-записи — справочное, для будущей
сверки бренда с тем, что реально вернёт API.

До этого модуля ingest_wb_api.py/ingest_ozon_api.py брали токен из ОДНОГО
глобального WILDBERRIES_API/OZON_API в .env — одинаковый ключ для всех
--cabinet, хотя у каждого кабинета своя учётка на площадке. Теперь ключ
резолвится по имени кабинета, а не берётся из общего env.
"""

import json
import os
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent


def _keys_path() -> Path:
    raw = os.environ.get("CABINET_API_KEYS_FILE", "secrets/cabinet_api_keys.json")
    path = Path(raw)
    return path if path.is_absolute() else REPO_ROOT / path


def _load() -> dict:
    path = _keys_path()
    if not path.exists():
        raise FileNotFoundError(
            f"Не найден файл с ключами кабинетов: {path}. "
            "Задайте CABINET_API_KEYS_FILE или создайте secrets/cabinet_api_keys.json."
        )
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def get_wb_token(cabinet: str) -> str:
    data = _load()
    entry = data.get(cabinet, {}).get("wb")
    if not entry or not entry.get("token"):
        known = sorted(k for k, v in data.items() if v.get("wb"))
        raise KeyError(f"Нет WB-ключа для кабинета {cabinet!r}. Есть ключи для: {known}")
    return entry["token"]


def get_ozon_credentials(cabinet: str) -> tuple[str, str]:
    data = _load()
    entry = data.get(cabinet, {}).get("ozon")
    if not entry or not entry.get("api_key"):
        known = sorted(k for k, v in data.items() if v.get("ozon"))
        raise KeyError(f"Нет Ozon-ключа для кабинета {cabinet!r}. Есть ключи для: {known}")
    if not entry.get("client_id"):
        raise KeyError(
            f"Для кабинета {cabinet!r} есть Ozon Api-Key, но нет Client-Id "
            f"(secrets/cabinet_api_keys.json → {cabinet}.ozon.client_id). "
            "Заполните перед загрузкой."
        )
    return entry["client_id"], entry["api_key"]
