-- Parse the ref update commands from a receive-pack request body.
-- The body starts with pkt-line encoded ref updates, followed by a packfile.
-- Returns the ref commands and the byte offset where the packfile begins.
create function parse_receive_pack_commands(p_body bytea)
returns table(old_oid bytea, new_oid bytea, ref_name text, packfile_offset integer)
language plpgsql immutable strict as $$
declare
    v_pos integer := 1;
    v_len integer;
    v_pkt_len integer;
    v_hex text;
    v_line text;
    v_line_bytes bytea;
    v_null_pos integer;
    v_parts text[];
begin
    v_len := octet_length(p_body);

    while v_pos + 3 <= v_len loop
        v_hex := convert_from(substring(p_body from v_pos for 4), 'UTF8');

        if v_hex = '0000' then
            -- Flush packet: packfile starts after this
            packfile_offset := v_pos + 4;
            return next;
            return;
        end if;

        v_pkt_len := ('x' || v_hex)::bit(16)::integer;
        if v_pkt_len < 4 then
            exit;
        end if;

        -- Extract line as bytea to handle null bytes safely
        v_line_bytes := substring(p_body from v_pos + 4 for v_pkt_len - 4);

        -- Strip capabilities after null byte (first line has \0capabilities)
        v_null_pos := position('\x00'::bytea in v_line_bytes);
        if v_null_pos > 0 then
            v_line_bytes := substring(v_line_bytes from 1 for v_null_pos - 1);
        end if;

        v_line := convert_from(v_line_bytes, 'UTF8');
        v_line := rtrim(v_line, E'\n');

        -- Format: "<old-oid> <new-oid> <ref-name>"
        old_oid := decode(substring(v_line from 1 for 40), 'hex');
        new_oid := decode(substring(v_line from 42 for 40), 'hex');
        ref_name := substring(v_line from 83);
        packfile_offset := null;

        return next;

        v_pos := v_pos + v_pkt_len;
    end loop;

    -- If we get here without a flush, packfile starts at current position
    packfile_offset := v_pos;
    old_oid := null;
    new_oid := null;
    ref_name := null;
    return next;
end;
$$;

-- Apply ref updates and unpack objects from a receive-pack request.
create function apply_receive_pack(p_repo_id integer, p_body bytea)
returns bytea
language plpgsql as $$
declare
    v_cmd record;
    v_packfile_offset integer;
    v_packfile bytea;
    v_unpack_count integer;
    v_ok boolean;
    v_result bytea;
    v_status_lines bytea := ''::bytea;
    v_unpack_status text := 'unpack ok';
begin
    -- Collect commands and find packfile offset
    for v_cmd in select * from omni_git.parse_receive_pack_commands(p_body) loop
        if v_cmd.packfile_offset is not null then
            v_packfile_offset := v_cmd.packfile_offset;
        end if;
    end loop;

    -- Unpack the packfile first (objects must exist before refs point to them)
    if v_packfile_offset is not null and v_packfile_offset <= octet_length(p_body) then
        v_packfile := substring(p_body from v_packfile_offset);
        if octet_length(v_packfile) > 0 then
            begin
                v_unpack_count := omni_git.unpack_packfile(p_repo_id, v_packfile);
            exception when others then
                v_unpack_status := 'unpack ' || sqlerrm;
            end;
        end if;
    end if;

    -- Now apply ref updates
    for v_cmd in select * from omni_git.parse_receive_pack_commands(p_body) loop
        if v_cmd.ref_name is not null then
            v_ok := omni_git.ref_update(p_repo_id, v_cmd.ref_name, v_cmd.new_oid, v_cmd.old_oid);

            if v_ok then
                v_status_lines := v_status_lines || omni_git.pkt_line('ok ' || v_cmd.ref_name || E'\n');
            else
                v_status_lines := v_status_lines || omni_git.pkt_line('ng ' || v_cmd.ref_name || ' failed' || E'\n');
            end if;
        end if;
    end loop;

    v_result := omni_git.pkt_line(v_unpack_status || E'\n')
             || v_status_lines
             || omni_git.pkt_flush();

    return v_result;
end;
$$;
