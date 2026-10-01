import sys
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
from planfact_api_core import COLUMNS, flatten  # noqa: E402

TS = datetime(2026, 10, 1, 5, 0, 0)


def _op(**kw):
    op = {
        "operationId": 1, "operationType": "Outcome", "operationDate": "2026-01-05",
        "isCommitted": True, "value": 100.0, "comment": None,
        "account": {"accountId": 7, "title": "Т-Банк", "companyId": 3, "currencyCode": "RUB"},
        "accountCompany": {"companyId": 3, "title": "ИП Тест"},
        "accountCurrency": {"currencyCode": "RUB"},
        "operationCategory": {"operationCategoryId": 0, "title": None},
        "boundMoveOperationId": None, "createDate": "2026-01-05T10:00:00.5",
        "modifyDate": "0001-01-01T00:00:00", "operationParts": [],
    }
    op.update(kw)
    return op


def test_split_operation_gives_row_per_part_with_sign():
    parts = [
        {"operationPartId": 10, "calculationDate": "2026-01-05", "value": 60.0,
         "project": {"projectId": 5, "title": "Бренд"}, "contrAgent": {"contrAgentId": 9, "title": "К"},
         "operationCategory": {"operationCategoryId": 4, "title": "Аренда", "operationCategoryType": "Operating"}},
        {"operationPartId": 11, "calculationDate": "2026-01-05", "value": 40.0,
         "project": {"projectId": 6, "title": "Другой"}, "contrAgent": None,
         "operationCategory": {"operationCategoryId": 4, "title": "Аренда", "operationCategoryType": "Operating"}},
    ]
    rows = flatten(_op(operationParts=parts), TS)
    assert len(rows) == 2
    r = dict(zip(COLUMNS, rows[0]))
    assert (r["part_id"], r["part_value"], r["amount"], r["operation_value"]) == (10, 60.0, -60.0, 100.0)
    assert r["category_title"] == "Аренда" and r["pf_project"] == "Бренд" and r["operation_date"] == date(2026, 1, 5)
    assert dict(zip(COLUMNS, rows[1]))["contragent_id"] is None
    assert sum(dict(zip(COLUMNS, x))["part_value"] for x in rows) == 100.0


def test_move_without_parts_is_single_row_part_zero():
    rows = flatten(_op(operationType="Income", boundMoveOperationId=55), TS)
    assert len(rows) == 1
    r = dict(zip(COLUMNS, rows[0]))
    assert r["part_id"] == 0 and r["is_move"] == 1 and r["amount"] == 100.0
    assert r["category_id"] is None and r["modify_date"] is None
    assert len(rows[0]) == len(COLUMNS)
