"""«Детальный адаптер»: вьюхи с полным набором статей (src/schema_detail_adapter_views.sql).

Инварианты на данных (сумма листьев группы = каноническая метрика бренд-вьюхи; блок «1 Начисления»
= payable_total) проверены на проде 2026-10-04 для WB xlsx/API, Ozon xlsx/API — расхождение ~1e-6.
Тест следит за текстом: актуальность файла, отсутствие копий формул и ловушек, найденных при разработке.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import gen_detail_adapter_views as gen  # noqa: E402

GEN = ROOT / "scripts" / "gen_detail_adapter_views.py"
OUT = ROOT / "src" / "schema_detail_adapter_views.sql"
CANON_CASHFLOW = ROOT / "src" / "schema_ozon_cashflow_metrics_views.sql"
NEW = ("ozon_cashflow_items_classified", "detail_adapter_wb", "detail_adapter_wb_api",
       "detail_adapter_ozon", "detail_adapter_ozon_api")
CANON = ("wb_metrics_by_sku_month", "wb_metrics_by_cabinet_month", "ozon_metrics_by_cabinet_month_cashflow_api",
         "ozon_metrics_by_sku_month")


def test_generated_file_is_up_to_date():
    r = subprocess.run([sys.executable, str(GEN), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, f"прогоните scripts/gen_detail_adapter_views.py\n{r.stdout}{r.stderr}"


def test_only_new_views_are_created():
    sql = OUT.read_text(encoding="utf-8")
    for name in NEW:
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" in sql
    for name in CANON:
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" not in sql
        assert f"CREATE OR REPLACE VIEW {name}" not in sql


def _view(sql: str, name: str) -> str:
    start = sql.index(f"CREATE VIEW IF NOT EXISTS {name} AS")
    end = sql.find("CREATE VIEW IF NOT EXISTS", start + 10)
    return sql[start:end if end > 0 else None]


def test_wb_view_scans_raw_table_once_and_has_no_brand_alias_shadowing():
    """Раньше каждая статья была отдельным SELECT к сырой таблице (11 сканирований, таймаут Metabase) и
    результат бренда назывался brand, перекрывая колонку brand в том же выражении."""
    sql = OUT.read_text(encoding="utf-8")
    for name, src in (("detail_adapter_wb", "FROM wb_reports"),
                      ("detail_adapter_wb_api", "FROM wb_api_realization_as_reports")):
        v = _view(sql, name)
        assert v.count(src) == 1, f"{name}: сырая таблица должна читаться один раз"
        assert "AS brand_key" in v
        assert re.search(r"\) AS brand,\n\s+formatDateTime", v) is None
    assert _view(sql, "detail_adapter_wb").count("FROM wb_metrics_by_cabinet_brand_month\n") == 1


def test_wb_whitelist_is_extracted_from_canonical():
    items = gen.wb_whitelist()
    assert "'продажа'" in items and "'возврат'" in items


def test_every_cashflow_item_has_russian_label():
    """Каждый item_name из канонической классификации должен иметь русское название, иначе в отчёте
    будет технический код. Новый код Ozon → сначала допишите название в CASHFLOW_LABELS."""
    canon = CANON_CASHFLOW.read_text(encoding="utf-8")
    names = set(re.findall(r"'((?:Marketplace|Accrual|Fines|Insurance|Operation)[A-Za-z0-9]+)'", canon))
    missing = sorted(n for n in names if n not in gen.CASHFLOW_LABELS)
    assert not missing, f"нет русского названия: {missing}"


def test_ozon_api_reads_canonical_classification():
    sql = OUT.read_text(encoding="utf-8")
    v = _view(sql, "detail_adapter_ozon_api")
    assert "ozon_cashflow_items_classified" in v and "share" in v
    assert "item_name AS item_name" in _view(sql, "ozon_cashflow_items_classified")
