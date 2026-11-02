-- It is important to have C collation:
-- https://github.com/matrix-org/synapse/blob/develop/docs/postgres.md#fixing-incorrect-collate-or-ctype
SELECT '
CREATE DATABASE "@database@" WITH OWNER "matrix-synapse"
    TEMPLATE template0
    LC_COLLATE = "C"
    LC_CTYPE = "C"
' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '@database@') \gexec

GRANT ALL PRIVILEGES ON DATABASE "@database@" TO "matrix-synapse";
