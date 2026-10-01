"""Результаты «Тестов» из Metabase для страницы «Дашборд» (ТЗ 04, блок B).

Источник — коллекция «Тесты/<проект>» в Metabase, читаемая отдельным ключом
ТОЛЬКО на чтение (METABASE_TESTS_API_KEY, группа «Вебапп report - чтение тестов»).
Формулы проверок живут только в карточках Metabase — здесь SQL не дублируется.

Контракт карточки-теста: результат — несошедшиеся строки, пустой результат = тест
пройден. Необязательная колонка «Уровень» (error | warn) задаёт серьёзность строки;
без неё строка считается error.

Состояния отчёта (никогда не «зелёный по умолчанию»):
  ok          — получили результаты по всем тестам
  empty       — для проекта нет подколлекции или в ней нет карточек
  unavailable — Metabase недоступен/ключ не задан и кэша нет
Состояния теста: ok | warn | error | failed (карточка не выполнилась).
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Optional

import requests

log = logging.getLogger(__name__)

TESTS_COLLECTION_NAME = "Тесты"
LEVEL_COLUMN = "Уровень"
MAX_ROWS_SHOWN = 50
REQUEST_TIMEOUT_S = 60
SEVERITY_ORDER = {"ok": 0, "warn": 1, "error": 2, "failed": 2}


@dataclass
class TestResult:
    card_id: int
    name: str
    description: str
    status: str                       # ok | warn | error | failed
    columns: list = field(default_factory=list)
    rows: list = field(default_factory=list)
    rows_total: int = 0
    message: str = ""                 # понятная причина для status=failed


@dataclass
class TestsReport:
    state: str                        # ok | empty | unavailable
    results: list = field(default_factory=list)
    fetched_at: float = 0.0
    stale: bool = False               # показан кэш, обновить не удалось
    message: str = ""

    def counts(self) -> dict:
        counts = {"ok": 0, "warn": 0, "error": 0, "failed": 0}
        for r in self.results:
            counts[r.status] += 1
        return counts

    @property
    def overall(self) -> str:
        """Худший статус; для empty/unavailable — само состояние (не «ok»)."""
        if self.state != "ok":
            return self.state
        worst = "ok"
        for r in self.results:
            if SEVERITY_ORDER[r.status] > SEVERITY_ORDER[worst]:
                worst = r.status
        return worst


class MetabaseTestsClient:
    def __init__(self, base_url: str, api_key: str, ttl_seconds: int = 300, session=None):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.ttl = ttl_seconds
        self.session = session or requests.Session()
        self._cache: dict = {}
        self._lock = threading.Lock()

    # --- HTTP -------------------------------------------------------------
    def _get(self, path: str):
        r = self.session.get(self.base_url + path, headers={"x-api-key": self.api_key},
                             timeout=REQUEST_TIMEOUT_S)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str):
        r = self.session.post(self.base_url + path, headers={"x-api-key": self.api_key},
                              timeout=REQUEST_TIMEOUT_S)
        r.raise_for_status()
        return r.json()

    # --- логика -----------------------------------------------------------
    def _find_project_collection(self, project_keys: list) -> Optional[int]:
        tree = self._get("/api/collection/tree")
        wanted = {k.strip().lower() for k in project_keys if k}
        for root in tree:
            if root.get("name") == TESTS_COLLECTION_NAME:
                for child in root.get("children", []):
                    if str(child.get("name", "")).strip().lower() in wanted:
                        return child["id"]
        return None

    def _run_card(self, card: dict) -> TestResult:
        base = dict(card_id=card["id"], name=_display_name(card["name"]),
                    description=card.get("description") or "")
        try:
            data = self._post(f"/api/card/{card['id']}/query")
        except Exception as e:
            log.warning("Тест %s не выполнен: %s", card["id"], type(e).__name__)
            return TestResult(**base, status="failed",
                              message="Проверка не выполнилась (ошибка при запуске в Metabase).")
        if data.get("status") == "failed" or data.get("error"):
            log.warning("Тест %s вернул ошибку Metabase", card["id"])
            return TestResult(**base, status="failed",
                              message="Проверка не выполнилась (ошибка в запросе).")
        cols = [c.get("display_name") or c.get("name") for c in data["data"]["cols"]]
        rows = data["data"]["rows"]
        if not rows:
            return TestResult(**base, status="ok", columns=cols)
        status = "warn"
        if LEVEL_COLUMN in cols:
            idx = cols.index(LEVEL_COLUMN)
            if any(str(r[idx]).lower() != "warn" for r in rows):
                status = "error"
        else:
            status = "error"
        shown_cols = [c for c in cols if c != LEVEL_COLUMN]
        keep = [i for i, c in enumerate(cols) if c != LEVEL_COLUMN]
        shown = [[_cell(r[i]) for i in keep] for r in rows[:MAX_ROWS_SHOWN]]
        return TestResult(**base, status=status, columns=shown_cols, rows=shown, rows_total=len(rows))

    def _fetch(self, project_keys: list) -> TestsReport:
        coll_id = self._find_project_collection(project_keys)
        if coll_id is None:
            return TestsReport("empty", fetched_at=time.time(),
                               message="Для этого проекта ещё нет проверок.")
        items = self._get(f"/api/collection/{coll_id}/items?models=card")["data"]
        cards = [c for c in items if c.get("model") == "card" and not c.get("archived")]
        if not cards:
            return TestsReport("empty", fetched_at=time.time(),
                               message="Для этого проекта ещё нет проверок.")
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(self._run_card, cards))
        results.sort(key=lambda r: (-SEVERITY_ORDER[r.status], r.name))
        return TestsReport("ok", results, fetched_at=time.time())

    def get_report(self, project_keys: list, refresh: bool = False) -> TestsReport:
        key = "|".join(sorted(k.lower() for k in project_keys if k))
        now = time.time()
        with self._lock:
            cached = self._cache.get(key)
        if cached and not refresh and now - cached.fetched_at < self.ttl:
            return cached
        try:
            report = self._fetch(project_keys)
        except Exception as e:
            log.error("Metabase недоступен для «Тестов»: %s", type(e).__name__)
            if cached:
                return TestsReport(cached.state, cached.results, cached.fetched_at, stale=True,
                                   message="Не удалось обновить, показан последний результат.")
            return TestsReport("unavailable", fetched_at=now,
                               message="Проверки временно недоступны.")
        with self._lock:
            self._cache[key] = report
        return report


def _display_name(name: str) -> str:
    """«Таблица - CloudSix - Тест WB …» → «Тест WB …» (тип и проект в названии — служебные)."""
    parts = [p.strip() for p in name.split(" - ")]
    return parts[-1] if parts else name


_MIDNIGHT = re.compile(r"^(\d{4}-\d{2}-\d{2})T00:00:00(?:\.0+)?(?:[+-]\d{2}:\d{2}|Z)?$")


def _cell(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        m = _MIDNIGHT.match(value)
        if m:                                   # дата без времени — только дата
            y, mo, d = m.group(1).split("-")
            return f"{d}.{mo}.{y}"
    if isinstance(value, float):
        return f"{value:,.2f}".replace(",", " ")
    return str(value)


_client: Optional[MetabaseTestsClient] = None


def get_client() -> Optional[MetabaseTestsClient]:
    """Клиент из окружения; None, если ключ/адрес не заданы (страница покажет unavailable)."""
    global _client
    if _client is None:
        url, key = os.environ.get("METABASE_URL"), os.environ.get("METABASE_TESTS_API_KEY")
        if not url or not key:
            return None
        ttl = int(os.environ.get("TESTS_CACHE_TTL_SECONDS", "300"))
        _client = MetabaseTestsClient(url, key, ttl)
    return _client


def get_project_report(project: dict, refresh: bool = False) -> TestsReport:
    client = get_client()
    if client is None:
        log.error("METABASE_URL/METABASE_TESTS_API_KEY не заданы")
        return TestsReport("unavailable", fetched_at=time.time(), message="Проверки временно недоступны.")
    return client.get_report([project.get("name"), project.get("slug")], refresh=refresh)
