"""Формула метрик WB не должна разойтись между .xlsx- и API-вариантом.

API-вариант (src/schema_wb_metrics_views_api.sql) генерируется из канонических
файлов скриптом scripts/gen_wb_metrics_api_view.py. Сгенерированный файл
коммитится, чтобы схему можно было накатить без запуска Python — а этот тест
следит, что он не отстал от формулы.

Это не формальность: проект уже терял на двух копиях одной формулы (архивная
Модель 57 осталась на старой формуле лояльности и тихо расходилась с боевой,
см. заголовок schema_wb_metrics_views_sku.sql).
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "scripts" / "gen_wb_metrics_api_view.py"
OUT = ROOT / "src" / "schema_wb_metrics_views_api.sql"
RENAMER = ROOT / "src" / "schema_wb_api_as_reports.sql"


def test_generated_file_is_up_to_date():
    r = subprocess.run([sys.executable, str(GEN), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0, (
        f"{OUT.name} отстал от канонической формулы.\n"
        f"Прогоните: python3 scripts/gen_wb_metrics_api_view.py\n"
        f"{r.stdout}{r.stderr}"
    )


def test_generated_reads_api_not_xlsx():
    sql = OUT.read_text(encoding="utf-8")
    assert "FROM wb_api_realization_as_reports" in sql
    assert "FROM wb_reports" not in sql, "API-вариант не должен читать .xlsx-таблицу"


def test_generated_views_are_suffixed():
    sql = OUT.read_text(encoding="utf-8")
    assert "CREATE VIEW IF NOT EXISTS wb_metrics_by_sku_month_api" in sql
    assert "CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_month_api" in sql
    # канонические имена без суффикса не должны создаваться заново —
    # иначе накат API-схемы перезатёр бы боевые вьюхи
    assert "CREATE VIEW IF NOT EXISTS wb_metrics_by_sku_month AS" not in sql
    assert "CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_month AS" not in sql


def test_renamer_covers_every_field_the_formula_reads():
    """Все колонки wb_reports, которые читает формула, должны быть в
    вьюхе-переименователе — иначе API-вариант просто не создастся."""
    canon = (ROOT / "src" / "schema_wb_metrics_views_sku.sql").read_text(encoding="utf-8")
    renamer = RENAMER.read_text(encoding="utf-8")
    used = [
        "sale_date", "supplier_article", "product_name", "qty", "payment_reason",
        "document_type", "wb_realized_amount", "retail_price_with_discount",
        "payable_to_seller", "delivery_service_cost", "logistics_fines_corrections_type",
        "total_fines", "wb_commission_correction", "storage_cost",
        "acceptance_operations", "deductions", "loyalty_discount_compensation",
        "loyalty_program_cost", "loyalty_points_deducted",
    ]
    for col in used:
        assert col in canon, f"{col} больше не используется формулой — список в тесте устарел"
        assert f"AS {col}" in renamer, (
            f"формула читает {col}, но вьюха-переименователь его не отдаёт — "
            f"API-вариант метрик не соберётся"
        )


def test_renamer_uses_final():
    """wb_api_realization — ReplacingMergeTree: без FINAL повторная загрузка
    того же отчёта посчиталась бы дважды."""
    assert "FROM wb_api_realization FINAL" in RENAMER.read_text(encoding="utf-8")
