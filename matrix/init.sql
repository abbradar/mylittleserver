GRANT auth TO "matrix-synapse";

-- It is important to have C collation:
-- https://github.com/matrix-org/synapse/blob/develop/docs/postgres.md#fixing-incorrect-collate-or-ctype
SELECT '
CREATE DATABASE "matrix_synapse" WITH OWNER "matrix-synapse"
    TEMPLATE template0
    LC_COLLATE = "C"
    LC_CTYPE = "C"
' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'matrix_synapse') \gexec

GRANT ALL PRIVILEGES ON DATABASE matrix_synapse TO "matrix-synapse";
