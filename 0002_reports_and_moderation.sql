-- 0002_reports_and_moderation.sql

CREATE TABLE IF NOT EXISTS moderation_actions (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actor_sid VARCHAR(32) NOT NULL,
  target_sid VARCHAR(32) NOT NULL,
  action VARCHAR(32) NOT NULL, -- 'mute','warn','kick','ban_temp','ban_perm'
  minutes INT NULL,
  reason VARCHAR(255) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS reports (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reporter_sid VARCHAR(32) NOT NULL,
  targets_json JSON NOT NULL,
  description VARCHAR(1024) NOT NULL,
  status ENUM('open','claimed','resolved','closed') NOT NULL DEFAULT 'open',
  handled_by VARCHAR(32) NULL,
  resolution_note VARCHAR(1024) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Seed UI perms (if not present)
INSERT IGNORE INTO permissions (name, description) VALUES
 ('ui.admin.moderation', 'Access Moderation page'),
 ('ui.admin.reports', 'Access Reports page'),
 ('ui.admin.roles.edit', 'Access Role Editing page'),
 ('ui.admin.perms.edit', 'Access Role Assignment page');

-- Example grants (adjust to taste)
-- Mods: moderation + reports
INSERT INTO role_permissions (role_id, perm_id, effect)
SELECT r.id, p.id, 'allow' FROM roles r JOIN permissions p ON r.name='mod' AND p.name IN ('ui.admin.moderation','ui.admin.reports')
ON DUPLICATE KEY UPDATE effect='allow';

-- Admins: role assignment + role editing (+ everything mods can)
INSERT INTO role_permissions (role_id, perm_id, effect)
SELECT r.id, p.id, 'allow' FROM roles r JOIN permissions p ON r.name='admin' AND p.name IN ('ui.admin.perms.edit','ui.admin.roles.edit','ui.admin.moderation','ui.admin.reports')
ON DUPLICATE KEY UPDATE effect='allow';
