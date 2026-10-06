-- Выплаченные зарплаты Реальта одной плоской таблицей: кто, отдел, сумма, дата начисления, дата оплаты.
--
-- Источник — регистры движения денег (то, что реально выплачено), а не realt_payroll (там только начисления
-- по месяцам, без даты оплаты): realt_bank_account (расчётные счета) и realt_cash (наличные), строки с
-- подстатьёй ДДС «ФОТ к уплате» (cf_subarticle). Знак: расход в регистрах отрицательный, здесь сумма
-- выплаты положительная; возвраты/сторно остаются отрицательными.
--
-- Известные ограничения источника (не додумываем — показываем как есть):
--  * Банк: получатель — как в платёжке. Часть выплат идёт через банковские реестры (контрагент «АО
--    "АЛЬФА-БАНК"», «ООО "Банк Точка"»): конкретный сотрудник по таким строкам не определяется.
--  * Наличные: получателя в регистре нет — подписано «Не указан, наличные», кто получил, видно только
--    из назначения платежа (purpose).
--  * Дата начисления в регистре почти всегда равна дате оплаты (банк: 279 из 281 строк), у наличных
--    не заполнена. Настоящее начисление по сотруднику (месяц, «К оплате») — в realt_payroll; связь
--    «платёж ↔ начисление» по ФИО/месяцу здесь НЕ делается, чтобы не подставлять догадки.
--  * Отдел — поле «Проект» регистра (3 этаж / АПДШ / ШАА).
-- FINAL обязателен (ReplacingMergeTree).

CREATE OR REPLACE VIEW realt_salary_payments AS
SELECT
    source,
    payee,
    department,
    pay_amount,
    accrual_date,
    payment_date,
    purpose
FROM
(
    SELECT
        'Банк'                                                    AS source,
        coalesce(nullIf(trim(counterparty), ''), 'Не указан')     AS payee,
        coalesce(nullIf(trim(project), ''), 'Без отдела')         AS department,
        -amount_signed                                            AS pay_amount,
        accrual_date                                              AS accrual_date,
        operation_date                                            AS payment_date,
        purpose                                                   AS purpose
    FROM realt_bank_account FINAL
    WHERE cf_subarticle = 'ФОТ к уплате'

    UNION ALL

    SELECT
        'Наличные'                                                AS source,
        'Не указан, наличные'                                     AS payee,
        coalesce(nullIf(trim(project), ''), 'Без отдела')         AS department,
        -amount                                                   AS pay_amount,
        accrual_date                                              AS accrual_date,
        operation_date                                            AS payment_date,
        purpose                                                   AS purpose
    FROM realt_cash FINAL
    WHERE cf_subarticle = 'ФОТ к уплате'
);
