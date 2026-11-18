-- BIOPRESS Analytics: PostgreSQL 16 schema
-- Generated from backend/app/db/models.py (same tables, columns and constraints).
-- Only what the data supports: no dates, workers, patients or sessions tables.

CREATE TABLE institutions (
  id SERIAL PRIMARY KEY,
  name VARCHAR(200) NOT NULL UNIQUE
);

CREATE TABLE wards (
  id SERIAL PRIMARY KEY,
  institution_id INTEGER NOT NULL REFERENCES institutions(id),
  name VARCHAR(100) NOT NULL,
  CONSTRAINT uq_wards_institution_name UNIQUE (institution_id, name)
);

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  role VARCHAR(20) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  CONSTRAINT ck_users_role CHECK (role IN ('admin', 'analyst', 'viewer'))
);

CREATE TABLE data_imports (
  id SERIAL PRIMARY KEY,
  filename VARCHAR(255) NOT NULL,
  sha256 VARCHAR(64) NOT NULL UNIQUE,          -- same file cannot be imported twice
  row_count INTEGER NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'committed',
  imported_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  imported_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  notes TEXT,                                   -- JSON text: import warnings
  CONSTRAINT ck_data_imports_status CHECK (status IN ('committed', 'archived')),
  CONSTRAINT ck_data_imports_row_count CHECK (row_count >= 0)
);

CREATE TABLE hand_hygiene_opportunities (
  id SERIAL PRIMARY KEY,
  import_id INTEGER NOT NULL REFERENCES data_imports(id) ON DELETE RESTRICT,
  row_number INTEGER NOT NULL,                  -- position in the uploaded file (1-based)
  source_opp INTEGER,                           -- original Opp, NOT unique (788 appears twice)
  ward_id INTEGER NOT NULL REFERENCES wards(id),
  profcat VARCHAR(50) NOT NULL,
  shift VARCHAR(50) NOT NULL,
  indication VARCHAR(100) NOT NULL,
  hh_action VARCHAR(50),                        -- LEAKY: never a model input
  missed_but_glove VARCHAR(10),                 -- LEAKY: never a model input
  complied BOOLEAN NOT NULL,
  CONSTRAINT uq_opportunity_import_row UNIQUE (import_id, row_number),
  CONSTRAINT ck_opp_profcat CHECK (profcat IN ('Nurse', 'Medical doctor', 'Midwife', 'Other')),
  CONSTRAINT ck_opp_shift CHECK (shift IN ('Morning', 'After noon', 'Night')),
  CONSTRAINT ck_opp_indication CHECK (indication IN ('Before patient contact', 'Before an aseptic procedure', 'After patient contact', 'After contact with patient Surroundings', 'After body fluid exposure')),
  CONSTRAINT ck_opp_hh_action CHECK (hh_action IS NULL OR hh_action IN ('HW (hand wash)', 'HR (hand rub)')),
  CONSTRAINT ck_opp_missed CHECK (missed_but_glove IS NULL OR missed_but_glove IN ('Yes', 'No')),
  CONSTRAINT ck_opp_complied_not_null CHECK (complied IS NOT NULL)
);
CREATE INDEX ix_opp_import_id ON hand_hygiene_opportunities (import_id);
CREATE INDEX ix_opp_ward_id ON hand_hygiene_opportunities (ward_id);
CREATE INDEX ix_opp_indication ON hand_hygiene_opportunities (indication);
CREATE INDEX ix_opp_shift ON hand_hygiene_opportunities (shift);

CREATE TABLE model_runs (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  model_type VARCHAR(50) NOT NULL,
  git_commit VARCHAR(40),
  data_import_id INTEGER REFERENCES data_imports(id),
  features JSON NOT NULL,
  metrics JSON NOT NULL,
  artifact_path VARCHAR(500)
);

CREATE TABLE audit_log (
  id SERIAL PRIMARY KEY,
  ts TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  username VARCHAR(64),
  action VARCHAR(50) NOT NULL,
  resource VARCHAR(200),
  details JSON,                                 -- never passwords or tokens
  ip VARCHAR(45)
);
CREATE INDEX ix_audit_ts ON audit_log (ts);
CREATE INDEX ix_audit_action ON audit_log (action);

-- Reference data: one institution, five wards
INSERT INTO institutions (id, name) VALUES (1, 'Debre Berhan referral hospital');
INSERT INTO wards (institution_id, name) VALUES (1, 'Ob/Gyn');
INSERT INTO wards (institution_id, name) VALUES (1, 'Paediatric');
INSERT INTO wards (institution_id, name) VALUES (1, 'Medical');
INSERT INTO wards (institution_id, name) VALUES (1, 'Surgical');
INSERT INTO wards (institution_id, name) VALUES (1, 'NICU');

-- Views (only 'committed' imports are visible)
CREATE VIEW v_ml_features AS
SELECT w.name AS ward,
       o.profcat AS profcat,
       o.shift AS shift,
       o.indication AS indication,
       o.complied AS complied
FROM hand_hygiene_opportunities o
JOIN wards w ON w.id = o.ward_id
JOIN data_imports i ON i.id = o.import_id
WHERE i.status = 'committed';

CREATE VIEW v_compliance_facts AS
SELECT w.name AS ward,
       o.shift AS shift,
       o.profcat AS profcat,
       o.indication AS indication,
       COUNT(*) AS n,
       SUM(CASE WHEN o.complied THEN 1 ELSE 0 END) AS complied_count
FROM hand_hygiene_opportunities o
JOIN wards w ON w.id = o.ward_id
JOIN data_imports i ON i.id = o.import_id
WHERE i.status = 'committed'
GROUP BY w.name, o.shift, o.profcat, o.indication;

CREATE VIEW v_import_summary AS
SELECT id, filename, sha256, row_count, status, imported_at, notes
FROM data_imports;


-- Least-privilege access. Roles are created first by scripts/db/init/01_roles.sh
-- (migration_owner, app_rw, analytics_ro, agent_ro). Run this file as migration_owner.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
    GRANT USAGE ON SCHEMA public TO app_rw;
    GRANT SELECT ON institutions, wards TO app_rw;
    GRANT SELECT, INSERT, UPDATE ON users TO app_rw;
    GRANT SELECT, INSERT, UPDATE ON data_imports TO app_rw;
    GRANT SELECT, INSERT ON hand_hygiene_opportunities TO app_rw;   -- no UPDATE/DELETE: imported rows are immutable
    GRANT SELECT, INSERT ON model_runs TO app_rw;
    GRANT INSERT ON audit_log TO app_rw;                             -- append-only: cannot read, edit or delete
    GRANT SELECT ON v_ml_features, v_compliance_facts, v_import_summary TO app_rw;
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro') THEN
    GRANT USAGE ON SCHEMA public TO analytics_ro;
    GRANT SELECT ON v_ml_features, v_compliance_facts, v_import_summary TO analytics_ro;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro') THEN
    GRANT USAGE ON SCHEMA public TO agent_ro;
    GRANT SELECT ON v_compliance_facts, v_import_summary TO agent_ro;   -- aggregates only, no row-level view
  END IF;
END $$;
