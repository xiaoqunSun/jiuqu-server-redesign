CREATE TABLE IF NOT EXISTS access_token_chat_channels (
    token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    room_id VARBINARY(191) NOT NULL,
    channel VARBINARY(128) NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (token_hash, room_id, channel),
    KEY idx_access_channel (room_id, channel)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
