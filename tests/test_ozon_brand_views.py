"""Бренд-вьюхи Ozon (src/schema_ozon_metrics_views_brand.sql) не отстают от генератора и
не затрагивают боевые вьюхи. Инварианты «сумма по брендам = каноническая вьюха» проверены
на данных прода 2026-10-04 (реализация, cash-flow, xlsx — расхождение ~1e-7)."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "scripts" / "gen_ozon_brand_views.py"
OUT = ROOT / "src" / "schema_ozon_metrics_views_brand.sql"
NEW = ("ozon_product_brands", "ozon_realization_by_cabinet_brand_month",
       "ozon_metrics_by_cabinet_brand_month", "ozon_metrics_by_cabinet_brand_month_cashflow_api")
CANON = ("ozon_realization_by_cabinet_month", "ozon_metrics_by_cabinet_month",
         "ozon_metrics_by_sku_month", "ozon_metrics_by_cabinet_month_cashflow_api")


def test_generated_file_is_up_to_date():
    r = subprocess.run([sys.executable, str(GEN), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, (f"{OUT.name} отстал. Прогоните: python3 scripts/gen_ozon_brand_views.py\n"
                               f"{r.stdout}{r.stderr}")


def test_only_new_views_are_created():
    sql = OUT.read_text(encoding="utf-8")
    for name in NEW:
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" in sql
    for name in CANON:  # боевые вьюхи накат этого файла не перезаписывает
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" not in sql
        assert f"CREATE OR REPLACE VIEW {name}" not in sql


def test_no_alias_shadowing_in_cashflow_allocation():
    """Первая версия считала payable_total от уже умноженных на долю колонок (псевдоним = имя
    колонки перекрывает её в том же SELECT) — расходы × доля². Сырые колонки обязаны быть raw_*."""
    sql = OUT.read_text(encoding="utf-8")
    part = sql[sql.index("ozon_metrics_by_cabinet_brand_month_cashflow_api AS"):]
    assert "raw_logistics_cost * share AS logistics_cost" in part
    assert "c.logistics_cost AS logistics_cost" not in part


def test_brand_rules_present():
    sql = OUT.read_text(encoding="utf-8")
    assert "нет бренда" in sql and "неопознанный товар" in sql and "'Cloud Six'" in sql
    assert "greatest(" in sql  # доля по неотрицательной выручке
