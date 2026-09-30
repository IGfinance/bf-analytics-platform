#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Общая логика доступа к 1С OData «Алабуга Боттлинг» — используется и
разовой выгрузкой в xlsx (scripts/export_odata_bottling.py), и боевым
инжестом в ClickHouse (ingest_bottling_realization.py). Формула/парсинг
$metadata не дублируются — правьте здесь.

Вход — логин `USER` из .env, ПУСТОЙ пароль (не PASSWORD из .env, та
запись 1С отклоняет — см. вики knowledge/integrations/«1С OData —
подключение работает, но объекты не выгружены», обновление 2026-09-29).
"""

import base64
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENV = dict(re.findall(r'^([A-Z_]+)=(.*)$', (REPO / '.env').read_text(encoding='utf-8'), re.M))
AUTH = 'Basic ' + base64.b64encode(f"{ENV['USER'].strip()}:".encode()).decode()
BASE = 'http://46.21.71.110:3400/BP3/odata/standard.odata/'
METADATA_PATH = REPO.parent / '.odata_metadata_cache.xml'  # вне репо, крупный файл (7.6 МБ)

EMPTY_GUID = '00000000-0000-0000-0000-000000000000'


def http_get(url: str) -> tuple[int | None, bytes]:
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={'Authorization': AUTH})
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:  # noqa: BLE001
            print(f'  retry after {e}', file=sys.stderr)
            time.sleep(5)
    return None, b''


def odata_get_json(path: str) -> dict:
    url = BASE + urllib.parse.quote(path, safe="/?$=&(),':")
    status, body = http_get(url)
    if status != 200:
        raise RuntimeError(f'{path} -> HTTP {status}: {body[:300]!r}')
    return json.loads(body)


def fetch_all(entity: str, select: str | None = None, page: int = 5000) -> list[dict]:
    rows: list[dict] = []
    skip = 0
    while True:
        q = f"{entity}?$format=json&$top={page}&$skip={skip}"
        if select:
            q += f"&$select={select}"
        d = odata_get_json(q)
        batch = d['value']
        rows.extend(batch)
        skip += len(batch)
        if len(batch) < page:
            break
    return rows


def load_metadata() -> str:
    if METADATA_PATH.exists():
        return METADATA_PATH.read_text(encoding='utf-8')
    status, body = http_get(BASE + '$metadata')
    if status != 200:
        raise RuntimeError(f'$metadata -> HTTP {status}')
    text = body.decode('utf-8')
    METADATA_PATH.write_text(text, encoding='utf-8')
    return text


def entity_fields(xml: str, entity: str) -> tuple[list[str], list[str]]:
    """Возвращает (скалярные поля, табличные части) объекта по $metadata.

    Табличные части возвращаются как ИМЕНА ЗАПРОСА (не имена свойств):
    у документов свойство "Товары" запрашивается как отдельный EntitySet
    "Document_X_Товары" — имя совпадает. А у регистров с признаком
    "подчинён регистратору" (Recorder-based) реальные строки лежат в
    свойстве "RecordSet", но как отдельный EntitySet оно доступно ТОЛЬКО
    под именем "..._RecordType" (гочтя 1С OData, проверено на
    InformationRegister_РасчетКалькуляцииСебестоимости и
    AccumulationRegister_ВыпускПродукцииУслуг 2026-09-29) — суффикс
    подменяется на этом шаге.
    """
    m = re.search(r'<EntityType\s+Name="' + re.escape(entity) + r'"[^>]*>(.*?)</EntityType>', xml, re.S)
    if not m:
        raise RuntimeError(f'{entity} не найден в $metadata')
    block = m.group(1)
    props = re.findall(r'<Property\s+Name="([^"]+)"\s+Type="([^"]+)"', block, re.S)
    scalar = [name for name, typ in props if not typ.startswith('Collection(')]
    tabular = [('RecordType' if name == 'RecordSet' else name)
               for name, typ in props if typ.startswith('Collection(')]
    return scalar, tabular


def key_field(xml: str, entity: str) -> str:
    m = re.search(r'<EntityType\s+Name="' + re.escape(entity) + r'"[^>]*>(.*?)</EntityType>', xml, re.S)
    km = re.search(r'<Key>\s*<PropertyRef\s+Name="([^"]+)"', m.group(1), re.S)
    return km.group(1) if km else 'Ref_Key'


def chunk_select_fields(fields: list[str], key: str, max_encoded: int = 1500) -> list[list[str]]:
    """Режет список полей на пачки так, чтобы кодированный $select не
    упирался в лимит IIS на длину query string (эмпирически найден
    2026-09-29 на этой базе: ~20 кириллических полей уже ломает запрос
    404.15, безопасный порог около 1500 закодированных символов).
    Каждая пачка включает `key`, чтобы результаты можно было склеить.
    """
    rest = [f for f in fields if f != key]
    chunks: list[list[str]] = []
    current: list[str] = [key]
    for f in rest:
        trial = current + [f]
        encoded_len = len(urllib.parse.quote(','.join(trial), safe="/?$=&(),':"))
        if encoded_len > max_encoded and len(current) > 1:
            chunks.append(current)
            current = [key, f]
        else:
            current.append(f)
    chunks.append(current)
    return chunks


def fetch_all_wide(entity: str, fields: list[str], key: str, page: int = 5000) -> list[dict]:
    """Как fetch_all, но для широких объектов: тянет поля отдельными
    пачками (см. chunk_select_fields) и склеивает построчно по `key`.
    """
    chunks = chunk_select_fields(fields, key)
    if len(chunks) == 1:
        return fetch_all(entity, select=','.join(chunks[0]), page=page)
    merged: dict[str, dict] = {}
    order: list[str] = []
    for i, chunk in enumerate(chunks):
        rows = fetch_all(entity, select=','.join(chunk), page=page)
        for r in rows:
            k = r.get(key)
            if k not in merged:
                merged[k] = {}
                order.append(k)
            merged[k].update(r)
        print(f'    select-пачка {i + 1}/{len(chunks)} ({len(chunk)} полей): {len(rows)} строк')
    return [merged[k] for k in order]


# Справочники для расшифровки *_Key в человекочитаемое имя. (EntitySet, поле-описание)
DICT_CATALOGS = [
    ('Catalog_Организации', 'Description'),
    ('Catalog_Контрагенты', 'Description'),
    ('Catalog_Номенклатура', 'Description'),
    ('Catalog_Склады', 'Description'),
    ('Catalog_ПодразделенияОрганизаций', 'Description'),
    ('Catalog_НоменклатурныеГруппы', 'Description'),
    ('Catalog_СтатьиЗатрат', 'Description'),
    ('Catalog_КлассификаторЕдиницИзмерения', 'Description'),
    ('Catalog_ДоговорыКонтрагентов', 'Description'),
    ('Catalog_ТипыЦенНоменклатуры', 'Description'),
    ('Catalog_Банки', 'Description'),
    ('Catalog_БанковскиеСчета', 'Description'),
    ('Catalog_Валюты', 'Description'),
    ('Catalog_Сотрудники', 'Description'),
    ('Catalog_ФизическиеЛица', 'Description'),
    ('Catalog_Пользователи', 'Description'),
    ('Catalog_СпособыДоставки', 'Description'),
    ('Catalog_ПрочиеДоходыИРасходы', 'Description'),
    ('Catalog_РасходыБудущихПериодов', 'Description'),
    ('ChartOfAccounts_Хозрасчетный', 'Code'),
]


def build_guid_dict() -> dict[str, str]:
    print('Загружаю справочники для расшифровки GUID...')
    guid_map: dict[str, str] = {}
    for entity, name_field in DICT_CATALOGS:
        try:
            rows = fetch_all(entity, select=f'Ref_Key,{name_field}')
        except Exception as e:  # noqa: BLE001
            print(f'  {entity}: пропущен ({e})', file=sys.stderr)
            continue
        for r in rows:
            key = r.get('Ref_Key')
            val = r.get(name_field)
            if key and val:
                guid_map.setdefault(key, str(val))
        print(f'  {entity}: {len(rows)}')
    return guid_map
