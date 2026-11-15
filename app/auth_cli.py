"""One-time, interactive owner account provisioning command."""

import getpass
import logging
import sys

from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.auth import InvalidOwnerInput, OwnerAlreadyProvisioned, provision_owner, prune_auth_data
from app.config import get_settings
from app.database import create_database_engine, create_session_factory

logger = logging.getLogger(__name__)


def main() -> int:
    arguments = sys.argv[1:]
    if arguments in (["-h"], ["--help"]):
        print("Usage: python -m app.auth_cli [provision-owner|prune-auth-data]")
        return 0
    if arguments not in ([], ["provision-owner"], ["prune-auth-data"]):
        print("Invalid maintenance command. Choose provision-owner or prune-auth-data.", file=sys.stderr)
        return 2
    command = arguments[0] if arguments else "provision-owner"
    engine = None
    try:
        engine = create_database_engine(get_settings().database_url)
        if command == "prune-auth-data":
            with create_session_factory(engine)() as session:
                counts = prune_auth_data(session, get_settings())
                session.commit()
            print(
                "Expired authentication records removed: "
                f"sessions={counts['sessions']}, throttles={counts['throttles']}, events={counts['events']}"
            )
            return 0

        print("Create the initial owner account. Credentials will not be saved or echoed.")
        login_name = input("Owner login name: ")
        password = getpass.getpass("Password (15 characters minimum): ")
        confirmation = getpass.getpass("Confirm password: ")
        if password != confirmation:
            print("Passwords did not match.", file=sys.stderr)
            return 2

        with create_session_factory(engine)() as session:
            try:
                provision_owner(session, login_name, password)
                session.commit()
            except (InvalidOwnerInput, OwnerAlreadyProvisioned) as exc:
                session.rollback()
                print(str(exc), file=sys.stderr)
                return 2
            except IntegrityError as exc:
                session.rollback()
                logger.error("Owner provisioning conflict; error_type=%s", type(exc).__name__)
                print("Owner provisioning could not be completed due to a database conflict.", file=sys.stderr)
                return 2
        print("Owner account provisioned successfully.")
        return 0
    except SQLAlchemyError as exc:
        logger.error("Authentication maintenance database error; error_type=%s", type(exc).__name__)
        print("Database operation failed. Check database configuration and migrations.", file=sys.stderr)
        return 1
    except Exception as exc:
        logger.error("Authentication maintenance failed; error_type=%s", type(exc).__name__)
        print("Operation could not be completed. Check sanitized operator diagnostics.", file=sys.stderr)
        return 1
    finally:
        if engine is not None:
            engine.dispose()


if __name__ == "__main__":
    raise SystemExit(main())
