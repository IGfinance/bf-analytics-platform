-- Проверка "отчёт к отчёту": сырые строки финансового API WB против
-- недельного сводного отчёта (метод list). Эталон для WB — недельная
-- сводка (решение владельца 2026-09-29).
--
-- Выводит только НЕсошедшиеся отчёты — пустой результат = всё сходится.
-- Суммы в валюте отчёта (NoxLab — сомы), поэтому здесь сырой
-- wb_api_realization, а не рублёвый wb_api_realization_as_reports.
--
-- d_bank — та же формула, что payable_total в wb_metrics_by_sku_month
-- (после правки 2026-09-29), только без разбивки по месяцам и артикулам.
-- 2026-09-29: 550 отчётов, 0 расхождений по выплате; по "Продаже" один
-- отчёт INOVO 742779887 (+32 ₽ — в выплату не входит, не разобран).
-- Запускать в Metabase на базе "ClickHouse CloudSix".

WITH d AS (
    SELECT
        cabinet, report_id,
        coalesce(sumIf(retail_amount, doc_type_name = 'Продажа'), 0)
          - coalesce(sumIf(retail_amount, doc_type_name = 'Возврат'), 0)          AS sale,
        coalesce(sumIf(for_pay, doc_type_name = 'Продажа'), 0)
          - coalesce(sumIf(for_pay, doc_type_name = 'Возврат'), 0)                AS for_pay,
        sum(coalesce(delivery_service, 0))                                        AS logi,
        sum(coalesce(paid_storage, 0))                                            AS stor,
        sum(coalesce(paid_acceptance, 0))                                         AS acc,
        sum(coalesce(deduction, 0))                                               AS ded,
        sum(coalesce(penalty, 0))                                                 AS pen,
        sum(coalesce(additional_payment, 0))                                      AS addp,
        sum(coalesce(cashback_commission_change, 0))
          - 2 * sumIf(coalesce(cashback_commission_change, 0), doc_type_name = 'Возврат') AS loyalty_cost,
        sum(coalesce(cashback_amount, 0))
          - 2 * sumIf(coalesce(cashback_amount, 0), doc_type_name = 'Возврат')    AS loyalty_points
    FROM wb_api_realization FINAL
    GROUP BY cabinet, report_id
)
SELECT
    s.cabinet, s.report_id, s.date_from, s.date_to,
    round(d.sale    - s.retail_amount_sum, 2)     AS d_sale,
    round(d.for_pay - s.for_pay_sum, 2)           AS d_for_pay,
    round(d.logi    - s.delivery_service_sum, 2)  AS d_logistics,
    round(d.stor    - s.paid_storage_sum, 2)      AS d_storage,
    round(d.acc     - s.paid_acceptance_sum, 2)   AS d_acceptance,
    round(d.ded     - s.deduction_sum, 2)         AS d_deductions,
    round(d.pen     - s.penalty_sum, 2)           AS d_fines,
    round(d.for_pay - d.logi - d.stor - d.acc - d.ded - d.pen + d.addp
          - d.loyalty_cost - d.loyalty_points - s.bank_payment_sum, 2) AS d_bank
FROM wb_api_report_summary AS s FINAL
LEFT JOIN d ON d.cabinet = s.cabinet AND d.report_id = s.report_id
WHERE greatest(abs(d_sale), abs(d_for_pay), abs(d_logistics), abs(d_storage),
               abs(d_acceptance), abs(d_deductions), abs(d_fines), abs(d_bank)) > 0.01
   OR d.report_id = 0
ORDER BY s.cabinet, s.date_from
