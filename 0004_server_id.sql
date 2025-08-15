-- START /garrysmod/data/rpg_perms/migrations/0004_server_id.sql
-- Add a server_id to each table so multiple Garry's Mod servers can share one DB.
-- Uses a trigger that reads @rpg_server_id set by Lua on connect.

-- 1) Column (default 0 keeps old inserts working even before triggers fire)
ALTER TABLE chat_messages ADD COLUMN server_id SMALLINT NOT NULL DEFAULT 0, ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE chat_reports  ADD COLUMN server_id SMALLINT NOT NULL DEFAULT 0, ALGORITHM=INPLACE, LOCK=NONE;
ALTER TABLE chat_mutes    ADD COLUMN server_id SMALLINT NOT NULL DEFAULT 0, ALGORITHM=INPLACE, LOCK=NONE;

-- 2) Helpful indexes
ALTER TABLE chat_messages ADD INDEX idx_cm_server_ts (server_id, ts);
ALTER TABLE chat_reports  ADD INDEX idx_cr_server_ts (server_id, ts);
ALTER TABLE chat_mutes    ADD INDEX idx_cmu_server_exp (server_id, expires_at);

-- 3) BEFORE INSERT triggers to stamp the server_id automatically
DROP TRIGGER IF EXISTS trg_cm_server_id;
DELIMITER //
CREATE TRIGGER trg_cm_server_id BEFORE INSERT ON chat_messages
FOR EACH ROW BEGIN
  IF NEW.server_id IS NULL OR NEW.server_id = 0 THEN
    SET NEW.server_id = IFNULL(@rpg_server_id, 0);
  END IF;
END//
DELIMITER ;

DROP TRIGGER IF EXISTS trg_cr_server_id;
DELIMITER //
CREATE TRIGGER trg_cr_server_id BEFORE INSERT ON chat_reports
FOR EACH ROW BEGIN
  IF NEW.server_id IS NULL OR NEW.server_id = 0 THEN
    SET NEW.server_id = IFNULL(@rpg_server_id, 0);
  END IF;
END//
DELIMITER ;

DROP TRIGGER IF EXISTS trg_cmu_server_id;
DELIMITER //
CREATE TRIGGER trg_cmu_server_id BEFORE INSERT ON chat_mutes
FOR EACH ROW BEGIN
  IF NEW.server_id IS NULL OR NEW.server_id = 0 THEN
    SET NEW.server_id = IFNULL(@rpg_server_id, 0);
  END IF;
END//
DELIMITER ;
-- END /garrysmod/data/rpg_perms/migrations/0004_server_id.sql
