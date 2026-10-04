"""Бренд-вариант метрик WB (src/schema_wb_metrics_views_brand.sql) не должен
отстать от канонической формулы и не должен затрагивать боевые вьюхи.

Файл генерируется scripts/gen_wb_metrics_brand_views.py. Инвариант «сумма по
брендам = каноническая вьюха» проверен на данных прода 2026-10-04 (xlsx и API,
все 20 метрик, расхождение 0) — на данных его гоняют вручную, тест следит за
текстом.
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "scripts" / "gen_wb_metrics_brand_views.py"
OUT = ROOT / "src" / "schema_wb_metrics_views_brand.sql"


def test_generated_file_is_up_to_date():
    r = subprocess.run([sys.executable, str(GEN), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, (
        f"{OUT.name} отстал от канонической формулы.\n"
        f"Прогоните: python3 scripts/gen_wb_metrics_brand_views.py\n{r.stdout}{r.stderr}")


def test_only_new_views_are_created():
    sql = OUT.read_text(encoding="utf-8")
    for name in ("wb_metrics_by_sku_brand_month", "wb_metrics_by_cabinet_brand_month",
                 "wb_metrics_by_sku_brand_month_api", "wb_metrics_by_cabinet_brand_month_api"):
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" in sql
    # боевые вьюхи накат этого файла перезаписать не должен
    for name in ("wb_metrics_by_sku_month", "wb_metrics_by_cabinet_month",
                 "wb_metrics_by_sku_month_api", "wb_metrics_by_cabinet_month_api"):
        assert f"CREATE VIEW IF NOT EXISTS {name} AS" not in sql
        assert f"CREATE OR REPLACE VIEW {name}" not in sql


def test_brand_is_in_grain_and_cogs_join():
    sql = OUT.read_text(encoding="utf-8")
    # бренд в зерне и в ключе джойна себестоимости — иначе её задвоит
    assert sql.count("GROUP BY cabinet, month, sku, brand_key") == 4  # base + cogs_agg, xlsx и API
    assert sql.count("AND base.brand_key = c.brand_key") == 2
    assert "AS brand_key" in sql and "AS brand_key,\n" in sql
    # псевдоним не должен называться brand: перекроет колонку внутри SELECT
    assert "AS brand,\n        coalesce" not in sql


def test_blank_brand_is_its_own_value():
    sql = OUT.read_text(encoding="utf-8")
    assert "'Без бренда'" in sql
    assert "FROM wb_reports" in sql and "FROM wb_api_realization_as_reports" in sql
