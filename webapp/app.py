#!/usr/bin/env python3
"""
Веб-форма для ручной загрузки отчётов WB в ClickHouse.

Маршруты:
  GET  /                    — список доступных проектов
  GET  /p/<slug>/           — дашборд проекта (кабинеты + текущее состояние сверки)
  GET  /p/<slug>/upload     — форма загрузки отчётов
  POST /p/<slug>/upload/detail  — обработка детального отчёта
  POST /p/<slug>/upload/summary — обработка сводного отчёта + сверка
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

import functools
import logging
import ntpath
import os
import posixpath
import sys
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, abort, g, redirect, render_template, request, session, url_for
from flask_login import current_user, login_required, login_user, logout_user

WEBAPP_DIR = Path(__file__).parent
ROOT_DIR = WEBAPP_DIR.parent
SRC_DIR = ROOT_DIR / "src"
sys.path.insert(0, str(SRC_DIR))

load_dotenv(ROOT_DIR / ".env")   # реквизиты ClickHouse
load_dotenv(WEBAPP_DIR / ".env")       # секреты веб-формы (может переопределить)

from wb_core import ingest_files, get_client          # noqa: E402
from wb_summary_core import ingest_files as ingest_summary  # noqa: E402
from reconcile_wb import run_reconciliation            # noqa: E402
from auth import authenticate, login_manager            # noqa: E402

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

UPLOAD_DIR = WEBAPP_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)



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
        client = get_client()
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
        client = get_client()
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
        client = get_client()
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


def get_project_cabinets(project_id: int, platform: str | None = None) -> list[str]:
    """Кабинеты, зарегистрированные за проектом. При ошибке — []."""
    query = "SELECT cabinet FROM project_cabinets FINAL WHERE project_id = {pid:UInt32}"
    parameters = {"pid": int(project_id)}
    if platform is not None:
        query += " AND platform = {platform:String}"
        parameters["platform"] = platform
    query += " ORDER BY cabinet"
    try:
        client = get_client()
        rows = client.query(query, parameters=parameters).result_rows
        return [r[0] for r in rows]
    except Exception:
        log.exception("Не удалось получить кабинеты проекта id=%s", project_id)
        return []


def get_project_platforms(project_id: int) -> list[str]:
    """Площадки, представленные среди кабинетов проекта. При ошибке — []."""
    try:
        client = get_client()
        rows = client.query(
            "SELECT DISTINCT platform FROM project_cabinets FINAL WHERE project_id = {pid:UInt32} ORDER BY platform",
            parameters={"pid": int(project_id)},
        ).result_rows
        return [r[0] for r in rows]
    except Exception:
        log.exception("Не удалось получить площадки проекта id=%s", project_id)
        return []


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
            "active": endpoint in ("upload_page", "upload_detail", "upload_summary"),
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

    unread_alerts — заглушка до миграции alerts.
    """
    if not current_user.is_authenticated:
        return {}
    project = g.get("project")
    return {
        "top_nav_items": build_top_nav(),
        "user_projects": get_user_projects(int(current_user.id)),
        "current_project": project,
        "unread_alerts": 0,
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
    return render_template("home.html", projects=get_user_projects(int(current_user.id)))


# ---------------------------------------------------------------------------
# Routes — дашборд проекта
# ---------------------------------------------------------------------------

@app.route("/p/<slug>/", methods=["GET"])
@login_required
@project_access_required
def project_dashboard(slug):
    return render_template("dashboard.html", cabinets=get_project_cabinets(g.project["id"]))


# ---------------------------------------------------------------------------
# Routes — загрузка отчётов
# ---------------------------------------------------------------------------

# Площадки, для которых уже есть ingest-адаптер и формы загрузки. Остальные
# площадки, встреченные среди кабинетов проекта (project_cabinets.platform),
# рендерятся как disabled-заглушка на /p/<slug>/upload.
SUPPORTED_PLATFORMS = {"wb"}


def upload_form_context(project_id: int, slug: str, error: str | None = None) -> dict:
    platforms = get_project_platforms(project_id)
    return {
        "error": error,
        "slug": slug,
        "cabinets": get_project_cabinets(project_id, platform="wb"),
        "has_wb": "wb" in platforms,
        "other_platforms": [p for p in platforms if p not in SUPPORTED_PLATFORMS],
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
        dest = UPLOAD_DIR / filename
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
        summary = ingest_files(saved_paths, cabinet, log=logs.append)
    except Exception as e:
        return render_template(
            "detail_result.html", error=str(e), summary=None, logs=logs, slug=slug,
        ), 500
    finally:
        for p in saved_paths:
            p.unlink(missing_ok=True)

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

    dest = UPLOAD_DIR / filename
    f.save(dest)

    logs = []
    try:
        ingest_result = ingest_summary([dest], cabinet, log=logs.append)
        client = get_client()
        reconcile_rows = run_reconciliation(client, cabinet, log=logs.append)
    except Exception as e:
        return render_template(
            "summary_result.html", error=str(e), ingest_rows=0, total=0, failed=0,
            failures=[], logs=logs, slug=slug,
        ), 500
    finally:
        dest.unlink(missing_ok=True)

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
        ingest_rows=ingest_result["rows"],
        total=len(rows_as_dicts),
        failed=len(failures),
        failures=failures,
        logs=logs,
        slug=slug,
    )


# ---------------------------------------------------------------------------
# Routes — профиль пользователя
# ---------------------------------------------------------------------------

@app.route("/profile", methods=["GET"])
@login_required
def profile():
    return render_template("profile.html", projects=get_user_projects(int(current_user.id)))


if __name__ == "__main__":
    port = int(os.environ.get("WEBAPP_PORT", "5001"))
    app.run(host="127.0.0.1", port=port, debug=False)
