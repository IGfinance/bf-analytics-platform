-- Разбор списаний июня 2026 (17,55 млн в «Списания: Продукция и товары»
-- подробной себестоимости): цепочка событий от оплаты поставщику до списания.
-- Одна таблица событий по двум случаям (соки «ДБ» и вода «Святой ключ» 18,9 л);
-- загрузчик — src/ingest_bottling_writeoff_case.py (таблица пересоздаётся целиком).
--
-- stage_no: 0 Ввод остатка · 1 Оплата поставщику · 2 Поступление на склад · 3 Списание
-- amount — рубли БЕЗ НДС (поступление: сумма − НДС; оплата — как в банке, с НДС).
CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.writeoff_case
(
    case_name     String,    -- 'Соки ДБ' / 'Вода 18,9 л'
    stage_no      UInt8,
    stage         String,
    event_date    Date,
    document      String,    -- номер и тип документа 1С
    counterparty  String,
    nomenclature  String,
    quantity      Float64,
    price         Float64,   -- за единицу, без НДС (для поступления)
    amount        Float64,
    note          String,
    loaded_at     DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY (case_name, event_date, stage_no, document);
