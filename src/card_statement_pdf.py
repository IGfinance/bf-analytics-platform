#!/usr/bin/env python3
"""
Парсер справок о движении средств по картам физлиц (PDF) → структурированные
транзакции. Портирован из FinanceBlackSite/src/scripts/bank_statement_parser.py
(общий инструмент finance-black.ru — код парсинга по банкам не трогаем, он
хорошо протестирован) и расширен: извлекает держателя карты и номер карты
операции, которых не было в исходном варианте (там колонок и не было нужно —
xlsx с 5 колонками для общего конвертера, а здесь нужна структурированная
загрузка).

Эти выписки — обороты по личным картам физлиц (самовыкупщики и т.п.), а не
по расчётным счетам юрлица, поэтому это отдельная сущность от bank_statements
(1С-формат, см. bank_statement_1c.py) — не один и тот же р/с и другая
семантика (нет ИНН/реквизитов контрагента, зато есть держатель+номер карты).

Поддерживаемые банки: Сбер, Альфа, Т-Банк, РСХ (Россельхозбанк), Озон Банк,
Газпромбанк. На выборке CloudSix (2026-09-04) встретился только Т-Банк —
извлечение держателя карты (extract_cardholder) реализовано пока только для
него, для остальных банков возвращает None (не блокирует парсинг транзакций).
"""

import re
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent


def extract_text(pdf_path: str, layout: bool = True) -> str:
    """Извлекает текст из PDF через pdftotext (poppler)."""
    cmd = ['pdftotext']
    if layout:
        cmd.append('-layout')
    cmd.extend([pdf_path, '-'])
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"pdftotext error: {result.stderr}")
    return result.stdout


def detect_bank(text: str) -> str:
    """Определяет банк по содержимому PDF."""
    # Порядок важен: РСХ, Сбер и ТБАНК проверяем ДО Альфы, т.к. в описаниях транзакций
    # могут упоминаться другие банки (переводы, комиссии и т.п., включая «Альфа-банк»
    # в Сбер-выписках)
    t = text.upper()
    if 'РОССЕЛЬХОЗБАНК' in t:
        return 'rsh'
    if 'SBERBANK.RU' in t or 'СБЕРБАНК ОНЛАЙН' in t or 'SBERONLINE' in t:
        return 'sber'
    if 'ТБАНК' in t or 'TBANK' in t:
        return 'tbank'
    if 'АЛЬФА-БАНК' in t or 'ALFA-BANK' in t:
        return 'alfa'
    if 'ОЗОН БАНК' in t or 'ООО «ОЗОН БАНК»' in text:
        return 'ozon'
    if 'ГАЗПРОМБАНК' in t or 'GAZPROMBANK' in t or 'GAZPRUMM' in t:
        return 'gazprom'
    if 'SBERBANK' in t or 'СБЕРБАНК' in t or 'СБЕРБ' in t:
        return 'sber'
    return 'unknown'


def parse_amount_ru(s: str) -> float:
    """Парсит сумму в русском формате: '10 000,50' → 10000.50, также '-600,00' → -600.0"""
    s = s.strip()
    s = s.replace('\xa0', ' ')
    s = s.replace('₽', '').replace('RUR', '').strip()
    s = s.replace(' ', '')
    s = s.replace(',', '.')
    return float(s)


# ─── ПАРСЕР: СБЕР ──────────────────────────────────────────────

def parse_sber(text: str) -> list[dict]:
    """
    Парсит выписку Сбербанка.
    Формат строки операции:
      DD.MM.YYYY   HH:MM   auth_code   Категория       [+]amount       balance
      DD.MM.YYYY                        Описание операции
    """
    transactions = []
    lines = text.split('\n')

    start_idx = 0
    for i, line in enumerate(lines):
        if 'Расшифровка операций' in line or 'ДАТА ОПЕРАЦИИ' in line:
            start_idx = i
            break

    op_pattern = re.compile(
        r'^\s*(\d{2}\.\d{2}\.\d{4})\s+(\d{2}:\d{2})\s+'
        r'(.+?)\s{2,}'
        r'([+\-]?[\d\s]+,\d{2})\s+'
        r'([\d\s]+,\d{2})\s*$'
    )
    desc_pattern = re.compile(
        r'^\s*\d{2}\.\d{2}\.\d{4}\s+\d+(?:\s+(.+))?\s*$'
    )
    cont_pattern = re.compile(
        r'^\s{20,}(.+)$'
    )

    i = start_idx
    while i < len(lines):
        line = lines[i]
        m = op_pattern.match(line)
        if m:
            date_str = m.group(1)
            category = m.group(3).strip()
            amount_str = m.group(4).strip()

            description_parts = []
            j = i + 1
            while j < len(lines):
                dm = desc_pattern.match(lines[j])
                cm = cont_pattern.match(lines[j])
                if dm:
                    desc_text = dm.group(1).strip() if dm.group(1) else ''
                    if desc_text:
                        description_parts.append(desc_text)
                    j += 1
                elif cm and description_parts:
                    description_parts.append(cm.group(1).strip())
                    j += 1
                else:
                    break
            i = j

            description = ' '.join(description_parts) if description_parts else category

            amount_val = parse_amount_ru(amount_str)
            if not amount_str.strip().startswith('+'):
                signed_amount = -abs(amount_val)
            else:
                signed_amount = abs(amount_val)

            transactions.append({
                'date': date_str,
                'processing_date': None,
                'amount': abs(amount_val),
                'signed_amount': signed_amount,
                'description': description,
                'card_number': None,
            })
        else:
            i += 1

    return transactions


# ─── ПАРСЕР: АЛЬФА ─────────────────────────────────────────────

def parse_alfa(text: str) -> list[dict]:
    """
    Парсит выписку Альфа-Банка.
    Формат:
      DD.MM.YYYY   code   Описание                                        [-]amount RUR
    Описание может переноситься на несколько строк.
    """
    transactions = []
    lines = text.split('\n')

    start_idx = 0
    for i, line in enumerate(lines):
        if 'Операции по счету' in line or 'Дата проводки' in line:
            start_idx = i
            break

    op_pattern = re.compile(
        r'^\s*(\d{2}\.\d{2}\.\d{4})\s+'
        r'(\S+)\s+'
        r'(.+?)\s{2,}'
        r'(-?[\d\s]+,\d{2})\s*RUR\s*$'
    )
    cont_pattern = re.compile(
        r'^\s{20,}(.+?)\s{2,}$|^\s{20,}(.+)$'
    )
    stop_pattern = re.compile(r'Страница\s+\d+|подпись|Уполномоченное')

    i = start_idx
    while i < len(lines):
        line = lines[i]

        if stop_pattern.search(line):
            i += 1
            continue

        m = op_pattern.match(line)
        if m:
            date_str = m.group(1)
            desc_parts = [m.group(3).strip()]
            amount_str = m.group(4).strip()

            j = i + 1
            while j < len(lines):
                cl = lines[j]
                if op_pattern.match(cl) or re.match(r'^\s*(\d{2}\.\d{2}\.\d{4})', cl):
                    break
                cm = cont_pattern.match(cl)
                if cm:
                    part = (cm.group(1) or cm.group(2) or '').strip()
                    if part and not re.match(r'^-?[\d\s]+,\d{2}\s*RUR$', part):
                        desc_parts.append(part)
                    j += 1
                elif cl.strip() == '':
                    j += 1
                    break
                else:
                    break
            i = j

            amount_val = parse_amount_ru(amount_str)
            signed_amount = amount_val

            transactions.append({
                'date': date_str,
                'processing_date': None,
                'amount': abs(amount_val),
                'signed_amount': signed_amount,
                'description': ' '.join(desc_parts),
                'card_number': None,
            })
        else:
            i += 1

    return transactions


# ─── ПАРСЕР: Т-БАНК ────────────────────────────────────────────

def parse_tbank(text: str) -> list[dict]:
    """
    Парсит выписку Т-Банка.
    Формат:
      DD.MM.YYYY   DD.MM.YYYY   ±amount ₽   ±amount ₽   Описание   card
      HH:MM        HH:MM                                 продолжение описания
    """
    transactions = []
    lines = text.split('\n')

    start_idx = 0
    for i, line in enumerate(lines):
        if 'Движение средств за период' in line:
            start_idx = i + 1
            break

    while start_idx < len(lines):
        stripped = lines[start_idx].strip()
        if stripped.startswith('Дата') or stripped.startswith('операции'):
            start_idx += 1
        else:
            break

    # Последний столбец — обычно 4 цифры карты, но для кэшбэка/системных операций стоит «—»
    op_pattern = re.compile(
        r'^\s*(\d{2}\.\d{2}\.\d{4})\s+'
        r'(\d{2}\.\d{2}\.\d{4})\s+'
        r'([+\-][\d\s]+\.\d{2})\s*₽\s+'
        r'([+\-][\d\s]+\.\d{2})\s*₽\s+'
        r'(.+?)\s+'
        r'(\d{4}|—)\s*$'
    )
    time_pattern = re.compile(
        r'^\s*(\d{2}:\d{2})\s+(\d{2}:\d{2})\s*(.*?)\s*$'
    )
    cont_pattern = re.compile(r'^\s{40,}(.+)$')
    end_pattern = re.compile(r'^\s*(Пополнения|Расходы|С уважением|Руководитель)')

    i = start_idx
    while i < len(lines):
        line = lines[i]

        if end_pattern.match(line):
            break

        m = op_pattern.match(line)
        if m:
            date_str = m.group(1)
            processing_date_str = m.group(2)
            amount_str = m.group(3).strip()
            desc_parts = [m.group(5).strip()]
            card_number = m.group(6) if m.group(6) != '—' else None

            j = i + 1
            while j < len(lines):
                cl = lines[j]

                if op_pattern.match(cl) or end_pattern.match(cl):
                    break

                tm = time_pattern.match(cl)
                if tm:
                    extra = tm.group(3).strip()
                    if extra:
                        desc_parts.append(extra)
                    j += 1
                    continue

                cm = cont_pattern.match(cl)
                if cm:
                    desc_parts.append(cm.group(1).strip())
                    j += 1
                    continue

                if cl.strip() == '':
                    j += 1
                    break

                j += 1
            i = j

            amount_clean = amount_str.replace(' ', '').replace('₽', '')
            amount_val = float(amount_clean)
            signed_amount = amount_val

            transactions.append({
                'date': date_str,
                'processing_date': processing_date_str,
                'amount': abs(amount_val),
                'signed_amount': signed_amount,
                'description': ' '.join(desc_parts),
                'card_number': card_number,
            })
        else:
            i += 1

    return transactions


# ─── ПАРСЕР: РСХ (РОССЕЛЬХОЗБАНК) ──────────────────────────────

def parse_rsh(text_unused: str, pdf_path: str = '') -> list[dict]:
    """
    Парсит выписку Россельхозбанка.
    Использует raw-режим pdftotext для чистого извлечения описаний.
    """
    if not pdf_path:
        return []

    result = subprocess.run(
        ['pdftotext', '-raw', pdf_path, '-'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    text = result.stdout

    text = text.replace('\x0c', '\n')
    text = re.sub(r'(\d,\d{2})(\d{2}\.\d{2}\.\d{4})', r'\1\n\2', text)

    transactions = []
    lines = text.split('\n')

    start_idx = 0
    for i, line in enumerate(lines):
        if '№ карты' in line:
            start_idx = i + 1
            break
    if start_idx == 0:
        for i, line in enumerate(lines):
            if 'ПОДТВЕРЖДЕННЫЕ ОПЕРАЦИИ' in line:
                start_idx = i + 1
                break

    end_idx = len(lines)
    for i in range(start_idx, len(lines)):
        if 'Дата исходящего остатка' in lines[i] or 'Исходящий остаток' in lines[i]:
            end_idx = i
            break

    tx_start = re.compile(
        r'^(\d{2}\.\d{2}\.\d{4})\s+(\d{2}\.\d{2}\.\d{4})\s+'
        r'(-?[\d\s]+,\d{2})\s+'
        r'(-?[\d\s]+,\d{2})\s*(.*)'
    )
    total_re = re.compile(r'^-?[\d\s]+,\d{2}\s+[\d\s]+,\d{2}\s*$')

    i = start_idx
    while i < end_idx:
        line = lines[i].strip()
        if not line or total_re.match(line):
            i += 1
            continue

        m = tx_start.match(line)
        if m:
            date_str = m.group(1)
            expense_str = m.group(3).strip()
            income_str = m.group(4).strip()
            rest = m.group(5).strip()

            desc_parts = []
            if rest:
                desc_parts.append(rest)

            j = i + 1
            while j < end_idx:
                cl = lines[j].strip()
                if cl.startswith('Российский') or cl == 'Российский':
                    j += 1
                    while j < end_idx:
                        skip = lines[j].strip()
                        if tx_start.match(skip) or total_re.match(skip) or not skip:
                            break
                        j += 1
                    break
                if tx_start.match(cl) or total_re.match(cl):
                    break
                if cl:
                    desc_parts.append(cl)
                j += 1
            i = j

            description = ' '.join(desc_parts)
            description = re.sub(r'\s+', ' ', description).strip()

            expense = parse_amount_ru(expense_str)
            income = parse_amount_ru(income_str)

            if expense != 0 and income == 0:
                amount = abs(expense)
                signed_amount = -amount
            elif income != 0 and expense == 0:
                amount = abs(income)
                signed_amount = amount
            elif expense != 0 and income != 0:
                amount = max(abs(expense), abs(income))
                signed_amount = income - abs(expense)
            else:
                i += 1
                continue

            if amount == 0:
                i += 1
                continue

            transactions.append({
                'date': date_str,
                'processing_date': None,
                'amount': amount,
                'signed_amount': signed_amount,
                'description': description,
                'card_number': None,
            })
        else:
            i += 1

    return transactions


# ─── ПАРСЕР: ГАЗПРОМБАНК ───────────────────────────────────────

def parse_gazprom(text: str) -> list[dict]:
    """
    Газпромбанк: выписка по карте.
    Строка транзакции: DD.MM.YYYY  DD.MM.YYYY  описание  +приход  -расход
    Описание может переноситься на несколько строк (глубокий отступ).
    """
    lines = text.split('\n')
    transactions = []

    tx_re = re.compile(
        r'^\s*(\d{2}\.\d{2}\.\d{4})\s+(\d{2}\.\d{2}\.\d{4})\s+'
        r'(.+?)\s*'
        r'([+-]\d[\d ]*,\d{2})\s+'
        r'([+-]\d[\d ]*,\d{2})\s*$'
    )
    cont_re = re.compile(r'^\s{20,}(\S.*\S|\S)\s*$')
    skip_re = re.compile(
        r'ВЫПИСКА ПО КАРТЕ|Держатель|Дата\s+Дата|Поступления|Расходы|'
        r'За период|совершения|операции|списания|зачисления|Содержание|'
        r'Приход|Расход|Страница'
    )

    i = 0
    while i < len(lines):
        line = lines[i]
        m = tx_re.match(line)
        if not m:
            i += 1
            continue

        ref_date = m.group(2)
        desc_start = m.group(3).strip()
        income = parse_amount_ru(m.group(4))
        expense = parse_amount_ru(m.group(5))

        desc_parts = [desc_start] if desc_start else []

        j = i + 1
        while j < len(lines):
            cl = lines[j]
            stripped = cl.strip()

            if tx_re.match(cl):
                break

            if not stripped:
                j += 1
                continue

            leading = len(cl) - len(cl.lstrip())
            if leading >= 20:
                if not re.match(r'^\d+$', stripped) and not skip_re.search(stripped):
                    desc_parts.append(stripped)
                j += 1
            else:
                break

        i = j

        if income > 0:
            amount, signed_amount = income, income
        elif expense < 0:
            amount, signed_amount = abs(expense), expense
        else:
            continue

        description = re.sub(r'\s+', ' ', ' '.join(desc_parts)).strip()
        transactions.append({
            'date': ref_date,
            'processing_date': None,
            'amount': amount,
            'signed_amount': signed_amount,
            'description': description,
            'card_number': None,
        })

    return transactions


# ─── ПАРСЕР: ОЗОН БАНК ─────────────────────────────────────────

def parse_ozon(text: str) -> list[dict]:
    """
    Парсит выписку Озон Банка. Двухпроходный парсер.
    Формат: дата на отдельной строке, затем строка с doc_number + описание + суммы.
    Описание может начинаться ДО даты (prefix) и продолжаться ПОСЛЕ строки данных (suffix).
    """
    lines = text.split('\n')

    start_idx = end_idx = 0
    for i, line in enumerate(lines):
        if start_idx == 0 and 'Российские рубли' in line and 'Валюта' in line:
            start_idx = i + 1
    for i, line in enumerate(lines):
        if re.search(r'Итого\s+(зачислений|списаний)', line) and i > start_idx:
            end_idx = i
            break
    if end_idx == 0:
        end_idx = len(lines)

    work_lines = lines[start_idx:end_idx]

    dt_data_re = re.compile(
        r'^\s*(\d{2}\.\d{2}\.\d{4})\s+\d{2}:\d{2}:\d{2}\s+'
        r'(\d{3,})\s+(.+?)\s{2,}([+\-])\s*([\d\s]+\.\d{2})\s*₽\s+([+\-])\s*([\d\s]+\.\d{2})\s*₽'
    )
    plain_data_re = re.compile(
        r'^\s+(\d{3,})\s+(.+?)\s{2,}([+\-])\s*([\d\s]+\.\d{2})\s*₽\s+([+\-])\s*([\d\s]+\.\d{2})\s*₽'
    )
    date_only_re = re.compile(r'^\s*(\d{2}\.\d{2}\.\d{4})\s*$')
    date_text_re = re.compile(r'^\s*(\d{2}\.\d{2}\.\d{4})\s{2,}(.+\S)')
    date_time_re = re.compile(r'^\s*(\d{2}\.\d{2}\.\d{4})\s+(\d{2}:\d{2}:\d{2})')
    time_re = re.compile(r'^\s*(\d{2}:\d{2}:\d{2})\s*(.*?)\s*$')

    line_info = []
    for i, line in enumerate(work_lines):
        stripped = line.strip()
        if stripped == '':
            line_info.append(('blank', None, i))
            continue

        m_dt = dt_data_re.match(line)
        if m_dt:
            sign = m_dt.group(4)
            amount_val = float(m_dt.group(5).replace(' ', ''))
            if sign == '-':
                amount_val = -amount_val
            line_info.append(('data', {
                'date': m_dt.group(1),
                'desc': m_dt.group(3).strip(),
                'amount': amount_val,
            }, i))
            continue

        m_pl = plain_data_re.match(line)
        if m_pl:
            sign = m_pl.group(3)
            amount_val = float(m_pl.group(4).replace(' ', ''))
            if sign == '-':
                amount_val = -amount_val
            line_info.append(('data', {
                'date': None,
                'desc': m_pl.group(2).strip(),
                'amount': amount_val,
            }, i))
            continue

        if date_only_re.match(line):
            line_info.append(('date', date_only_re.match(line).group(1), i))
        elif date_time_re.match(line):
            line_info.append(('date', date_time_re.match(line).group(1), i))
        elif date_text_re.match(line):
            m_dt = date_text_re.match(line)
            line_info.append(('date', m_dt.group(1), i))
            line_info.append(('text', m_dt.group(2).strip(), i))
            continue
        elif time_re.match(line):
            m_t = time_re.match(line)
            extra = m_t.group(2).strip()
            line_info.append(('time', extra if extra else None, i))
        elif stripped and not re.match(r'^\d{1,2}$', stripped):
            if re.match(
                r'^(Сумма операции|Дата операции|Российские рубли|'
                r'Назначение платежа|Документ|\d{1,2}\s*$)', stripped
            ):
                line_info.append(('other', None, i))
            else:
                line_info.append(('text', stripped, i))
        else:
            line_info.append(('other', None, i))

    transactions = []
    data_indices = [i for i, (t, _, _) in enumerate(line_info) if t == 'data']

    for pos, di in enumerate(data_indices):
        data = line_info[di][1]

        date = data['date']
        if not date:
            for j in range(di - 1, -1, -1):
                if line_info[j][0] == 'date':
                    date = line_info[j][1]
                    break
                if line_info[j][0] == 'data':
                    break

        prev_end = 0
        if pos > 0:
            prev_di = data_indices[pos - 1]
            j = prev_di + 1
            while j < len(line_info) and line_info[j][0] in ('time', 'text', 'blank'):
                j += 1
            prev_end = j

        date_pos = di
        for j in range(di - 1, -1, -1):
            if line_info[j][0] == 'date':
                date_pos = j
                break
            if line_info[j][0] == 'data':
                break

        prefix_parts = []
        for j in range(prev_end, di):
            if line_info[j][0] == 'text':
                prefix_parts.append(line_info[j][1])

        desc_parts = prefix_parts + [data['desc']]

        j = di + 1
        while j < len(line_info) and line_info[j][0] == 'time':
            if line_info[j][1]:
                desc_parts.append(line_info[j][1])
            j += 1
        while j < len(line_info) and line_info[j][0] in ('text', 'blank'):
            if line_info[j][0] == 'text':
                desc_parts.append(line_info[j][1])
            j += 1

        transactions.append({
            'date': date,
            'processing_date': None,
            'amount': abs(data['amount']),
            'signed_amount': data['amount'],
            'description': ' '.join(desc_parts),
            'card_number': None,
        })

    return transactions


# ─── ИЗВЛЕЧЕНИЕ МЕТАДАННЫХ ──────────────────────────────────────

def extract_account_number(text: str, bank: str) -> str:
    """Извлекает номер лицевого счёта/карты из текста выписки."""
    patterns = {
        'alfa':    r'Номер счета\s+(\d{20})',
        'ozon':    r'Номер лицевого счёта[:\s№]+(\d{20})',
        'rsh':     r'СЧЕТУ\s+(\d{20})',
        'tbank':   r'Номер лицевого счета:\s+(\d{20})',
        'sber':    r'Номер счёта\s+([\d\s]{20,30})',
        'gazprom': r'Номер счета карты\s+(\d{20})',
    }
    pattern = patterns.get(bank)
    if not pattern:
        return ''
    m = re.search(pattern, text, re.IGNORECASE)
    if not m:
        return ''
    return re.sub(r'\s+', '', m.group(1))[:20]


def extract_cardholder(text: str, bank: str) -> str:
    """
    Извлекает ФИО держателя карты из шапки справки. На выборке CloudSix
    встретился только формат Т-Банка ("Справка о движении средств" /
    "Исх. № ..." / пустая строка / ФИО / "Адрес места жительства: ...") —
    для остальных банков реализуем по мере появления образцов.
    """
    if bank == 'tbank':
        lines = text.split('\n')
        for i, line in enumerate(lines):
            if 'Исх. №' in line:
                for j in range(i + 1, len(lines)):
                    candidate = lines[j].strip()
                    if candidate:
                        return candidate
                break
    return ''


def extract_period(text: str) -> str:
    """Извлекает период выписки из текста."""
    m = re.search(
        r'(?:За период|за период|Период выписки)[:\s]*'
        r'(?:с\s+)?(\d{2}\.\d{2}\.\d{4})\s*[—–\-]\s*(\d{2}\.\d{2}\.\d{4})',
        text
    )
    if m:
        return f"{m.group(1)} - {m.group(2)}"
    return ''


BANK_NAMES = {
    'sber':    'Сбер',
    'alfa':    'Альфа',
    'tbank':   'Т-Банк',
    'rsh':     'РСХ',
    'ozon':    'Озон',
    'gazprom': 'Газпром',
    'unknown': 'Неизвестный',
}

PARSERS = {
    'sber':    parse_sber,
    'alfa':    parse_alfa,
    'tbank':   parse_tbank,
    'rsh':     parse_rsh,
    'ozon':    parse_ozon,
    'gazprom': parse_gazprom,
}


def parse_pdf(pdf_path: Path) -> list[dict]:
    """Разбирает одну PDF-справку и возвращает список строк-транзакций."""
    text = extract_text(str(pdf_path))
    bank = detect_bank(text)

    if bank == 'unknown':
        return []

    parser = PARSERS[bank]
    if bank == 'rsh':
        transactions = parser(text, pdf_path=str(pdf_path))
    else:
        transactions = parser(text)

    account_number = extract_account_number(text, bank)
    cardholder = extract_cardholder(text, bank)

    rows = []
    for row_num, txn in enumerate(transactions, start=1):
        rows.append({
            "cardholder": cardholder,
            "source_bank": BANK_NAMES[bank],
            "account_number": account_number,
            "card_number": txn["card_number"],
            "operation_date": txn["date"],
            "processing_date": txn["processing_date"],
            "amount": txn["amount"],
            "signed_amount": txn["signed_amount"],
            "description": txn["description"],
            "row_num": row_num,
            "source_file": pdf_path.name,
        })
    return rows


def parse_dir(input_dir: Path) -> list[dict]:
    rows = []
    for path in sorted(input_dir.glob("*.pdf")):
        rows.extend(parse_pdf(path))
    return rows


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: card_statement_pdf.py <input_dir>", file=sys.stderr)
        sys.exit(1)

    all_rows = parse_dir(Path(sys.argv[1]))
    cardholders = sorted({r["cardholder"] for r in all_rows if r["cardholder"]})
    print(f"Файлов: {len(list(Path(sys.argv[1]).glob('*.pdf')))}")
    print(f"Строк (транзакций): {len(all_rows)}")
    print(f"Держатели карт: {cardholders}")
