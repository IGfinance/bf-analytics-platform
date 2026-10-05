"""Рекламное API WB → wb_promotion_api: нарезка окон, разбор строки, вьюхи."""

from datetime import date, datetime
from pathlib import Path

import wb_promotion_api_core as c

SQL = (Path(c.__file__).parent / "schema_wb_promotion_api.sql").read_text(encoding="utf-8")


def test_chunks_cover_period_without_gaps_or_overlap():
    parts = list(c.chunks(date(2026, 1, 1), date(2026, 3, 15)))
    assert parts[0][0] == date(2026, 1, 1) and parts[-1][1] == date(2026, 3, 15)
    for (_, e1), (s2, _) in zip(parts, parts[1:]):
        assert (s2 - e1).days == 1
    assert all((e - s).days + 1 <= 31 for s, e in parts)


def test_chunks_single_day():
    assert list(c.chunks(date(2026, 8, 5), date(2026, 8, 5))) == [(date(2026, 8, 5), date(2026, 8, 5))]


def test_to_record_converts_to_moscow_date():
    raw = {"updTime": "2026-08-31T21:30:00+00:00", "campName": "1/Art_A/Поиск", "paymentType": "Баланс",
           "updNum": 5, "updSum": 101, "advertId": 7, "advertType": 9, "advertStatus": 9, "currency": "RUB"}
    r = c.to_record(raw, "CloudSix", datetime(2026, 10, 5))
    assert r[3] == datetime(2026, 9, 1, 0, 30)      # 21:30 UTC = 00:30 МСК
    assert r[4] == date(2026, 9, 1)                  # дата — по МСК
    assert r[9] == 101.0 and r[1] == 7 and r[2] == 5
    assert len(r) == len(c.COLUMNS)


def test_schema_view_keeps_nameless_campaigns_as_no_article():
    assert "'без артикула'" in SQL and "splitByChar('/', camp_name)" in SQL
    assert "FULL OUTER JOIN" in SQL  # расхождения с таблицей не прячутся


def test_parse_ts_accepts_odd_fraction_length():
    assert c.parse_ts("2026-09-01T00:32:57.95896+03:00").hour == 0
    assert c.parse_ts("2026-08-31T23:59:59+03:00").second == 59
