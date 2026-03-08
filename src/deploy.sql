-- Deployment configuration: which repo/branch to deploy, and how
create table deploy_config (
    id          serial primary key,
    repo_id     integer not null references public.repositories(id),
    branch      text not null default 'refs/heads/main',
    deploy_dir  text not null default '', -- subdirectory to deploy from (empty = root)
    active      boolean not null default true,
    created_at  timestamptz not null default now(),
    unique (repo_id, branch)
);

-- Log of deployments
create table deploy_log (
    id          bigserial primary key,
    config_id   integer not null references omni_git.deploy_config(id),
    commit_oid  bytea not null,
    commit_sha  text not null,
    status      text not null, -- 'ok', 'error'
    message     text,
    files_deployed integer not null default 0,
    deployed_at timestamptz not null default now()
);

-- Read a blob from the git tree at a given commit
create function read_blob_at_commit(
    p_repo_id integer,
    p_commit_oid bytea,
    p_path text
)
returns text
language plpgsql stable as $$
declare
    v_commit_content bytea;
    v_tree_oid bytea;
    v_blob_oid bytea;
    v_blob_content bytea;
begin
    select content into v_commit_content
    from public.objects
    where repo_id = p_repo_id and oid = p_commit_oid and type = 1;

    if v_commit_content is null then
        return null;
    end if;

    select tree_oid into v_tree_oid
    from public.git_commit_parse(v_commit_content);

    select t.oid into v_blob_oid
    from public.git_ls_tree_r(p_repo_id, v_tree_oid) t
    where t.path = p_path and t.obj_type = 'blob';

    if v_blob_oid is null then
        return null;
    end if;

    select content into v_blob_content
    from public.objects
    where repo_id = p_repo_id and oid = v_blob_oid and type = 3;

    return convert_from(v_blob_content, 'UTF8');
end;
$$;

-- Deploy a commit: find deployable files and execute/register them.
--
-- Convention:
--   deploy/migrate/*.sql  -- run in alphabetical order (schema migrations)
--   deploy/handlers/*.sql -- SQL handler definitions
--   deploy/handlers/*.py  -- Python handler definitions (via omni_python)
--   deploy/seed.sql       -- run last (seed data, route registration)
--
-- If deploy_dir is set on the config, that prefix is prepended.
-- Files outside these paths are ignored (they're just code in the repo).
create function deploy_commit(p_config_id integer, p_commit_oid bytea)
returns void
language plpgsql as $$
declare
    v_config record;
    v_tree_oid bytea;
    v_commit_content bytea;
    v_file record;
    v_code text;
    v_count integer := 0;
    v_status text := 'ok';
    v_message text := '';
    v_prefix text;
begin
    select * into v_config from omni_git.deploy_config where id = p_config_id;

    select content into v_commit_content
    from public.objects
    where repo_id = v_config.repo_id and oid = p_commit_oid and type = 1;

    if v_commit_content is null then
        insert into omni_git.deploy_log (config_id, commit_oid, commit_sha, status, message, files_deployed)
        values (p_config_id, p_commit_oid, encode(p_commit_oid, 'hex'), 'error', 'commit not found', 0);
        return;
    end if;

    select tree_oid into v_tree_oid
    from public.git_commit_parse(v_commit_content);

    v_prefix := v_config.deploy_dir;
    if v_prefix != '' and not v_prefix like '%/' then
        v_prefix := v_prefix || '/';
    end if;

    -- Phase 1: migrations (run in order)
    for v_file in
        select t.path, t.oid
        from public.git_ls_tree_r(v_config.repo_id, v_tree_oid) t
        where t.obj_type = 'blob'
          and t.path like v_prefix || 'deploy/migrate/%.sql'
        order by t.path
    loop
        select convert_from(content, 'UTF8') into v_code
        from public.objects
        where repo_id = v_config.repo_id and oid = v_file.oid and type = 3;

        begin
            execute v_code;
            v_count := v_count + 1;
        exception when others then
            v_status := 'error';
            v_message := v_message || v_file.path || ': ' || sqlerrm || E'\n';
        end;
    end loop;

    -- Phase 2: handler definitions (SQL)
    for v_file in
        select t.path, t.oid
        from public.git_ls_tree_r(v_config.repo_id, v_tree_oid) t
        where t.obj_type = 'blob'
          and t.path like v_prefix || 'deploy/handlers/%.sql'
        order by t.path
    loop
        select convert_from(content, 'UTF8') into v_code
        from public.objects
        where repo_id = v_config.repo_id and oid = v_file.oid and type = 3;

        begin
            execute v_code;
            v_count := v_count + 1;
        exception when others then
            v_status := 'error';
            v_message := v_message || v_file.path || ': ' || sqlerrm || E'\n';
        end;
    end loop;

    -- Phase 3: Python handlers (via omni_python if available)
    for v_file in
        select t.path, t.oid
        from public.git_ls_tree_r(v_config.repo_id, v_tree_oid) t
        where t.obj_type = 'blob'
          and t.path like v_prefix || 'deploy/handlers/%.py'
        order by t.path
    loop
        select convert_from(content, 'UTF8') into v_code
        from public.objects
        where repo_id = v_config.repo_id and oid = v_file.oid and type = 3;

        begin
            perform omni_python.create_functions(v_code, v_file.path, true);
            v_count := v_count + 1;
        exception when others then
            v_status := 'error';
            v_message := v_message || v_file.path || ': ' || sqlerrm || E'\n';
        end;
    end loop;

    -- Phase 4: seed file
    for v_file in
        select t.path, t.oid
        from public.git_ls_tree_r(v_config.repo_id, v_tree_oid) t
        where t.obj_type = 'blob'
          and t.path = v_prefix || 'deploy/seed.sql'
    loop
        select convert_from(content, 'UTF8') into v_code
        from public.objects
        where repo_id = v_config.repo_id and oid = v_file.oid and type = 3;

        begin
            execute v_code;
            v_count := v_count + 1;
        exception when others then
            v_status := 'error';
            v_message := v_message || v_file.path || ': ' || sqlerrm || E'\n';
        end;
    end loop;

    insert into omni_git.deploy_log (config_id, commit_oid, commit_sha, status, message, files_deployed)
    values (p_config_id, p_commit_oid, encode(p_commit_oid, 'hex'), v_status, nullif(v_message, ''), v_count);
end;
$$;

-- Trigger function: fires after ref update, deploys if branch matches config
create function deploy_on_ref_update()
returns trigger
language plpgsql as $$
declare
    v_config record;
begin
    if new.oid is null then
        return new;
    end if;

    for v_config in
        select * from omni_git.deploy_config
        where repo_id = new.repo_id
          and branch = new.name
          and active = true
    loop
        perform omni_git.deploy_commit(v_config.id, new.oid);
    end loop;

    return new;
end;
$$;

create trigger deploy_after_ref_update
    after insert or update on public.refs
    for each row
    execute function omni_git.deploy_on_ref_update();
