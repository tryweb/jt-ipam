#!/bin/bash
# jt-ipam — PostgreSQL Docker init script
#
# Runs inside the pgvector/pgvector:pg16 container on first startup,
# after the official image has created the POSTGRES_USER / POSTGRES_DB.
# Only creates the required PostgreSQL extensions.
#
# The user/role and database creation are handled by the Docker image's
# own entrypoint via POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB env vars.

set -e

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-'EOSQL'
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS citext;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS btree_gist;
EOSQL
