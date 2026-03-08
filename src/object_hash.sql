-- Type codes: 1=commit, 2=tree, 3=blob, 4=tag
create function type_name(obj_type smallint)
returns text
language sql immutable strict as $$
    select case obj_type
        when 1 then 'commit'
        when 2 then 'tree'
        when 3 then 'blob'
        when 4 then 'tag'
    end;
$$;

-- Git object hash: SHA1("<type> <size>\0<content>")
create function object_hash(obj_type smallint, content bytea)
returns bytea
language sql immutable strict as $$
    select digest(
        convert_to(omni_git.type_name(obj_type) || ' ' || octet_length(content)::text, 'UTF8')
        || '\x00'::bytea
        || content,
        'sha1'
    );
$$;
