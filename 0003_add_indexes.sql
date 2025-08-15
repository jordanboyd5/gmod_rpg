-- START /garrysmod/data/rpg_perms/migrations/0003_add_indexes.sql
-- Speed up common lookups; tweak names as needed for your schema
ALTER TABLE chat_messages
  ADD INDEX idx_cm_sender64 (sender64),
  ADD INDEX idx_cm_target64 (target64),
  ADD INDEX idx_cm_ts (ts);

ALTER TABLE chat_reports
  ADD INDEX idx_cr_reporter64 (reporter64),
  ADD INDEX idx_cr_target64 (target64),
  ADD INDEX idx_cr_ts (ts);

ALTER TABLE chat_mutes
  ADD INDEX idx_cmu_target64 (target64),
  ADD INDEX idx_cmu_expires_at (expires_at);
-- END /garrysmod/data/rpg_perms/migrations/0003_add_indexes.sql
