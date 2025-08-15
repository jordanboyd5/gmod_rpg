-- 0001_init.sql
CREATE TABLE IF NOT EXISTS schema_version (
  id INT PRIMARY KEY,
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS roles (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64) NOT NULL UNIQUE,
  display_name VARCHAR(128) NOT NULL,
  priority INT NOT NULL DEFAULT 0,
  color INT NOT NULL DEFAULT 16777215, -- RGB int for UI
  is_default TINYINT(1) NOT NULL DEFAULT 0,
  inherits JSON NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS permissions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(128) NOT NULL UNIQUE,
  description VARCHAR(255) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS role_permissions (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  role_id INT NOT NULL,
  perm_id INT NOT NULL,
  effect ENUM('allow','deny') NOT NULL,
  context JSON NULL,
  CONSTRAINT fk_rp_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE,
  CONSTRAINT fk_rp_perm FOREIGN KEY (perm_id) REFERENCES permissions(id) ON DELETE CASCADE,
  UNIQUE KEY uq_role_perm (role_id, perm_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_roles (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  steamid64 VARCHAR(32) NOT NULL,
  role_id INT NOT NULL,
  ctx JSON NULL,
  expires_at DATETIME NULL,
  granted_by VARCHAR(32) NULL,
  reason VARCHAR(255) NULL,
  CONSTRAINT fk_ur_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE,
  KEY idx_ur_user (steamid64),
  KEY idx_ur_exp (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_overrides (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  steamid64 VARCHAR(32) NOT NULL,
  perm_id INT NOT NULL,
  effect ENUM('allow','deny') NOT NULL,
  context JSON NULL,
  expires_at DATETIME NULL,
  granted_by VARCHAR(32) NULL,
  reason VARCHAR(255) NULL,
  CONSTRAINT fk_uo_perm FOREIGN KEY (perm_id) REFERENCES permissions(id) ON DELETE CASCADE,
  KEY idx_uo_user (steamid64),
  KEY idx_uo_exp (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audit_log (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actor_steamid64 VARCHAR(32) NOT NULL,
  action VARCHAR(64) NOT NULL,
  target_steamid64 VARCHAR(32) NULL,
  payload JSON NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Seed a few permissions and roles to start
INSERT IGNORE INTO permissions (name, description) VALUES
 ('ui.admin.open', 'Open the admin panel'),
 ('player.kick', 'Kick a player'),
 ('chat.mute', 'Mute a player in chat'),
 ('*', 'Wildcard all permissions');

INSERT IGNORE INTO roles (name, display_name, priority, color, is_default, inherits) VALUES
 ('owner', 'Owner', 1000, 0xFFAA00, 0, JSON_ARRAY()), 
 ('admin', 'Admin', 900, 0xFF0000, 0, JSON_ARRAY()),
 ('mod', 'Moderator', 500, 0x00AAFF, 0, JSON_ARRAY()),
 ('helper', 'Helper', 300, 0x55FF55, 0, JSON_ARRAY()),
 ('player', 'Player', 0, 0xFFFFFF, 1, JSON_ARRAY());

-- Mark this migration applied
INSERT IGNORE INTO schema_version (id, applied_at) VALUES (1, NOW());
