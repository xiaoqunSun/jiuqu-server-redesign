-- Apply once to databases created before event/snapshot schema versions were added.
ALTER TABLE room_events
    ADD COLUMN schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1 AFTER event_type;

ALTER TABLE room_snapshots
    ADD COLUMN schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1 AFTER sequence_no;
