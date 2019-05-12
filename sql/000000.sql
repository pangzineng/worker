BEGIN;
  create extension if not exists pgcrypto with schema public;
  create extension if not exists "uuid-ossp" with schema public;
  create schema :SCHEMA_NAME;
COMMIT;