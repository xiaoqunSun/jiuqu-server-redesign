-- Main Skynet configuration. Edit this file for local and deployment settings.
root = "./"
skynet_root = root .. "third_party/skynet/"

thread = 8
harbor = 0
logger = nil
logpath = root .. "logs"
bootstrap = "snlua bootstrap"
start = "main"
lualoader = skynet_root .. "lualib/loader.lua"
enablessl = "true"

luaservice = skynet_root .. "service/?.lua;" .. root .. "service/?.lua"
lua_path = skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua;" .. root .. "lualib/?.lua;" .. root .. "domain/?.lua;" .. root .. "providers/?.lua"
lua_cpath = skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"

listen_host = "0.0.0.0"
tcp_port = 8001
ws_port = 9948
proto_dir = root .. "compat/v1/proto"
sensitive_words_file = root .. "etc/sensitive_words.txt"
mysql_host = "127.0.0.1"
mysql_port = 3306
mysql_database = "jiuqu_server"
mysql_user = "jiuqu_server"
mysql_password = ""
mysql_max_packet_size = 16 * 1024 * 1024
auth_token_pepper = ""
-- Optional old-platform recording metadata lookup; never uses saveRoomData data.api.
recording_provider_module = ""
recording_provider_host = ""
recording_provider_path = "/schedule-api/t/rooms/"
provider_http_timeout_ms = 2000
provider_http_max_response_bytes = 65536
recording_provider_attempts = 3
recording_provider_retry_delay_ms = 1000
is_k12 = "1"
oneSec_frequencyLimit = 200
fiveSec_frequencyLimit = 500
outbound_queue_max_packets = 256
outbound_queue_max_bytes = 1024 * 1024
room_command_queue_max_outstanding = 256
directory_command_queue_max_outstanding = 512
family_command_queue_max_outstanding = 512
chat_command_queue_max_outstanding = 512
store_command_queue_max_outstanding = 512
metrics_slow_command_ms = 1000
metrics_slow_recovery_ms = 1000
room_idle_timeout = 3600
-- K12 room endAt (or Room start time when provider metadata omits it) plus this grace period closes clients.
room_end_grace_period = 1800
-- Replay cursor positions are coalesced by identity and written as one batch per interval.
replay_cursor_flush_interval_ms = 250
chat_messages_per_10s = 30
-- In-memory chat history is only a fallback cache when MySQL history reads fail.
chat_history_cache_channels = 1024
-- Empty-token clients keep old arbitrary-channel behavior for compatibility.
-- Set to "0" after clients use authoritative channel grants.
legacy_chat_channels_unrestricted = "1"
-- Empty-token clients may request any sub-room unless this is set to "0".
legacy_sub_rooms_unrestricted = "1"
admin_host = "127.0.0.1"
admin_port = 0
admin_token = ""
