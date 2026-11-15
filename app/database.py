"""SQLAlchemy engine, declarative base, and request-scoped sessions."""

from collections.abc import Generator

from fastapi import Request
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


class Base(DeclarativeBase):
    """Base class for application ORM models."""


def create_database_engine(database_url: str) -> Engine:
    """Create an engine without opening a connection until it is first used."""
    connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
    return create_engine(database_url, pool_pre_ping=True, connect_args=connect_args)


def create_session_factory(engine: Engine) -> sessionmaker[Session]:
    """Build a session factory bound to the supplied engine."""
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_session(request: Request) -> Generator[Session, None, None]:
    """Yield the current request session attached to the app's configured engine."""
    session_factory = request.app.state.session_factory
    with session_factory() as session:
        yield session
