-- Encode a single line as a pkt-line (4-byte hex length prefix + data)
create function pkt_line(data bytea)
returns bytea
language sql immutable strict as $$
    select convert_to(lpad(to_hex(octet_length(data) + 4), 4, '0'), 'UTF8') || data;
$$;

-- Text convenience wrapper
create function pkt_line(data text)
returns bytea
language sql immutable strict as $$
    select omni_git.pkt_line(convert_to(data, 'UTF8'));
$$;

-- Flush packet
create function pkt_flush()
returns bytea
language sql immutable as $$
    select '\x30303030'::bytea; -- "0000"
$$;

-- Delimiter packet (protocol v2)
create function pkt_delim()
returns bytea
language sql immutable as $$
    select '\x30303031'::bytea; -- "0001"
$$;

-- Parse pkt-line stream into individual lines
-- Returns each line's raw bytes (without the length prefix)
create function pkt_line_decode(data bytea)
returns table(line bytea, is_flush boolean)
language plpgsql immutable strict as $$
declare
    v_pos integer := 1;
    v_len integer;
    v_pkt_len integer;
    v_hex text;
begin
    v_len := octet_length(data);

    while v_pos + 3 <= v_len loop
        v_hex := convert_from(substring(data from v_pos for 4), 'UTF8');

        if v_hex = '0000' then
            line := null;
            is_flush := true;
            return next;
            v_pos := v_pos + 4;
            continue;
        end if;

        if v_hex = '0001' then
            -- delimiter packet, skip
            v_pos := v_pos + 4;
            continue;
        end if;

        v_pkt_len := ('x' || v_hex)::bit(16)::integer;

        if v_pkt_len < 4 then
            exit;
        end if;

        line := substring(data from v_pos + 4 for v_pkt_len - 4);
        is_flush := false;
        return next;

        v_pos := v_pos + v_pkt_len;
    end loop;
end;
$$;

-- Format ref advertisement for /info/refs response
create function ref_advertisement(p_repo_id integer, p_service text)
returns bytea
language plpgsql stable as $$
declare
    v_result bytea;
    v_first boolean := true;
    v_ref record;
    v_line text;
    v_capabilities text;
begin
    v_result := omni_git.pkt_line('# service=' || p_service || E'\n')
             || omni_git.pkt_flush();

    v_capabilities := 'report-status delete-refs ofs-delta';

    for v_ref in
        select r.name, encode(r.oid, 'hex') as hex_oid
        from public.refs r
        where r.repo_id = p_repo_id and r.oid is not null
        order by r.name
    loop
        if v_first then
            v_result := v_result || omni_git.pkt_line(
                convert_to(v_ref.hex_oid || ' ' || v_ref.name, 'UTF8')
                || '\x00'::bytea
                || convert_to(v_capabilities || E'\n', 'UTF8')
            );
            v_first := false;
        else
            v_result := v_result || omni_git.pkt_line(v_ref.hex_oid || ' ' || v_ref.name || E'\n');
        end if;
    end loop;

    -- Empty repo: send zero-id with capabilities
    if v_first then
        v_result := v_result || omni_git.pkt_line(
            convert_to(repeat('0', 40) || ' capabilities^{}', 'UTF8')
            || '\x00'::bytea
            || convert_to(v_capabilities || E'\n', 'UTF8')
        );
    end if;

    v_result := v_result || omni_git.pkt_flush();

    return v_result;
end;
$$;
