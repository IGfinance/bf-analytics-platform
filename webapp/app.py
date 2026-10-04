#!/usr/bin/env python3
"""
Веб-форма для ручной загрузки отчётов WB в ClickHouse.

Маршруты:
  GET  /                    — список доступных проектов
  GET  /p/<slug>/           — дашборд проекта (кабинеты + текущее состояние сверки)
  GET  /p/<slug>/upload     — форма загрузки отчётов
  POST /p/<slug>/upload/detail  — обработка детального отчёта WB
  POST /p/<slug>/upload/summary — обработка сводного отчёта WB + сверка
  POST /p/<slug>/upload/ozon    — отчёт Ozon «Начисления» (xlsx)
  POST /p/<slug>/upload/bank    — банковская выписка 1С (txt)
  POST /p/<slug>/upload/card    — карточная выписка (PDF)
  GET  /profile             — профиль пользователя
  GET/POST /login — вход
  POST /logout    — выход

Навигация — в шапке (Проекты / Дашборд / Загрузка / Профиль), не в
sidebar. Дашборд/Загрузка ведут на последний посещённый проект
(session["current_project_slug"], см. project_access_required).

Вход — по email/паролю сотрудника (таблица users), через Flask-Login.
Первого пользователя заводит scripts/create_user.py. Доступ к проекту —
через таблицу user_projects, её выдаёт scripts/create_user.py --project.
"""

# Аннотации вида `str | None` требуют Python 3.10+. venv проекта на 3.13, но на
# машинах разработки встречается системный 3.9 — без отложенных аннотаций модуль
# там не импортируется вообще (2026-09-27 это заблокировало прогон
# compare_wb_summaries.py). В рантайме ничего не меняет.
from __future__ import annotations

import functools
import logging
import ntpath
import os
import time
import uuid
import posixpath
import re
import sys
from pathlib import Path

from flask import Flask, abort, g, redirect, render_template, request, session, url_for
from flask_login import current_user, login_required, login_user, logout_user

WEBAPP_DIR = Path(__file__).parent
ROOT_DIR = WEBAPP_DIR.parent
SRC_DIR = ROOT_DIR / "src"
sys.path.insert(0, str(SRC_DIR))

from dotenv_safe import load_dotenv                    # noqa: E402  (src/ уже в sys.path)


def _load_env(path: Path) -> None:
    """Грузит .env, не падая, если файл недоступен этому пользователю.

    На проде сервис работает от www-data и читает ТОЛЬКО webapp/.env (ключи проектов ClickHouse,
    секрет Flask, Metabase); общий корневой .env — root-only (там пароль админа ClickHouse, ключи
    площадок, реквизиты SSH) и сервису недоступен. Первым грузится webapp/.env: python-dotenv
    не перезаписывает уже заданные переменные, поэтому его значения главнее корневого."""
    load_dotenv(path)


_load_env(WEBAPP_DIR / ".env")   # прод: всё, что нужно сервису (см. ТЗ 04, блок D)
_load_env(ROOT_DIR / ".env")     # локальная разработка: общий .env репозитория

from wb_core import ingest_files, get_client          # noqa: E402
from upload_checks.summary import ingest as ingest_summary  # noqa: E402   (проверки → запись)
from ozon_core import ingest_files as ingest_ozon      # noqa: E402
import metabase_tests                                   # noqa: E402
import doors                                            # noqa: E402
from doors import (ALL_PLATFORMS, SUPPORTED_PLATFORMS, SOURCE_META,  # noqa: E402
                   SUPPORTED_SOURCES, STANDARD, CUSTOM)
from upload_checks.core import UploadRejected, check_cabinet, has_errors  # noqa: E402
from bank_statement_1c import ingest_files as ingest_bank   # noqa: E402
from card_statement_pdf import ingest_files as ingest_card  # noqa: E402
from klientiks_core import ingest_files as ingest_klientiks  # noqa: E402
from reconcile_wb import run_reconciliation            # noqa: E402
from auth import authenticate, login_manager            # noqa: E402
from ch_control import get_control_client              # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("webapp")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 100 * 1024 * 1024  # 100 МБ на запрос

app.secret_key = os.environ["FLASK_SECRET_KEY"]
login_manager.init_app(app)


class PrefixMiddleware:
    """Подставляет внешний префикс пути (например, /cloudsix из nginx
    location) в SCRIPT_NAME, чтобы url_for генерировал абсолютные ссылки
    (/static/..., /dashboard и т.п.), рабочие из-под этого префикса.

    Нужен, потому что nginx проксирует `location /cloudsix/` на бэкенд
    БЕЗ префикса (proxy_pass с trailing slash), а Flask ничего не знает
    о внешнем пути, если явно не сказать через SCRIPT_NAME/URL_PREFIX.
    """

    def __init__(self, wsgi_app, prefix=""):
        self.wsgi_app = wsgi_app
        self.prefix = prefix.rstrip("/")

    def __call__(self, environ, start_response):
        if self.prefix:
            environ["SCRIPT_NAME"] = self.prefix
        return self.wsgi_app(environ, start_response)


URL_PREFIX = os.environ.get("URL_PREFIX", "")
if URL_PREFIX:
    app.wsgi_app = PrefixMiddleware(app.wsgi_app, prefix=URL_PREFIX)

def asset_v(filename: str) -> int:
    """Версия статики для ?v= — время изменения файла (браузер не держит старый shell.js/ui.css)."""
    try:
        return int((WEBAPP_DIR / "static" / filename).stat().st_mtime)
    except OSError:
        return 0


app.jinja_env.globals["asset_v"] = asset_v

UPLOAD_DIR = WEBAPP_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

GENERIC_UPLOAD_ERROR = ("Не удалось обработать загрузку из-за внутренней ошибки. Попробуйте ещё раз "
                        "или обратитесь к администратору.")


def upload_dest(filename: str) -> Path:
    """Путь для сохранения загруженного файла: у КАЖДОГО файла своя временная папка.
    Имя файла сохраняем (из него берётся номер отчёта), но общей папки нет — иначе два
    одновременных запроса с одинаковым именем файла (разные проекты) перезаписали бы друг друга
    и один обработал бы чужой файл."""
    folder = UPLOAD_DIR / uuid.uuid4().hex
    folder.mkdir()
    return folder / filename


def discard_upload(path: Path) -> None:
    path.unlink(missing_ok=True)
    try:
        path.parent.rmdir()
    except OSError:
        pass


def upload_failed(exc: Exception, slug: str) -> str:
    """Текст ошибки для пользователя. Сырое исключение (текст ClickHouse, пути, хосты) в интерфейс
    не отдаём — только в журнал. Исключение: ValueError с русским текстом — это наши собственные
    понятные сообщения проверки (например, «не найден номер отчёта в имени файла»)."""
    log.exception("Сбой загрузки в проекте %s", slug)
    if isinstance(exc, ValueError) and re.search("[а-яА-ЯёЁ]", str(exc)):
        return str(exc)[:300]
    return GENERIC_UPLOAD_ERROR



# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def safe_filename(filename: str) -> str:
    """Убирает путь и null-байты, сохраняет юникод (в т.ч. '№')."""
    filename = filename.replace("\x00", "")
    filename = ntpath.basename(filename)
    filename = posixpath.basename(filename)
    return filename


def get_user_projects(user_id: int) -> list[dict]:
    """Проекты, доступные пользователю (через user_projects). При ошибке — []."""
    try:
        client = get_control_client()
        rows = client.query(
            """
            SELECT p.id, p.slug, p.name
            FROM user_projects AS up
            INNER JOIN projects AS p ON p.id = up.project_id
            WHERE up.user_id = {user_id:UInt32}
            ORDER BY p.name
            """,
            parameters={"user_id": int(user_id)},
        ).result_rows
    except Exception:
        log.exception("Не удалось получить проекты пользователя id=%s", user_id)
        return []
    return [{"id": r[0], "slug": r[1], "name": r[2]} for r in rows]


def get_project_by_slug(slug: str) -> dict | None:
    try:
        client = get_control_client()
        rows = client.query(
            "SELECT id, slug, name FROM projects FINAL WHERE slug = {slug:String}",
            parameters={"slug": slug},
        ).result_rows
    except Exception:
        log.exception("Не удалось получить проект slug=%s", slug)
        return None
    if not rows:
        return None
    return {"id": rows[0][0], "slug": rows[0][1], "name": rows[0][2]}


def user_has_project_access(user_id: int, project_id: int) -> bool:
    try:
        client = get_control_client()
        count = client.query(
            "SELECT count() FROM user_projects WHERE user_id = {uid:UInt32} AND project_id = {pid:UInt32}",
            parameters={"uid": int(user_id), "pid": int(project_id)},
        ).result_rows[0][0]
    except Exception:
        log.exception(
            "Не удалось проверить доступ user_id=%s project_id=%s", user_id, project_id
        )
        return False
    return count > 0


def get_project_cabinets(project_id: int, database: str, platform: str | None = None) -> list[str]:
    """Кабинеты, зарегистрированные за проектом. При ошибке — [].

    database — БД проекта (g.project["slug"]): project_cabinets живёт
    внутри БД проекта, не в control.
    """
    query = "SELECT cabinet FROM project_cabinets FINAL WHERE project_id = {pid:UInt32}"
    parameters = {"pid": int(project_id)}
    if platform is not None:
        query += " AND platform = {platform:String}"
        parameters["platform"] = platform
    query += " ORDER BY cabinet"
    try:
        client = get_client(database=database)
        rows = client.query(query, parameters=parameters).result_rows
        return [r[0] for r in rows]
    except Exception:
        log.exception("Не удалось получить кабинеты проекта id=%s", project_id)
        return []


def get_project_cabinet_platforms(project_id: int, database: str) -> dict:
    """{кабинет: [площадки]} — для переключателя кабинетов на «Загрузке»: кабинет WB-only
    не должен включать двери Ozon. При ошибке — {}."""
    try:
        client = get_client(database=database)
        rows = client.query(
            "SELECT cabinet, groupUniqArray(platform) FROM project_cabinets FINAL "
            "WHERE project_id = {pid:UInt32} GROUP BY cabinet ORDER BY cabinet",
            parameters={"pid": int(project_id)},
        ).result_rows
        return {r[0]: sorted(r[1]) for r in rows}
    except Exception:
        log.exception("Не удалось получить кабинеты с площадками проекта id=%s", project_id)
        return {}


def get_project_platforms(project_id: int, database: str) -> list[str]:
    """Площадки, представленные среди кабинетов проекта. При ошибке — []."""
    try:
        client = get_client(database=database)
        rows = client.query(
            "SELECT DISTINCT platform FROM project_cabinets FINAL WHERE project_id = {pid:UInt32} ORDER BY platform",
            parameters={"pid": int(project_id)},
        ).result_rows
        return [r[0] for r in rows]
    except Exception:
        log.exception("Не удалось получить площадки проекта id=%s", project_id)
        return []


def get_project_sources(project_id: int, database: str) -> list[str]:
    """Источники данных, включённые у проекта (project_sources). При ошибке — [].

    Аналог get_project_platforms, но для источников без концепции кабинета
    (банк, карты, Клиентикс, Google-Таблицы). project_sources живёт внутри
    БД проекта, не в control. try/except → [], чтобы отсутствие таблицы или
    сбой не ронял страницу загрузки.
    """
    try:
        client = get_client(database=database)
        rows = client.query(
            "SELECT DISTINCT source FROM project_sources FINAL WHERE project_id = {pid:UInt32} ORDER BY source",
            parameters={"pid": int(project_id)},
        ).result_rows
        return [r[0] for r in rows]
    except Exception:
        log.exception("Не удалось получить источники проекта id=%s", project_id)
        return []


def reject_unknown_cabinet(slug: str, cabinet: str, platform: str):
    """Серверная проверка кабинета (ТЗ 04): только из списка кабинетов проекта на этой
    площадке, новые кабинеты через форму не создаются. Возвращает готовый ответ 400
    с причиной либо None, если кабинет в порядке."""
    results = check_cabinet(cabinet, get_project_cabinets(g.project["id"], g.project["slug"], platform))
    if not has_errors(results):
        return None
    return render_template(
        "detail_result.html", error=None, summary=None, logs=[], slug=slug,
        rejected=[r.as_dict() for r in results],
    ), 400


def render_rejected(slug: str, exc: UploadRejected, logs: list):
    """Файл отклонён проверками до записи: 400 и список причин, в базе ничего нет."""
    return render_template(
        "detail_result.html", error=None, summary=None, logs=logs, slug=slug,
        rejected=[r.as_dict() for r in exc.results],
    ), 400


def project_access_required(view):
    """Резолвит slug из URL в g.project и проверяет доступ через user_projects.

    404 — проекта с таким slug нет, 403 — есть, но не выдан доступ.
    Должен идти после @login_required (нужен current_user).
    """
    @functools.wraps(view)
    def wrapped(*args, slug, **kwargs):
        project = get_project_by_slug(slug)
        if project is None:
            abort(404)
        if not user_has_project_access(int(current_user.id), project["id"]):
            abort(403)
        g.project = project
        session["current_project_slug"] = slug
        return view(*args, slug=slug, **kwargs)
    return wrapped


def build_top_nav() -> list[dict]:
    """Пункты навигации в шапке.

    Дашборд/Загрузка ведут на текущий проект — g.project, если запрос уже
    внутри проекта, иначе последний посещённый (session), иначе недоступны
    (href=None рендерится как disabled — сначала нужно выбрать проект через
    переключатель или страницу «Проекты»).
    """
    project = g.get("project")
    slug = project["slug"] if project else session.get("current_project_slug")
    endpoint = request.endpoint

    items = [
        {"label": "Проекты", "icon": "folder", "href": url_for("home"), "active": endpoint == "home"},
    ]
    if slug:
        items.append({
            "label": "Дашборд", "icon": "layout-dashboard",
            "href": url_for("project_dashboard", slug=slug),
            "active": endpoint == "project_dashboard",
        })
        items.append({
            "label": "Загрузка", "icon": "upload",
            "href": url_for("upload_page", slug=slug),
            "active": endpoint in ("upload_page", "upload_detail", "upload_summary", "upload_ozon", "upload_bank", "upload_card", "upload_klientiks"),
        })
    else:
        items.append({"label": "Дашборд", "icon": "layout-dashboard", "href": None, "active": False})
        items.append({"label": "Загрузка", "icon": "upload", "href": None, "active": False})
    items.append({
        "label": "Профиль", "icon": "user",
        "href": url_for("profile"),
        "active": endpoint == "profile",
    })
    return items


@app.context_processor
def inject_shell_context():
    """Общие данные шапки для всех шаблонов после логина.

    """
    if not current_user.is_authenticated:
        return {}
    project = g.get("project")

    def project_options(endpoint: str) -> list:
        """Опции переключателя проекта: каждая ведёт на тот же раздел другого проекта."""
        return [{"value": p["slug"], "label": p["name"], "href": url_for(endpoint, slug=p["slug"])}
                for p in get_user_projects(int(current_user.id))]

    return {
        "project_options": project_options,
        "top_nav_items": build_top_nav(),
        "user_projects": get_user_projects(int(current_user.id)),
        "current_project": project,
    }


# ---------------------------------------------------------------------------
# Routes — вход/выход
# ---------------------------------------------------------------------------

@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("home"))

    if request.method == "GET":
        return render_template("login.html", error=None)

    email = request.form.get("email", "").strip()
    password = request.form.get("password", "")
    user = authenticate(email, password)
    if not user:
        log.warning("Неудачная попытка входа email=%s", email)
        return render_template("login.html", error="Неверный email или пароль"), 401

    login_user(user)
    log.info("Вход выполнен: id=%s email=%s", user.id, user.email)
    return redirect(url_for("home"))


@app.route("/logout", methods=["POST"])
@login_required
def logout():
    log.info("Выход: id=%s email=%s", current_user.id, current_user.email)
    logout_user()
    return redirect(url_for("login"))


# ---------------------------------------------------------------------------
# Routes — кабинет пользователя
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET"])
@login_required
def home():
    rows = []
    for p in get_user_projects(int(current_user.id)):
        state = doors.doors_state(get_project_platforms(p["id"], p["slug"]),
                                  get_project_sources(p["id"], p["slug"]))
        rows.append({
            "project": p,
            "standard": [d for d in state if d["kind"] == STANDARD],
            "custom": [d for d in state if d["kind"] == CUSTOM and d["active"]],
        })
    return render_template("home.html", rows=rows)


# ---------------------------------------------------------------------------
# Routes — дашборд проекта
# ---------------------------------------------------------------------------

@app.route("/p/<slug>/", methods=["GET"])
@login_required
@project_access_required
def project_dashboard(slug):
    """Результаты «Тестов» из Metabase (ТЗ 04, блок B). ?refresh=1 — обойти кэш."""
    report = metabase_tests.get_project_report(g.project, refresh=request.args.get("refresh") == "1")
    age_minutes = max(0, int((time.time() - report.fetched_at) // 60)) if report.fetched_at else 0
    return render_template("dashboard.html", report=report, counts=report.counts(), age_minutes=age_minutes)


# ---------------------------------------------------------------------------
# Routes — загрузка отчётов
# ---------------------------------------------------------------------------

# Каталог дверей (площадки, источники, категории) — webapp/doors.py.


def build_platform_cards() -> list[dict]:
    """Заглушки площадок без адаптера — всегда полный список ALL_PLATFORMS
    минус SUPPORTED_PLATFORMS, одинаковый для всех проектов (см. ALL_PLATFORMS)."""
    return [
        {"key": key, "label": label}
        for key, label in ALL_PLATFORMS.items()
        if key not in SUPPORTED_PLATFORMS
    ]


def build_source_cards(project_id: int, slug: str) -> list[dict]:
    """Карточки источников для страницы загрузки — ВСЕГДА по полному каталогу
    SOURCE_META (плюс код источника из project_sources, если он самому
    SOURCE_META ещё неизвестен — на случай, что данные уже включили,
    а код под них подвести не успели), а не только по включённым в
    project_sources: у клиента без какого-то источника карточка всё равно
    рендерится, только неактивной (серой) — единообразная страница у всех
    проектов.

    enabled — источник включён у ЭТОГО проекта (project_sources).
    supported — у источника есть код-адаптер (SUPPORTED_SOURCES).
    action не None (⇒ активная форма) только когда оба условия верны.
    """
    enabled_sources = set(get_project_sources(project_id, slug))
    keys = list(SOURCE_META.keys()) + [k for k in enabled_sources if k not in SOURCE_META]

    cards = []
    for key in keys:
        meta = SOURCE_META.get(key, {})
        is_enabled = key in enabled_sources
        is_supported = key in SUPPORTED_SOURCES
        cards.append({
            "key": key,
            "label": meta.get("label", key),
            "description": meta.get("description", ""),
            "accept": meta.get("accept"),
            "pull": meta.get("pull", False),
            "enabled": is_enabled,
            "supported": is_supported,
            "action": url_for(meta["endpoint"], slug=slug) if (is_enabled and is_supported) else None,
        })
    return cards


PLATFORM_SHORT = {"wb": "WB", "ozon": "Ozon"}


def build_doors(project_id: int, slug: str, platforms: list) -> dict:
    """Двери страницы «Загрузка» по категориям: {"standard": [...], "custom": [...]}.

    Каждая дверь — dict параметров для partials/upload_card.html. Стандартные двери
    видны всегда (недоступные — серой карточкой с причиной); индивидуальные — только
    включённые у проекта (у чужого клиента чужие двери не нужны)."""
    standard, custom = [], []
    for d in doors.PLATFORM_DOORS:
        standard.append({
            "key": d["key"], "title": d["label"], "description": d["description"],
            "action": url_for(d["endpoint"], slug=slug), "input_id": d["input_id"],
            "input_name": d["input_name"], "multiple": d["multiple"], "accept": ".xlsx",
            "needs_cabinet": True, "platform": d["platform"],
            "disabled": d["platform"] not in platforms,
            "disabled_reason": f"У проекта нет кабинетов {PLATFORM_SHORT.get(d['platform'], d['platform'])}.",
        })
    for p in build_platform_cards():           # площадки без адаптера — серые заглушки
        standard.append({
            "key": p["key"], "title": p["label"], "description": "", "action": None,
            "needs_cabinet": False, "platform": None, "disabled": True,
            "disabled_reason": "Площадка пока не поддерживается — адаптер загрузки ещё не реализован.",
        })
    for c in build_source_cards(project_id, slug):
        kind = doors.source_kind(c["key"])
        if kind == CUSTOM and not c["enabled"]:
            continue
        door = {
            "key": c["key"], "title": c["label"], "description": c["description"], "action": c["action"],
            "input_id": "files-" + c["key"], "input_name": "files", "multiple": True,
            "accept": c["accept"] or ".xlsx", "needs_cabinet": False, "platform": None,
            "pull": c["pull"], "disabled": not c["action"],
            "disabled_reason": ("Источник недоступен для этого проекта." if not c["enabled"]
                                else "Источник пока не поддерживается — адаптер загрузки ещё не реализован."),
        }
        (standard if kind == STANDARD else custom).append(door)
    return {"standard": standard, "custom": custom}


def upload_form_context(project_id: int, slug: str, error: str | None = None) -> dict:
    platforms = get_project_platforms(project_id, slug)
    cabinet_platforms = get_project_cabinet_platforms(project_id, slug)
    d = build_doors(project_id, slug, platforms)
    return {
        "error": error,
        "slug": slug,
        # Кабинеты для переключателя: имя + площадки (бейдж и включение/выключение дверей).
        "cabinet_options": [
            {"value": name, "label": name, "badge": " · ".join(PLATFORM_SHORT.get(x, x) for x in plats),
             "meta": ",".join(plats)}
            for name, plats in cabinet_platforms.items()
        ],
        "doors_standard": d["standard"],
        "doors_custom": d["custom"],
    }


@app.route("/p/<slug>/upload", methods=["GET"])
@login_required
@project_access_required
def upload_page(slug):
    return render_template("upload_form.html", **upload_form_context(g.project["id"], slug))


@app.route("/p/<slug>/upload/detail", methods=["POST"])
@login_required
@project_access_required
def upload_detail(slug):
    cabinet = request.form.get("cabinet", "").strip()
    files = request.files.getlist("files")

    if not cabinet:
        return render_template(
            "upload_form.html", **upload_form_context(g.project["id"], slug, "Укажите кабинет"),
        ), 400
    rejected = reject_unknown_cabinet(slug, cabinet, "wb")
    if rejected:
        return rejected
    if not files or all(f.filename == "" for f in files):
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Выберите хотя бы один файл"),
        ), 400

    saved_paths, skipped = [], []
    for f in files:
        filename = safe_filename(f.filename)
        if not filename.lower().endswith(".xlsx"):
            skipped.append(f.filename)
            continue
        dest = upload_dest(filename)
        f.save(dest)
        saved_paths.append(dest)

    if not saved_paths:
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Ни одного .xlsx файла не найдено"),
        ), 400

    logs = []
    if skipped:
        logs.append(f"Пропущены не-xlsx файлы: {', '.join(skipped)}")

    try:
        summary = ingest_files(saved_paths, cabinet, log=logs.append, database=g.project["slug"],
                               user_id=current_user.id, project=g.project["slug"])
    except UploadRejected as e:
        return render_rejected(slug, e, logs)
    except Exception as e:
        return render_template(
            "detail_result.html", error=upload_failed(e, slug), summary=None, logs=logs, slug=slug,
        ), 500
    finally:
        for p in saved_paths:
            discard_upload(p)

    return render_template(
        "detail_result.html", error=None, summary=summary, logs=logs, slug=slug,
    )


@app.route("/p/<slug>/upload/summary", methods=["POST"])
@login_required
@project_access_required
def upload_summary(slug):
    cabinet = request.form.get("cabinet", "").strip()
    f = request.files.get("file")

    if not cabinet:
        return render_template(
            "upload_form.html", **upload_form_context(g.project["id"], slug, "Укажите кабинет"),
        ), 400
    rejected = reject_unknown_cabinet(slug, cabinet, "wb")
    if rejected:
        return rejected
    if not f or f.filename == "":
        return render_template(
            "upload_form.html", **upload_form_context(g.project["id"], slug, "Выберите файл"),
        ), 400

    filename = safe_filename(f.filename)
    if not filename.lower().endswith(".xlsx"):
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Файл должен быть .xlsx"),
        ), 400

    dest = upload_dest(filename)
    f.save(dest)

    logs = []
    try:
        ingest_result = ingest_summary([dest], cabinet, log=logs.append, database=g.project["slug"],
                                       user_id=current_user.id, project=g.project["slug"])
        client = get_client(database=g.project["slug"])
        reconcile_rows = run_reconciliation(client, cabinet, log=logs.append)
    except UploadRejected as e:
        return render_rejected(slug, e, logs)
    except Exception as e:
        return render_template(
            "summary_result.html", error=upload_failed(e, slug), ingest_rows=0, total=0, failed=0,
            failures=[], logs=logs, slug=slug,
        ), 500
    finally:
        discard_upload(dest)

    # Преобразуем tuple-результат в dict для шаблона
    FIELDS = [
        "cabinet", "report_number", "report_type", "period_start", "period_end",
        "field_name", "expected_value", "actual_value", "diff", "tolerance", "is_ok",
    ]
    rows_as_dicts = [dict(zip(FIELDS, r)) for r in reconcile_rows]
    failures = [r for r in rows_as_dicts if not r["is_ok"]]

    return render_template(
        "summary_result.html",
        error=None,
        notes=[r for o in ingest_result.get("outcomes", []) for r in o["results"]],
        ingest_rows=ingest_result["rows"],
        total=len(rows_as_dicts),
        failed=len(failures),
        failures=failures,
        logs=logs,
        slug=slug,
    )


@app.route("/p/<slug>/upload/ozon", methods=["POST"])
@login_required
@project_access_required
def upload_ozon(slug):
    cabinet = request.form.get("cabinet", "").strip()
    files = request.files.getlist("files")

    if not cabinet:
        return render_template(
            "upload_form.html", **upload_form_context(g.project["id"], slug, "Укажите кабинет"),
        ), 400
    rejected = reject_unknown_cabinet(slug, cabinet, "ozon")
    if rejected:
        return rejected
    if not files or all(f.filename == "" for f in files):
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Выберите хотя бы один файл"),
        ), 400

    saved_paths, skipped = [], []
    for f in files:
        filename = safe_filename(f.filename)
        if not filename.lower().endswith(".xlsx"):
            skipped.append(f.filename)
            continue
        dest = upload_dest(filename)
        f.save(dest)
        saved_paths.append(dest)

    if not saved_paths:
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Ни одного .xlsx файла не найдено"),
        ), 400

    logs = []
    if skipped:
        logs.append(f"Пропущены не-xlsx файлы: {', '.join(skipped)}")

    try:
        summary = ingest_ozon(saved_paths, cabinet, log=logs.append, database=g.project["slug"],
                              user_id=current_user.id, project=g.project["slug"])
    except UploadRejected as e:
        return render_rejected(slug, e, logs)
    except Exception as e:
        return render_template(
            "detail_result.html", error=upload_failed(e, slug), summary=None, logs=logs, slug=slug,
        ), 500
    finally:
        for p in saved_paths:
            discard_upload(p)

    return render_template(
        "detail_result.html", error=None, summary=summary, logs=logs, slug=slug,
    )


def handle_source_upload(slug: str, ext: str, ingest_fn, source_label: str):
    """Общая обработка загрузки источника без кабинета (банк/карты).

    ext — допустимое расширение (.txt/.pdf); ingest_fn — ingest_files
    соответствующего модуля (принимает files, project_id, log, database).
    Ошибки не роняют форму: битый файл/сбой ClickHouse → source_result с 500,
    отсутствие файлов → форма загрузки с 400.
    """
    files = request.files.getlist("files")
    if not files or all(f.filename == "" for f in files):
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, "Выберите хотя бы один файл"),
        ), 400

    saved_paths, skipped = [], []
    for f in files:
        filename = safe_filename(f.filename)
        if not filename.lower().endswith(ext):
            skipped.append(f.filename)
            continue
        dest = upload_dest(filename)
        f.save(dest)
        saved_paths.append(dest)

    if not saved_paths:
        return render_template(
            "upload_form.html",
            **upload_form_context(g.project["id"], slug, f"Ни одного {ext} файла не найдено"),
        ), 400

    logs = []
    if skipped:
        logs.append(f"Пропущены файлы не-{ext}: {', '.join(skipped)}")

    try:
        summary = ingest_fn(
            saved_paths, project_id=g.project["id"], log=logs.append, database=g.project["slug"],
        )
    except Exception as e:
        return render_template(
            "source_result.html", error=upload_failed(e, slug), summary=None, logs=logs,
            slug=slug, source_label=source_label,
        ), 500
    finally:
        for p in saved_paths:
            discard_upload(p)

    return render_template(
        "source_result.html", error=None, summary=summary, logs=logs,
        slug=slug, source_label=source_label,
    )


@app.route("/p/<slug>/upload/bank", methods=["POST"])
@login_required
@project_access_required
def upload_bank(slug):
    return handle_source_upload(slug, ".txt", ingest_bank, "Банковская выписка 1С")


@app.route("/p/<slug>/upload/card", methods=["POST"])
@login_required
@project_access_required
def upload_card(slug):
    return handle_source_upload(slug, ".pdf", ingest_card, "Карточная выписка PDF")


@app.route("/p/<slug>/upload/klientiks", methods=["POST"])
@login_required
@project_access_required
def upload_klientiks(slug):
    return handle_source_upload(slug, ".csv", ingest_klientiks, "Выгрузка Клиентикс")


# ---------------------------------------------------------------------------
# Routes — профиль пользователя
# ---------------------------------------------------------------------------

@app.route("/profile", methods=["GET"])
@login_required
def profile():
    return render_template("profile.html")


if __name__ == "__main__":
    port = int(os.environ.get("WEBAPP_PORT", "5001"))
    app.run(host="127.0.0.1", port=port, debug=False)
