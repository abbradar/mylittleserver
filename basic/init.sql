CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (name != ''),
    password TEXT NOT NULL CHECK (password LIKE '$6$%'), -- enforce SHA-512 hash
    enabled BOOLEAN NOT NULL
);

GRANT SELECT ON users TO auth;
GRANT UPDATE (password, enabled) ON users TO auth_update;
