"""Каталог Ozon: архивные товары обязаны попадать в справочник брендов.

visibility=ALL в Ozon Seller API архивные не отдаёт (Isonic 2026-10-04: ALL — 80,
ARCHIVED — ещё 173). Без архивных 66 % оборота Isonic оставались без бренда.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import ozon_products_core as core  # noqa: E402


def _fake_post(calls):
    catalog = {"ALL": [{"product_id": 1, "offer_id": "A", "sku": 11}],
               "ARCHIVED": [{"product_id": 2, "offer_id": "B", "sku": 22, "archived": True}]}
    attrs = {1: ("Товар A", "iSonic"), 2: ("Товар B", "")}

    def post(client_id, api_key, path, payload):
        vis = payload["filter"]["visibility"]
        calls.append((path, vis))
        if path == "/v3/product/list":
            return {"result": {"items": catalog[vis], "last_id": ""}}
        ids = [int(i) for i in payload["filter"]["product_id"]]
        found = [i for i in ids if (i == 1 and vis == "ALL") or (i == 2 and vis == "ARCHIVED")]
        return {"result": [{"id": i, "name": attrs[i][0],
                            "attributes": ([{"id": 85, "values": [{"value": attrs[i][1]}]}] if attrs[i][1] else [])}
                           for i in found]}
    return post


def test_archived_products_are_included(monkeypatch):
    calls = []
    monkeypatch.setattr(core, "_post", _fake_post(calls))
    monkeypatch.setattr(core, "get_ozon_credentials", lambda cab: ("cid", "key"))
    rows = core.collect("Кабинет")
    by_offer = {r[2]: r for r in rows}
    assert set(by_offer) == {"A", "B"}, "архивный товар потерян"
    assert by_offer["A"][5] == "iSonic"
    assert by_offer["B"][5] == "", "нет бренда в карточке — пусто, а не догадка"
    assert by_offer["B"][6] == 1, "признак archived должен сохраниться"
    assert ("/v3/product/list", "ARCHIVED") in calls
    assert ("/v4/product/info/attributes", "ARCHIVED") in calls
