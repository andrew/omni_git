-- HTTP handlers require omni_httpd and omni_http extensions.
-- Skip if not available.
do $outer$
begin
    if not exists (select 1 from pg_extension where extname = 'omni_httpd') then
        raise notice 'omni_httpd not installed, skipping HTTP handler setup';
        return;
    end if;

    execute $sql$
/*{% include "../src/http_handlers.sql" %}*/
    $sql$;
end;
$outer$;
