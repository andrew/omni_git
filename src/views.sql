create materialized view commits_view as
select o.repo_id, o.oid as commit_oid, encode(o.oid, 'hex') as sha,
       c.tree_oid, c.parent_oids, c.author_name, c.author_email,
       to_timestamp(c.author_timestamp) as authored_at,
       c.committer_name, c.committer_email,
       to_timestamp(c.committer_timestamp) as committed_at,
       c.message
from omni_git.objects o, lateral omni_git.commit_parse(o.content) c
where o.type = 1;

create unique index idx_commits_view_oid on omni_git.commits_view (repo_id, commit_oid);

create materialized view tree_entries_view as
select o.repo_id, o.oid as tree_oid, e.mode, e.name, e.entry_oid
from omni_git.objects o, lateral omni_git.tree_entries(o.content) e
where o.type = 2;

create index idx_tree_entries_view_oid on omni_git.tree_entries_view (repo_id, tree_oid);
