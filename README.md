# Documentation

Check out the document for the original `graphile-worker`:
https://github.com/graphile/worker/blob/master/README.md

# What's this fork for

If your DBA does not allow admin access to the database to install extensions and schema, nor would they pass you the name/pw to be put inside a NodeJS application.

In any case where the database setup needed to be decoupled with the nodejs application setup, you should use this fork.

# Guide

## Database Setup

Let your DBA setup the schema with their own admin account
```
cd sql
psql -f 000000.sql -v SCHEMA_NAME=my_worker_schema "postgresql://admin:admin@host:port/mydb"
psql -f 000001.sql -v SCHEMA_NAME=my_worker_schema "postgresql://admin:admin@host:port/mydb"
```

## NodeJs Setup

Lauch your NodeJs application with worker account (NOTE: make sure the account has access to the db `mydb` in this case)
```
npx graphile-worker -c "postgresql://worker:worker@host:port/mydb" -s my_worker_schema
```
