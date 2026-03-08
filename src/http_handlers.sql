-- HTTP handler for GET /:repo/info/refs?service=git-receive-pack
-- Returns ref advertisement in smart HTTP format
create function http_info_refs(request omni_httpd.http_request)
returns omni_httpd.http_outcome
language plpgsql as $$
declare
    v_repo_name text;
    v_service text;
    v_repo_id integer;
    v_body bytea;
    v_content_type text;
    v_path_parts text[];
begin
    -- Extract repo name from path: /<repo>/info/refs
    v_path_parts := string_to_array(trim(leading '/' from request.path), '/');
    if array_length(v_path_parts, 1) < 3 then
        return omni_httpd.http_response(status => 404);
    end if;
    v_repo_name := v_path_parts[1];

    -- Extract service from query string
    v_service := null;
    if request.query_string like '%service=git-receive-pack%' then
        v_service := 'git-receive-pack';
    elsif request.query_string like '%service=git-upload-pack%' then
        v_service := 'git-upload-pack';
    end if;

    if v_service is null then
        return omni_httpd.http_response(status => 403);
    end if;

    select id into v_repo_id from public.repositories where name = v_repo_name;
    if v_repo_id is null then
        return omni_httpd.http_response(status => 404);
    end if;

    v_body := omni_git.ref_advertisement(v_repo_id, v_service);
    v_content_type := 'application/x-' || v_service || '-advertisement';

    return omni_httpd.http_response(
        status => 200,
        headers => array[
            omni_http.http_header('Content-Type', v_content_type),
            omni_http.http_header('Cache-Control', 'no-cache')
        ],
        body => v_body
    );
end;
$$;

-- HTTP handler for POST /:repo/git-receive-pack
-- Accepts pushed objects and ref updates
create function http_receive_pack(request omni_httpd.http_request)
returns omni_httpd.http_outcome
language plpgsql as $$
declare
    v_repo_name text;
    v_repo_id integer;
    v_result bytea;
    v_path_parts text[];
begin
    -- Extract repo name from path: /<repo>/git-receive-pack
    v_path_parts := string_to_array(trim(leading '/' from request.path), '/');
    if array_length(v_path_parts, 1) < 2 then
        return omni_httpd.http_response(status => 404);
    end if;
    v_repo_name := v_path_parts[1];

    select id into v_repo_id from public.repositories where name = v_repo_name;
    if v_repo_id is null then
        return omni_httpd.http_response(status => 404);
    end if;

    v_result := omni_git.apply_receive_pack(v_repo_id, request.body);

    return omni_httpd.http_response(
        status => 200,
        headers => array[
            omni_http.http_header('Content-Type', 'application/x-git-receive-pack-result'),
            omni_http.http_header('Cache-Control', 'no-cache')
        ],
        body => v_result
    );
end;
$$;

-- HTTP handler for POST /:repo/git-upload-pack
-- Serves objects for clone/fetch
create function http_upload_pack(request omni_httpd.http_request)
returns omni_httpd.http_outcome
language plpgsql as $$
declare
    v_repo_name text;
    v_repo_id integer;
    v_result bytea;
    v_path_parts text[];
begin
    v_path_parts := string_to_array(trim(leading '/' from request.path), '/');
    if array_length(v_path_parts, 1) < 2 then
        return omni_httpd.http_response(status => 404);
    end if;
    v_repo_name := v_path_parts[1];

    select id into v_repo_id from public.repositories where name = v_repo_name;
    if v_repo_id is null then
        return omni_httpd.http_response(status => 404);
    end if;

    v_result := omni_git.apply_upload_pack(v_repo_id, request.body);

    return omni_httpd.http_response(
        status => 200,
        headers => array[
            omni_http.http_header('Content-Type', 'application/x-git-upload-pack-result'),
            omni_http.http_header('Cache-Control', 'no-cache')
        ],
        body => v_result
    );
end;
$$;
