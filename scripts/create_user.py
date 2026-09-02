#!/usr/bin/env python3
"""
Создаёт пользователя веб-формы (users) и, опционально, сразу выдаёт ему
доступ к проекту (user_projects). Единственный способ завести пользователя —
самостоятельной регистрации в форме нет.

Пример:
    python3 scripts/create_user.py --email ilya@finance-black.ru --first-name Илья --last-name Гимаратов --project cloudsix
    python3 scripts/create_user.py --email new@finance-black.ru --first-name Имя --last-name Фамилия

Обновить имя/фамилию существующему пользователю (пароль не трогает):
    python3 scripts/create_user.py --email ilya@finance-black.ru --first-name Илья --last-name Гимаратов --update
"""

import argparse
import getpass
import logging
import sys
from pathlib import Path

from dotenv import load_dotenv
from werkzeug.security import generate_password_hash

SCRIPT_DIR = Path(__file__).parent
ROOT_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(ROOT_DIR))

from wb_core import get_client  # noqa: E402

load_dotenv(ROOT_DIR / ".env")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("create_user")


def next_id(client, table: str) -> int:
    row = client.query(f"SELECT max(id) FROM {table}").result_rows
    current_max = row[0][0]
    return (current_max or 0) + 1


def find_user(client, email: str) -> tuple[int, str] | None:
    """Возвращает (id, password_hash) существующего пользователя или None."""
    rows = client.query(
        "SELECT id, password_hash FROM users FINAL WHERE email = {email:String}",
        parameters={"email": email},
    ).result_rows
    return (rows[0][0], rows[0][1]) if rows else None


def create_user(client, email: str, password: str, first_name: str, last_name: str) -> int:
    if find_user(client, email) is not None:
        raise ValueError(f"Пользователь с email {email} уже существует")

    user_id = next_id(client, "users")
    client.insert(
        "users",
        [[user_id, email, generate_password_hash(password), first_name, last_name]],
        column_names=["id", "email", "password_hash", "first_name", "last_name"],
    )
    return user_id


def update_user_name(client, email: str, first_name: str, last_name: str) -> int:
    """Перезаписывает first_name/last_name существующему пользователю (пароль не трогает)."""
    existing = find_user(client, email)
    if existing is None:
        raise ValueError(f"Пользователь с email {email} не найден")
    user_id, password_hash = existing
    client.insert(
        "users",
        [[user_id, email, password_hash, first_name, last_name]],
        column_names=["id", "email", "password_hash", "first_name", "last_name"],
    )
    return user_id


def grant_project_access(client, user_id: int, project_slug: str) -> None:
    rows = client.query(
        "SELECT id FROM projects FINAL WHERE slug = {slug:String}",
        parameters={"slug": project_slug},
    ).result_rows
    if not rows:
        raise ValueError(f"Проект со slug={project_slug} не найден")
    project_id = rows[0][0]
    client.insert(
        "user_projects",
        [[user_id, project_id]],
        column_names=["user_id", "project_id"],
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email", required=True)
    parser.add_argument("--first-name", required=True)
    parser.add_argument("--last-name", required=True)
    parser.add_argument("--project", help="slug проекта, к которому сразу дать доступ (опционально)")
    parser.add_argument("--update", action="store_true", help="обновить имя/фамилию, не создавая нового пользователя")
    args = parser.parse_args()

    try:
        client = get_client()
    except Exception:
        log.exception("Не удалось подключиться к ClickHouse")
        sys.exit(1)

    try:
        if args.update:
            user_id = update_user_name(client, args.email, args.first_name, args.last_name)
            log.info("Обновлено имя пользователя id=%s email=%s", user_id, args.email)
        else:
            password = getpass.getpass("Пароль для нового пользователя: ")
            password_confirm = getpass.getpass("Повторите пароль: ")
            if password != password_confirm:
                log.error("Пароли не совпадают")
                sys.exit(1)
            if len(password) < 8:
                log.error("Пароль должен быть не короче 8 символов")
                sys.exit(1)

            user_id = create_user(client, args.email, password, args.first_name, args.last_name)
            log.info("Создан пользователь id=%s email=%s", user_id, args.email)

        if args.project:
            grant_project_access(client, user_id, args.project)
            log.info("Выдан доступ к проекту slug=%s", args.project)
    except ValueError as e:
        log.error(str(e))
        sys.exit(1)
    except Exception:
        log.exception("Ошибка при создании/обновлении пользователя")
        sys.exit(1)


if __name__ == "__main__":
    main()
