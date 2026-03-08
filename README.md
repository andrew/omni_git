## omni_git

A PostgreSQL extension that stores git repositories in database tables and serves the git smart HTTP protocol, turning Postgres into a git remote. Pair it with [omnigres](https://omnigres.com) and you get `git push` to deploy: your application code goes straight from a git push into a running Postgres instance, no filesystem, no CI pipeline, no container registry.

Built on [gitgres](https://github.com/andrew/gitgres). See [Git in Postgres](https://nesbitt.io/2026/02/26/git-in-postgres.html) for the background.

## How it works

Git objects (commits, trees, blobs, tags) live in an `objects` table. Refs live in a `refs` table with compare-and-swap updates. The extension implements the git smart HTTP protocol entirely in SQL, with a C function for packfile unpacking and generation (via libgit2).

When you `git push`, the HTTP handler (served by omni_httpd) receives the packfile, unpacks every object into the database, and updates the refs. A trigger on the refs table fires on push to main, walks the git tree to find deployable files, and executes them: SQL files run directly, Python files go through omni_python.

When you `git clone`, the extension collects all reachable objects, generates a packfile in C (zlib-compressed, no deltas), and sends it back.

## Quick start with Docker

```
docker build -t omni_git .
docker run --rm -p 5432:5432 -p 8080:8081 omni_git
```

Push a repo:

```
cd your-app
git remote add pg http://localhost:8080/demo
git push pg main
```

Check what landed:

```
PGPASSWORD=omnigres psql -U omnigres -d omnigres -h localhost -c "select sha, message from omni_git.commits_view order by authored_at desc limit 5"
```

## Deploy convention

The deploy trigger looks for files in a `deploy/` directory in your repo:

```
deploy/
  migrate/    SQL files, run in alphabetical order (schema changes)
  handlers/   SQL and Python handler definitions
  seed.sql    Route registration and seed data, run last
```

Everything outside `deploy/` is ignored during deployment. You can have tests, docs, whatever else alongside it.

To enable deploy on a repo:

```sql
insert into omni_git.deploy_config (repo_id, branch)
select id, 'refs/heads/main' from omni_git.repositories where name = 'myapp';
```

Deployments are logged in `omni_git.deploy_log` with status, error messages, and file counts.

## Standalone setup

Requires PostgreSQL 17 with pgcrypto, libgit2, and OpenSSL.

```
make
make install
```

Then in psql:

```sql
create extension omni_git cascade;
insert into omni_git.repositories (name) values ('myrepo');
```

## SQL interface

Write a blob:

```sql
select encode(omni_git.object_write(1, 3::smallint, convert_to('hello', 'UTF8')), 'hex');
```

Read a file from a commit:

```sql
select omni_git.read_blob_at_commit(1, decode('abc123...', 'hex'), 'deploy/handlers/app.sql');
```

Walk a tree:

```sql
select path, mode, encode(oid, 'hex')
from omni_git.ls_tree_r(1, decode('abc123...', 'hex'));
```

Query commits:

```sql
refresh materialized view omni_git.commits_view;
select sha, author_name, authored_at, message
from omni_git.commits_view
order by authored_at desc;
```

## What's here

**Ported from gitgres:** object storage with SHA1 hashing, tree and commit parsing, recursive tree walks, ref management with compare-and-swap, materialized views for commits and tree entries.

**New:** git smart HTTP protocol (packet-line encoding in SQL), packfile unpacking and generation (C/libgit2), HTTP handlers for omni_httpd, deploy-on-push trigger system.

## License

MIT
