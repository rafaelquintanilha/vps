set -e

# Create Metabase database and user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create Metabase user if it doesn't exist
    DO
    \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${METABASE_DB_USER}') THEN
            CREATE USER ${METABASE_DB_USER} WITH PASSWORD '${METABASE_DB_PASS}';
        END IF;
    END
    \$\$;

    -- Create Metabase database if it doesn't exist
    SELECT 'CREATE DATABASE ${METABASE_DB_NAME} OWNER ${METABASE_DB_USER}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${METABASE_DB_NAME}')\gexec

    -- Grant all privileges on the database to the user
    GRANT ALL PRIVILEGES ON DATABASE ${METABASE_DB_NAME} TO ${METABASE_DB_USER};
EOSQL

echo "Metabase database and user created successfully!"

# Realstate Scraper database and user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO
    \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${REALSTATE_DB_USER}') THEN
            CREATE USER ${REALSTATE_DB_USER} WITH PASSWORD '${REALSTATE_DB_PASS}';
        END IF;
    END
    \$\$;

    SELECT 'CREATE DATABASE ${REALSTATE_DB_NAME} OWNER ${REALSTATE_DB_USER}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${REALSTATE_DB_NAME}')\gexec

    GRANT ALL PRIVILEGES ON DATABASE ${REALSTATE_DB_NAME} TO ${REALSTATE_DB_USER};
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${REALSTATE_DB_NAME}" <<-EOSQL
    GRANT ALL ON SCHEMA public TO ${REALSTATE_DB_USER};
EOSQL

echo "Realstate Scraper database and user created successfully!"

# You can add more database creation commands here for other apps