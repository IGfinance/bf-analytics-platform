-- Metabase: "Таблица - Реальт - Выплаченные зарплаты" (коллекция "Реальт | Админка", id 8).
-- Дашборд: "01 Дашборд - Реальт - Выплаченные зарплаты". Источник — VIEW realt_salary_payments
-- (src/schema_realt_salary_payments.sql): банк + наличные, подстатья ДДС "ФОТ к уплате".
-- Фильтры (Field Filter на поля VIEW): Кто=payee, Отдел=department, Период=payment_date (дата оплаты).
-- Колонка "Источник" добавлена сверх запроса: без неё непонятно, почему у наличных "Не указан".
-- В Metabase хранится версия БЕЗ этого комментария (JDBC-драйвер ClickHouse падает на комментариях с
-- кавычками при подстановке параметров). Строк ~340, лимит Metabase 2000 не достигается.

SELECT
    payee                  AS "Кто",
    department             AS "Отдел",
    round(pay_amount, 2)   AS "Сумма, руб",
    accrual_date           AS "Дата начисления",
    payment_date           AS "Дата оплаты",
    source                 AS "Источник"
FROM realt_salary_payments
WHERE 1 = 1
    [[ AND {{who}} ]]
    [[ AND {{dept}} ]]
    [[ AND {{period}} ]]
ORDER BY payment_date DESC, pay_amount DESC, payee
