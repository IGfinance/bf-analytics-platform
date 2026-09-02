"""
Flask-Login поверх таблицы users в ClickHouse — заменяет единый Basic Auth
на логин конкретного сотрудника (см. wiki: 2026-08-31 архитектура — кабинет
пользователя, проекты, мультиплощадочность).
"""

import logging

from flask_login import LoginManager, UserMixin
from werkzeug.security import check_password_hash

from wb_core import get_client

log = logging.getLogger(__name__)

login_manager = LoginManager()
login_manager.login_view = "login"
login_manager.login_message = "Войдите, чтобы продолжить"


class User(UserMixin):
    def __init__(self, user_id: int, email: str, first_name: str = "", last_name: str = ""):
        self.id = str(user_id)
        self.email = email
        self.first_name = first_name
        self.last_name = last_name

    @property
    def full_name(self) -> str:
        name = f"{self.last_name} {self.first_name}".strip()
        return name or self.email


def find_user_by_id(user_id: str) -> User | None:
    try:
        client = get_client()
        rows = client.query(
            "SELECT id, email, first_name, last_name FROM users FINAL WHERE id = {id:UInt32}",
            parameters={"id": int(user_id)},
        ).result_rows
    except Exception:
        log.exception("Не удалось получить пользователя id=%s", user_id)
        return None
    if not rows:
        return None
    return User(*rows[0])


def authenticate(email: str, password: str) -> User | None:
    """Возвращает User при верных email/пароле, иначе None (не бросает
    исключение при неверном пароле — только при сбое похода в БД)."""
    try:
        client = get_client()
        rows = client.query(
            "SELECT id, email, password_hash, first_name, last_name FROM users FINAL WHERE email = {email:String}",
            parameters={"email": email},
        ).result_rows
    except Exception:
        log.exception("Не удалось проверить учётные данные email=%s", email)
        return None
    if not rows:
        return None
    user_id, user_email, password_hash, first_name, last_name = rows[0]
    if not check_password_hash(password_hash, password):
        return None
    return User(user_id, user_email, first_name, last_name)


@login_manager.user_loader
def load_user(user_id: str) -> User | None:
    return find_user_by_id(user_id)
