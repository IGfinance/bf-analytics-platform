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


def test_renamer_uses_final_on_both_tables():
    """wb_api_realization и cbr_rates — обе ReplacingMergeTree: без FINAL
    повторная загрузка отчёта или курса посчиталась бы дважды. У курсов это
    особенно коварно: задвоенный курс размножил бы строки ASOF-джойном."""
    sql = RENAMER.read_text(encoding="utf-8")
    assert "FROM wb_api_realization AS d FINAL" in sql, "нет FINAL у данных"
    assert "FROM cbr_rates FINAL" in sql, "нет FINAL у курсов"


# --- валютная конверсия -------------------------------------------------------
# NoxLab — киргизский кабинет, WB отдаёт его отчёты в сомах. Без конверсии мы
# складывали сомы с рублями: именно отсюда бралось «необъяснимое» расхождение
# NoxLab во внешней сверке на 12-16%.

RATES = ROOT / "src" / "schema_cbr_rates.sql"


def test_money_columns_are_converted():
    """Каждая денежная колонка обязана быть умножена на курс. Пропущенная
    колонка — это сомы, выданные за рубли, и заметить это в отчёте нельзя."""
    sql = RENAMER.read_text(encoding="utf-8")
    money = [
        "wb_realized_amount", "retail_price_with_discount", "payable_to_seller",
        "delivery_service_cost", "total_fines", "storage_cost",
        "acceptance_operations", "deductions", "loyalty_discount_compensation",
        "loyalty_program_cost", "loyalty_points_deducted", "retail_price",
    ]
    for col in money:
        line = next((l for l in sql.splitlines() if f"AS {col}" in l), None)
        assert line is not None, f"колонка {col} пропала из вьюхи-переименователя"
        assert "* r.fx" in line, f"денежная колонка {col} не умножена на курс: {line.strip()}"


def test_percent_and_qty_columns_are_not_converted():
    """Проценты и количества умножать на курс нельзя — это не деньги."""
    sql = RENAMER.read_text(encoding="utf-8")
    for col in ("qty", "delivery_qty", "return_qty", "platform_discount_pct", "kvv_pct"):
        line = next((l for l in sql.splitlines() if f"AS {col}" in l), None)
        assert line is not None, f"колонка {col} пропала"
        assert "fx" not in line, f"{col} не деньги, курс к ней не применяется: {line.strip()}"


def test_missing_rate_yields_null_not_one():
    """Если курса на дату нет, деньги должны стать NULL, а НЕ пройти по курсу 1:
    неконвертированные сомы, выданные за рубли, хуже пропуска."""
    sql = RENAMER.read_text(encoding="utf-8")
    assert "CAST(NULL AS Nullable(Float64)))" in sql
    assert "multiIf(d.currency = 'RUB', toFloat64(1)" in sql


def test_rate_is_per_single_unit():
    """ЦБ котирует сом за 100 единиц. Использование value вместо rate даёт
    ошибку ровно в 100 раз, поэтому конверсия обязана брать rate."""
    assert "value / nominal" in (ROOT / "src" / "ingest_cbr_rates.py").read_text(encoding="utf-8")
    assert "c.rate" in RENAMER.read_text(encoding="utf-8")


def test_conversion_keyed_on_currency_not_cabinet():
    """Привязка к валюте из данных, а не к имени кабинета: появится второй
    зарубежный кабинет — заработает само."""
    sql = RENAMER.read_text(encoding="utf-8")
    assert "d.currency = c.currency" in sql
    assert "'NoxLab'" not in sql, "имя кабинета не должно быть зашито в конверсию"


def test_storage_rows_dated_by_rr_date():
    """Правило датировки зависит от типа операции — так датирует сам .xlsx.
    Хранение проводится следующим днём после начисления (18:00 UTC), и по
    московской дате sale_dt январь NoxLab дал бы 1350.33 вместо 923.70."""
    sql = RENAMER.read_text(encoding="utf-8")
    assert "d.seller_oper_name IN ('Хранение', 'Коррекция хранения'), d.rr_date" in sql
    assert "coalesce(toDate(d.sale_dt + INTERVAL 3 HOUR), d.rr_date)" in sql
