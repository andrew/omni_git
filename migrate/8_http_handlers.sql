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

    -- Create router table for omni_httpd auto-discovery
    execute $sql$
    create table if not exists omni_git.router (like omni_httpd.urlpattern_router);
    $sql$;

    -- Register git smart HTTP routes
    execute $sql$
    insert into omni_git.router (match, handler) values
        (omni_httpd.urlpattern(pathname => '/:repo/info/refs'),
         'omni_git.http_info_refs'::regproc),
        (omni_httpd.urlpattern(pathname => '/:repo/git-receive-pack', method => 'POST'),
         'omni_git.http_receive_pack'::regproc),
        (omni_httpd.urlpattern(pathname => '/:repo/git-upload-pack', method => 'POST'),
         'omni_git.http_upload_pack'::regproc)
    on conflict do nothing;
    $sql$;

    -- Refresh router discovery so omni_httpd picks up the new table
    execute $sql$
    refresh materialized view omni_httpd.available_routers;
    $sql$;
end;
$outer$;
