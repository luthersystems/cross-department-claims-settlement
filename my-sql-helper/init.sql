-- Create schema objects
CREATE TABLE IF NOT EXISTS users (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  external_user_id VARCHAR(64) NOT NULL UNIQUE,
  full_name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS policies (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  policy_id VARCHAR(64) NOT NULL UNIQUE, -- e.g. "policy-id"
  product VARCHAR(128) NOT NULL,
  status VARCHAR(32) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS user_policies (
  user_id BIGINT NOT NULL,
  policy_id_fk BIGINT NOT NULL,
  PRIMARY KEY (user_id, policy_id_fk),
  CONSTRAINT fk_up_user FOREIGN KEY (user_id) REFERENCES users(id),
  CONSTRAINT fk_up_policy FOREIGN KEY (policy_id_fk) REFERENCES policies(id)
);

-- Seed data
INSERT INTO users (external_user_id, full_name, email)
VALUES
  ('user-001', 'Ava Martin', 'ava@example.com'),
  ('user-002', 'Ben Shah',   'ben@example.com')
ON DUPLICATE KEY UPDATE full_name=VALUES(full_name), email=VALUES(email);

INSERT INTO policies (policy_id, product, status)
VALUES
  ('policy-id',      'Home',    'active'),
  ('policy-123',     'Auto',    'active'),
  ('policy-cancel',  'Travel',  'cancelled')
ON DUPLICATE KEY UPDATE product=VALUES(product), status=VALUES(status);

-- Link users to policies (many-to-many allowed, but examples are 1:1)
INSERT IGNORE INTO user_policies (user_id, policy_id_fk)
SELECT u.id, p.id FROM users u JOIN policies p ON u.external_user_id='user-001' AND p.policy_id='policy-id';
INSERT IGNORE INTO user_policies (user_id, policy_id_fk)
SELECT u.id, p.id FROM users u JOIN policies p ON u.external_user_id='user-002' AND p.policy_id='policy-123';

-- Convenience VIEW to fetch user details by policy_id
CREATE OR REPLACE VIEW v_user_details_by_policy AS
SELECT
  p.policy_id,
  u.external_user_id,
  u.full_name,
  u.email,
  p.product,
  p.status,
  p.created_at AS policy_created_at
FROM policies p
JOIN user_policies up ON up.policy_id_fk = p.id
JOIN users u         ON u.id = up.user_id;

-- Optional stored procedure version
DROP PROCEDURE IF EXISTS get_user_by_policy;
DELIMITER //
CREATE PROCEDURE get_user_by_policy(IN p_policy_id VARCHAR(64))
BEGIN
  SELECT * FROM v_user_details_by_policy WHERE policy_id = p_policy_id;
END //
DELIMITER ;
