import sqlite3

import pytest

from hermes_state import SessionDB
from hermes_state_common import SCHEMA_SQL


@pytest.fixture
def db(tmp_path):
    database = SessionDB(tmp_path / "state.db")
    try:
        yield database
    finally:
        database.close()


def test_hidden_excluded_by_default_included_on_request(db):
    db.create_session("visible", source="cli")
    db.create_session("secret", source="cli")
    # Give both a message so the default min_message_count filter keeps them.
    for sid in ("visible", "secret"):
        db._conn.execute(
            "UPDATE sessions SET message_count = 1 WHERE id = ?", (sid,)
        )
    db._conn.commit()

    # Flip the hidden flag on one session.
    assert db.set_session_hidden("secret", True) is True
    assert db.get_session("secret")["hidden"] == 1
    assert db.get_session("visible")["hidden"] == 0

    # Default listing drops the hidden row; include_hidden=True surfaces it.
    default_ids = {s["id"] for s in db.list_sessions_rich(min_message_count=1)}
    assert default_ids == {"visible"}

    all_ids = {
        s["id"]
        for s in db.list_sessions_rich(min_message_count=1, include_hidden=True)
    }
    assert all_ids == {"visible", "secret"}

    # Unhiding brings it back into the default listing.
    assert db.set_session_hidden("secret", False) is True
    assert db.get_session("secret")["hidden"] == 0
    unhidden_ids = {s["id"] for s in db.list_sessions_rich(min_message_count=1)}
    assert unhidden_ids == {"visible", "secret"}


def test_existing_pre_hidden_schema_is_reconciled_before_hidden_queries(tmp_path):
    path = tmp_path / "pre-hidden.db"
    old_schema = SCHEMA_SQL.replace(
        "    hidden INTEGER NOT NULL DEFAULT 0,\n", "", 1
    )
    assert old_schema != SCHEMA_SQL
    connection = sqlite3.connect(path)
    try:
        connection.executescript(old_schema)
        connection.commit()
    finally:
        connection.close()

    database = SessionDB(path)
    try:
        columns = {
            row[1]
            for row in database._conn.execute("PRAGMA table_info(sessions)")
        }
        assert "hidden" in columns
        database.create_session("legacy", source="cli")
        assert database.set_session_hidden("legacy", True) is True
        assert database.get_session("legacy")["hidden"] == 1
        assert database.list_sessions_rich() == []
        assert database.list_sessions_rich(include_hidden=True)[0]["id"] == "legacy"
    finally:
        database.close()
