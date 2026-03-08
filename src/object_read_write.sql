create function object_write(
    p_repo_id integer,
    p_type smallint,
    p_content bytea
)
returns bytea
language plpgsql as $$
declare
    v_oid bytea;
begin
    v_oid := omni_git.object_hash(p_type, p_content);

    insert into omni_git.objects (repo_id, oid, type, size, content)
    values (p_repo_id, v_oid, p_type, octet_length(p_content), p_content)
    on conflict (repo_id, oid) do nothing;

    return v_oid;
end;
$$;

create function object_read(
    p_repo_id integer,
    p_oid bytea
)
returns table(type smallint, size integer, content bytea)
language sql stable strict as $$
    select o.type, o.size, o.content
    from omni_git.objects o
    where o.repo_id = p_repo_id and o.oid = p_oid;
$$;

create function object_read_prefix(
    p_repo_id integer,
    p_prefix bytea,
    p_prefix_len integer
)
returns table(oid bytea, type smallint, size integer, content bytea)
language plpgsql stable as $$
declare
    v_prefix_bytes integer;
begin
    v_prefix_bytes := p_prefix_len / 2;

    return query
    select o.oid, o.type, o.size, o.content
    from omni_git.objects o
    where o.repo_id = p_repo_id
      and substring(o.oid from 1 for v_prefix_bytes) = substring(p_prefix from 1 for v_prefix_bytes);
end;
$$;
