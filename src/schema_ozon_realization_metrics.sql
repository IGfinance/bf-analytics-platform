-- Строки 01-07 отчёта для адаптера Ozon из НОВОГО метода «Отчёт о реализации»
-- (ozon_realization, см. schema_ozon_realization.sql).
--
-- ЗАЧЕМ ОТДЕЛЬНО ОТ CASHFLOW. Отчёт для адаптера на API
-- (ozon_adapter_report_api.sql) строится на cash-flow-statement, и тот НЕ
-- разбивает выручку и комиссию: delivery.amount приходит одним числом
-- «выручка минус базовая комиссия». Поэтому строки 01-06 из него взять
-- нельзя — их даёт этот метод, где есть и количество, и цена, и комиссия
-- отдельными полями.
--
-- РАЗБИВКА У OZON СВОЯ, не такая, как в .xlsx:
--   .xlsx:        выручка + СПП + комиссия + корректировки = к перечислению
--   realization:  amount + bonus + софинансирование - standard_fee = total
-- Проверено на CloudSix за январь 2026 (полностью загруженный .xlsx):
--   total          7 788 493.69 = payable_for_goods .xlsx — ТОЧНО
--   standard_fee   5 054 996.31 = |commission| .xlsx     — ТОЧНО
--   amount+coinv   7 891 246.59 vs sales_amount 7 892 272.86 — расх. 1 026 ₽
--   bonus          6 302 967.41 vs spp_amount   6 303 966.14 — расх.   999 ₽
--   сумма по deliv 14 194 214   vs sales_with_spp 14 196 239 — расх. 2 025 ₽
--   сумма по return 1 350 724   vs corrections   1 352 749   — расх. 2 025 ₽
-- То есть 0.014% на 14 млн. Остаток не подгоняется и не прячется: он
-- измерен и записан здесь, потому что разбивки у площадки действительно
-- разные, и требовать от них совпадения до копейки было бы неверно.
--
-- СОФИНАНСИРОВАНИЕ (bank_coinvestment, pick_up_point_coinvestment) отнесено
-- к ВЫРУЧКЕ, а не к СПП: без него расхождение по выручке было бы 65 994 ₽
-- вместо 1 026 ₽. Это решение, проверенное числом, а не догадка.
--
-- ВОЗВРАТЫ: kind='return' идёт в корректировки (строка 06) целиком, как в
-- .xlsx, а не вычитается из выручки. Количество (строка 01) — наоборот,
-- поставки минус возвраты, тоже как в .xlsx.
--
-- ПОКРЫТИЕ на 2026-09-28: 6 кабинетов, январь-август 2026. У cash-flow
-- кабинетов 8 — поэтому отчёт для адаптера джойнит эту вьюху ВЛЕВО: строки
-- 08-15 есть у всех восьми, а 01-07 только там, где есть реализация.

CREATE VIEW IF NOT EXISTS ozon_realization_by_cabinet_month AS
SELECT
    cabinet                                                      AS cabinet,
    toStartOfMonth(stop_date)                                    AS month,

    toInt64(sumIf(quantity, kind = 'delivery')
          - sumIf(quantity, kind = 'return'))                    AS sales_qty,

    sumIf(amount + bank_coinvestment + pick_up_point_coinvestment
          + bonus, kind = 'delivery')                            AS sales_with_spp,
    sumIf(amount + bank_coinvestment + pick_up_point_coinvestment,
          kind = 'delivery')                                     AS sales_amount,
    sumIf(bonus, kind = 'delivery')                              AS spp_amount,

    -- комиссия расходом, знак как в .xlsx-модели
    -(sumIf(standard_fee, kind = 'delivery')
      - sumIf(standard_fee, kind = 'return'))                    AS commission,

    -- возвраты целиком в корректировки, расходом
    -sumIf(amount + bank_coinvestment + pick_up_point_coinvestment
           + bonus, kind = 'return')                             AS returns_corrections,

    sumIf(total, kind = 'delivery')
      - sumIf(total, kind = 'return')                            AS payable_for_goods
FROM ozon_realization
GROUP BY cabinet, month
ORDER BY cabinet, month;

ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN sales_qty 'Кол-во продаж = поставки минус возвраты (kind delivery/return). На CloudSix расходится с .xlsx на 2-4 шт в месяц.';
ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN sales_amount 'Выручка = amount + софинансирование банка и ПВЗ, по поставкам. Софинансирование отнесено сюда, а не к СПП: проверено числом — без него расхождение с .xlsx было бы 65 994 ₽ вместо 1 026 ₽.';
ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN spp_amount 'СПП = bonus по поставкам. Расхождение с .xlsx 999 ₽ на 6.3 млн.';
ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN commission 'Комиссия = -standard_fee (поставки минус возвраты). Совпадает с .xlsx ТОЧНО.';
ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN returns_corrections 'Корректировки = возвраты целиком, расходом. Разбивка у Ozon своя, поэтому с .xlsx расходится на 2 025 ₽ из 1.35 млн.';
ALTER TABLE ozon_realization_by_cabinet_month COMMENT COLUMN payable_for_goods 'К перечислению за товар = total (поставки минус возвраты). Совпадает с .xlsx ТОЧНО и с payable_for_goods из cash-flow тоже.';
