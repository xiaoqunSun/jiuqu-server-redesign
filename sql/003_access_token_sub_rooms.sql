CREATE TABLE IF NOT EXISTS access_token_sub_rooms (
    token_hash CHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    room_id VARBINARY(191) NOT NULL,
    sub_room VARBINARY(191) NOT NULL,
    created_ts BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (token_hash, room_id, sub_room),
    KEY idx_access_sub_room (room_id, sub_room)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
