CREATE TABLE IF NOT EXISTS room_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    room_id VARBINARY(191) NOT NULL,
    sequence_no BIGINT UNSIGNED NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    payload_json LONGTEXT NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_room_sequence (room_id, sequence_no),
    KEY idx_room_created (room_id, created_ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS room_snapshots (
    room_id VARBINARY(191) NOT NULL,
    sequence_no BIGINT UNSIGNED NOT NULL,
    schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    snapshot_json LONGTEXT NOT NULL,
    updated_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (room_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS chat_messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    channel VARBINARY(128) NOT NULL,
    sender VARBINARY(255) NOT NULL,
    message_text BLOB NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (id),
    KEY idx_channel_id (channel, id),
    KEY idx_channel_created (channel, created_ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS access_tokens (
    token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    identity_id VARBINARY(255) NOT NULL,
    room_id VARBINARY(191) NOT NULL,
    root_room_id VARBINARY(191) NOT NULL,
    is_master TINYINT UNSIGNED NOT NULL DEFAULT 0,
    begin_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
    expires_at BIGINT UNSIGNED NULL,
    revoked_at BIGINT UNSIGNED NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (token_hash, room_id),
    KEY idx_access_identity (identity_id, room_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS access_token_chat_channels (
    token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    room_id VARBINARY(191) NOT NULL,
    channel VARBINARY(128) NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (token_hash, room_id, channel),
    KEY idx_access_channel (room_id, channel)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS access_token_sub_rooms (
    token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    room_id VARBINARY(191) NOT NULL,
    sub_room VARBINARY(191) NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (token_hash, room_id, sub_room),
    KEY idx_access_sub_room (room_id, sub_room)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;


CREATE TABLE IF NOT EXISTS room_lifecycle (
    room_id VARBINARY(191) NOT NULL,
    is_closed TINYINT UNSIGNED NOT NULL DEFAULT 0,
    updated_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (room_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
