-- SPDX-License-Identifier: MIT OR Apache-2.0
-- The hub's history: one row per polled sample. The sample itself is
-- stored as the JSON the agent served, so serving it back is a copy,
-- not a re-encode, and a schema change upstream never orphans old
-- rows. Queries always go by (host, ts_ms), hence the index.
CREATE TABLE samples (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    host    TEXT NOT NULL,
    ts_ms   INTEGER NOT NULL,
    payload TEXT NOT NULL
);
CREATE INDEX samples_host_ts ON samples (host, ts_ms);
