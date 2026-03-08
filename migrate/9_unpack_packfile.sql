create function unpack_packfile(repo_id integer, packdata bytea)
returns integer
as 'MODULE_PATHNAME', 'omni_git_unpack_packfile'
language c;
