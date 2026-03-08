create table repositories (
    id          serial primary key,
    name        text not null unique,
    created_at  timestamptz not null default now()
);

create table objects (
    repo_id     integer not null references repositories(id),
    oid         bytea not null,
    type        smallint not null,
    size        integer not null,
    content     bytea not null,
    primary key (repo_id, oid)
);
create index idx_objects_oid on objects (oid);

create table refs (
    repo_id     integer not null references repositories(id),
    name        text not null,
    oid         bytea,
    symbolic    text,
    primary key (repo_id, name),
    check ((oid is not null) != (symbolic is not null))
);

create table reflog (
    id          bigserial primary key,
    repo_id     integer not null references repositories(id),
    ref_name    text not null,
    old_oid     bytea,
    new_oid     bytea,
    committer   text not null,
    timestamp_s bigint not null,
    tz_offset   text not null,
    message     text,
    created_at  timestamptz not null default now()
);
create index idx_reflog_ref on reflog (repo_id, ref_name, id);
