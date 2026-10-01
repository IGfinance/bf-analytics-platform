"""scripts/add_project_cabinet.py: проверка ввода и идемпотентность (без ClickHouse)."""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
spec = importlib.util.spec_from_file_location("add_project_cabinet", ROOT / "scripts" / "add_project_cabinet.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def test_validate_accepts_normal_input():
    assert mod.validate("CloudNew", ["wb", "ozon"]) == []


def test_validate_rejects_bad_cabinet_platform_and_missing_platform():
    assert mod.validate(" CloudNew", ["wb"]) and mod.validate("", ["wb"]) and mod.validate("x" * 65, ["wb"])
    assert any("Неизвестная площадка" in e for e in mod.validate("A", ["yandex"]))
    assert any("Не указана площадка" in e for e in mod.validate("A", []))


def test_missing_pairs_is_idempotent_and_deduplicates():
    existing = {("CloudNew", "ozon")}
    assert mod.missing_pairs(existing, "CloudNew", ["wb", "ozon", "wb"]) == [("CloudNew", "wb")]
    assert mod.missing_pairs(existing, "CloudNew", ["ozon"]) == []
    assert mod.missing_pairs(set(), "HomeMaster", ["ozon"]) == [("HomeMaster", "ozon")]
