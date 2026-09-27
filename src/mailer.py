"""Отправка писем через локальный Postfix (127.0.0.1:25 на прод-VPS).

Postfix настроен как send-only relay (inet_interfaces=loopback-only),
поэтому для запуска не с самого VPS нужен SSH-туннель на 25-й порт:
    ssh -L 25:127.0.0.1:25 root@<host>
"""

import os
import smtplib
from email.mime.text import MIMEText

MAIL_SMTP_HOST = os.environ.get("MAIL_SMTP_HOST", "127.0.0.1")
MAIL_SMTP_PORT = int(os.environ.get("MAIL_SMTP_PORT", "25"))
MAIL_FROM = os.environ.get("MAIL_FROM", "noreply@finance-black.ru")
MAIL_FROM_NAME = os.environ.get("MAIL_FROM_NAME", "bf-analytics-platform")
LOGIN_URL = os.environ.get("LOGIN_URL", "https://report.finance-black.ru/cloudsix/login")


def send_password_email(to_email: str, full_name: str, password: str) -> None:
    body = (
        f"Здравствуйте, {full_name}!\n\n"
        "Для вас создан доступ к личному кабинету отчётности.\n\n"
        f"Ссылка для входа: {LOGIN_URL}\n"
        f"Логин: {to_email}\n"
        f"Пароль: {password}\n"
    )
    msg = MIMEText(body, _charset="utf-8")
    msg["Subject"] = "Доступ к личному кабинету отчётности"
    msg["From"] = f"{MAIL_FROM_NAME} <{MAIL_FROM}>"
    msg["To"] = to_email

    with smtplib.SMTP(MAIL_SMTP_HOST, MAIL_SMTP_PORT, timeout=15) as smtp:
        smtp.send_message(msg)
