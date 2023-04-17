GRANT auth TO dovecot2;

GRANT SELECT (id, name) ON users TO postfix;

INSERT INTO users (id, name, password, enabled) VALUES
    (0, 'admin', '$6$INVALID', FALSE)
    ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS aliases (
    id SERIAL PRIMARY KEY,
    source TEXT NOT NULL CHECK (source != ''),
    destination INT REFERENCES users (id) ON DELETE CASCADE,
    -- Allow fan-out to multiple destinations (mailing lists).
    UNIQUE (source, destination)
);

GRANT SELECT ON aliases TO postfix;

INSERT INTO aliases (source, destination) VALUES
    ('webmaster@@domain@', 0),
    ('hostmaster@@domain@', 0),
    ('postmaster@@domain@', 0),
    ('abuse@@domain@', 0),
    ('administrator@@domain@', 0),
    ('dmarc@@domain@', 0),
    ('dmarc-forensics@@domain@', 0)
    ON CONFLICT DO NOTHING;
