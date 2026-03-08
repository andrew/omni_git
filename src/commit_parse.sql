create function commit_parse(p_content bytea)
returns table(
    tree_oid bytea,
    parent_oids bytea[],
    author_name text,
    author_email text,
    author_timestamp bigint,
    author_tz text,
    committer_name text,
    committer_email text,
    committer_timestamp bigint,
    committer_tz text,
    message text
)
language plpgsql immutable strict as $$
declare
    v_text text;
    v_lines text[];
    v_line text;
    v_header_end integer;
    v_parents bytea[] := '{}';
    v_i integer;
    v_parts text[];
    v_ident text;
begin
    v_text := convert_from(p_content, 'UTF8');

    v_header_end := position(E'\n\n' in v_text);
    if v_header_end = 0 then
        message := '';
        v_lines := string_to_array(v_text, E'\n');
    else
        message := substring(v_text from v_header_end + 2);
        v_lines := string_to_array(substring(v_text from 1 for v_header_end - 1), E'\n');
    end if;

    for v_i in 1..array_length(v_lines, 1) loop
        v_line := v_lines[v_i];

        if v_line like 'tree %' then
            tree_oid := decode(substring(v_line from 6), 'hex');

        elsif v_line like 'parent %' then
            v_parents := v_parents || decode(substring(v_line from 8), 'hex');

        elsif v_line like 'author %' then
            v_ident := substring(v_line from 8);
            author_email := substring(v_ident from '<([^>]+)>');
            author_name := trim(substring(v_ident from 1 for position('<' in v_ident) - 1));
            v_parts := regexp_matches(v_ident, '> (\d+) ([+-]\d{4})$');
            author_timestamp := v_parts[1]::bigint;
            author_tz := v_parts[2];

        elsif v_line like 'committer %' then
            v_ident := substring(v_line from 11);
            committer_email := substring(v_ident from '<([^>]+)>');
            committer_name := trim(substring(v_ident from 1 for position('<' in v_ident) - 1));
            v_parts := regexp_matches(v_ident, '> (\d+) ([+-]\d{4})$');
            committer_timestamp := v_parts[1]::bigint;
            committer_tz := v_parts[2];
        end if;
    end loop;

    parent_oids := v_parents;
    return next;
end;
$$;
