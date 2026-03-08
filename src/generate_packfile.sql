create function generate_packfile(repo_id integer, oids bytea[])
returns bytea
as 'MODULE_PATHNAME', 'omni_git_generate_packfile'
language c;

-- Collect all objects reachable from a set of commit OIDs.
-- Walks commits, trees, and blobs recursively.
create function reachable_objects(
    p_repo_id integer,
    p_commit_oids bytea[]
)
returns table(oid bytea)
language plpgsql stable as $$
declare
    v_commit_oid bytea;
    v_tree_oid bytea;
    v_content bytea;
    v_seen bytea[] := '{}';
begin
    foreach v_commit_oid in array p_commit_oids loop
        -- Skip if already visited
        if v_commit_oid = any(v_seen) then
            continue;
        end if;
        v_seen := v_seen || v_commit_oid;

        select content into v_content
        from omni_git.objects o
        where o.repo_id = p_repo_id and o.oid = v_commit_oid and o.type = 1;

        if v_content is null then
            continue;
        end if;

        oid := v_commit_oid;
        return next;

        -- Get tree OID from commit
        select c.tree_oid into v_tree_oid
        from omni_git.commit_parse(v_content) c;

        -- Walk the tree recursively, collecting all objects
        if not (v_tree_oid = any(v_seen)) then
            v_seen := v_seen || v_tree_oid;
            oid := v_tree_oid;
            return next;

            -- Collect all tree entries recursively
            for oid in
                select t.oid
                from omni_git.ls_tree_r(p_repo_id, v_tree_oid) t
                where not (t.oid = any(v_seen))
            loop
                v_seen := v_seen || oid;
                return next;
            end loop;
        end if;

        -- Walk parent commits
        declare
            v_parents bytea[];
            v_parent bytea;
        begin
            select c.parent_oids into v_parents
            from omni_git.commit_parse(v_content) c;

            if v_parents is not null then
                foreach v_parent in array v_parents loop
                    if not (v_parent = any(v_seen)) then
                        for oid in
                            select * from omni_git.reachable_objects(p_repo_id, array[v_parent])
                            where not (reachable_objects.oid = any(v_seen))
                        loop
                            v_seen := v_seen || oid;
                            return next;
                        end loop;
                    end if;
                end loop;
            end if;
        end;
    end loop;
end;
$$;
