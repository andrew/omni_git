-- Parse want/have lines from an upload-pack request body.
-- Returns the wanted OIDs and the common OIDs the client already has.
create function parse_upload_pack_request(p_body bytea)
returns table(want_oid bytea, have_oid bytea)
language plpgsql immutable strict as $$
declare
    v_pos integer := 1;
    v_len integer;
    v_pkt_len integer;
    v_hex text;
    v_line text;
begin
    v_len := octet_length(p_body);

    while v_pos + 3 <= v_len loop
        v_hex := convert_from(substring(p_body from v_pos for 4), 'UTF8');

        if v_hex = '0000' then
            v_pos := v_pos + 4;
            -- After flush in upload-pack, check for "done"
            if v_pos + 3 <= v_len then
                -- Could be more packets or "done"
                continue;
            end if;
            return;
        end if;

        v_pkt_len := ('x' || v_hex)::bit(16)::integer;
        if v_pkt_len < 4 then
            exit;
        end if;

        v_line := convert_from(substring(p_body from v_pos + 4 for v_pkt_len - 4), 'UTF8');
        v_line := rtrim(v_line, E'\n');

        -- Strip capabilities from first want line
        if position(E'\0' in v_line) > 0 then
            v_line := substring(v_line from 1 for position(E'\0' in v_line) - 1);
        end if;

        if v_line like 'want %' then
            want_oid := decode(substring(v_line from 6 for 40), 'hex');
            have_oid := null;
            return next;
        elsif v_line like 'have %' then
            want_oid := null;
            have_oid := decode(substring(v_line from 6 for 40), 'hex');
            return next;
        end if;
        -- "done" line signals end of negotiation

        v_pos := v_pos + v_pkt_len;
    end loop;
end;
$$;

-- Handle an upload-pack request: collect wanted objects and generate a packfile.
-- Simple implementation: sends all reachable objects from wanted commits,
-- minus any objects reachable from "have" commits.
create function apply_upload_pack(p_repo_id integer, p_body bytea)
returns bytea
language plpgsql as $$
declare
    v_wants bytea[];
    v_haves bytea[];
    v_oids bytea[];
    v_packfile bytea;
    v_result bytea;
begin
    -- Collect want and have OIDs
    select
        coalesce(array_agg(want_oid) filter (where want_oid is not null), '{}'),
        coalesce(array_agg(have_oid) filter (where have_oid is not null), '{}')
    into v_wants, v_haves
    from omni_git.parse_upload_pack_request(p_body);

    if array_length(v_wants, 1) is null then
        return omni_git.pkt_line('NAK' || E'\n') || omni_git.pkt_flush();
    end if;

    -- Get all reachable objects from wants, excluding those reachable from haves
    if array_length(v_haves, 1) is not null then
        select array_agg(r.oid) into v_oids
        from omni_git.reachable_objects(p_repo_id, v_wants) r
        where r.oid not in (
            select h.oid from omni_git.reachable_objects(p_repo_id, v_haves) h
        );
    else
        select array_agg(r.oid) into v_oids
        from omni_git.reachable_objects(p_repo_id, v_wants) r;
    end if;

    if v_oids is null or array_length(v_oids, 1) is null then
        return omni_git.pkt_line('NAK' || E'\n') || omni_git.pkt_flush();
    end if;

    v_packfile := omni_git.generate_packfile(p_repo_id, v_oids);

    -- Response: NAK + packfile data
    v_result := omni_git.pkt_line('NAK' || E'\n') || v_packfile;

    return v_result;
end;
$$;
