-- Parse binary tree object content into rows of (mode, name, entry_oid)
-- Tree format: repeated entries of "<mode> <name>\0<20-byte-oid>"
create function tree_entries(p_content bytea)
returns table(mode text, name text, entry_oid bytea)
language plpgsql immutable strict as $$
declare
    v_pos integer := 1;
    v_len integer;
    v_space_pos integer;
    v_null_pos integer;
begin
    v_len := octet_length(p_content);

    while v_pos <= v_len loop
        v_space_pos := v_pos;
        while v_space_pos <= v_len and get_byte(p_content, v_space_pos - 1) != 32 loop
            v_space_pos := v_space_pos + 1;
        end loop;

        v_null_pos := v_space_pos + 1;
        while v_null_pos <= v_len and get_byte(p_content, v_null_pos - 1) != 0 loop
            v_null_pos := v_null_pos + 1;
        end loop;

        mode := convert_from(substring(p_content from v_pos for v_space_pos - v_pos), 'UTF8');
        name := convert_from(substring(p_content from v_space_pos + 1 for v_null_pos - v_space_pos - 1), 'UTF8');
        entry_oid := substring(p_content from v_null_pos + 1 for 20);

        return next;

        v_pos := v_null_pos + 21;
    end loop;
end;
$$;

-- Recursive tree walk
create function ls_tree_r(
    p_repo_id integer,
    p_tree_oid bytea,
    p_prefix text default ''
)
returns table(mode text, path text, oid bytea, obj_type text)
language plpgsql stable as $$
declare
    v_content bytea;
    v_entry record;
begin
    select o.content into v_content
    from omni_git.objects o
    where o.repo_id = p_repo_id and o.oid = p_tree_oid and o.type = 2;

    if v_content is null then
        return;
    end if;

    for v_entry in select e.mode, e.name, e.entry_oid from omni_git.tree_entries(v_content) e loop
        if v_entry.mode = '40000' then
            path := p_prefix || v_entry.name || '/';
            mode := v_entry.mode;
            oid := v_entry.entry_oid;
            obj_type := 'tree';
            return next;

            return query select * from omni_git.ls_tree_r(p_repo_id, v_entry.entry_oid, p_prefix || v_entry.name || '/');
        else
            path := p_prefix || v_entry.name;
            mode := v_entry.mode;
            oid := v_entry.entry_oid;
            obj_type := 'blob';
            return next;
        end if;
    end loop;
end;
$$;
