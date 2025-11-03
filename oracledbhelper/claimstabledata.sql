CREATE USER app IDENTIFIED BY apppw;
GRANT CONNECT, RESOURCE TO app;
ALTER USER app QUOTA UNLIMITED ON USERS;

-- Drop if re-running
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE claims PURGE';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- Table structure that matches your SELECT
CREATE TABLE claims (
  claim_id               VARCHAR2(64)   PRIMARY KEY,
  policy_id              VARCHAR2(64)   NOT NULL,
  amount                 NUMBER(12,2)   NOT NULL,
  status                 VARCHAR2(32)   NOT NULL,
  claimant_first_name    VARCHAR2(100)  NOT NULL,
  claimant_last_name     VARCHAR2(100)  NOT NULL,
  claimant_dob           DATE           NOT NULL,
  claimant_address       VARCHAR2(255)  NOT NULL,
  claimant_national_id   VARCHAR2(64)   NOT NULL
);

CREATE INDEX idx_claims_claim_id ON claims (claim_id);

-- Sample data
INSERT INTO claims VALUES (
  'CLM-1001','POL-2001',1250.50,'OPEN',
  'Alice','Wong',TO_DATE('1990-03-15','YYYY-MM-DD'),
  '221B Baker Street, London NW1','GBR-123456-A'
);

INSERT INTO claims VALUES (
  'CLM-1002','POL-2002',9350.00,'PENDING',
  'Bob','Martin',TO_DATE('1984-11-02','YYYY-MM-DD'),
  '10 Downing Street, London SW1A','GBR-987654-B'
);

INSERT INTO claims VALUES (
  'CLM-1003','POL-2003',310.99,'SETTLED',
  'Chloe','Singh',TO_DATE('1978-07-22','YYYY-MM-DD'),
  '1600 Pennsylvania Ave NW, Washington','USA-55-7788'
);

COMMIT;

SELECT CLAIM_ID, POLICY_ID, AMOUNT, STATUS,
       CLAIMANT_FIRST_NAME, CLAIMANT_LAST_NAME, CLAIMANT_DOB,
       CLAIMANT_ADDRESS, CLAIMANT_NATIONAL_ID
  FROM CLAIMS
 WHERE POLICY_ID = 'POL-2002';