-- HTTP handlers require omni_httpd and omni_http extensions.
-- Skip if not available.
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'omni_httpd') then
        raise notice 'omni_httpd not installed, skipping HTTP handler setup';
        return;
    end if;

    -- Create the handler functions dynamically so they don't fail
    -- at extension creation time when omni_httpd isn't present
    execute $sql$
/*{% include "../src/http_handlers.sql" %}*/
    $sql$;
end;
$$;
