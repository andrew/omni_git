create function ref_update(
    p_repo_id integer,
    p_name text,
    p_new_oid bytea,
    p_old_oid bytea default null,
    p_force boolean default false
)
returns boolean
language plpgsql as $$
declare
    v_current_oid bytea;
begin
    select oid into v_current_oid
    from omni_git.refs
    where repo_id = p_repo_id and name = p_name
    for update;

    if not found then
        if p_old_oid is not null and p_old_oid != '\x0000000000000000000000000000000000000000'::bytea then
            return false;
        end if;

        insert into omni_git.refs (repo_id, name, oid)
        values (p_repo_id, p_name, p_new_oid);
        return true;
    end if;

    if not p_force and p_old_oid is not null
       and p_old_oid != '\x0000000000000000000000000000000000000000'::bytea
       and v_current_oid != p_old_oid then
        return false;
    end if;

    if p_new_oid is null or p_new_oid = '\x0000000000000000000000000000000000000000'::bytea then
        delete from omni_git.refs where repo_id = p_repo_id and name = p_name;
    else
        update omni_git.refs set oid = p_new_oid, symbolic = null
        where repo_id = p_repo_id and name = p_name;
    end if;

    return true;
end;
$$;

create function ref_set_symbolic(
    p_repo_id integer,
    p_name text,
    p_target text
)
returns void
language plpgsql as $$
begin
    insert into omni_git.refs (repo_id, name, symbolic)
    values (p_repo_id, p_name, p_target)
    on conflict (repo_id, name) do update
    set oid = null, symbolic = p_target;
end;
$$;
