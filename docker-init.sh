#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'SQL'
    CREATE EXTENSION IF NOT EXISTS omni_git CASCADE;

    -- Create a demo repository
    INSERT INTO repositories (name) VALUES ('demo')
    ON CONFLICT DO NOTHING;

    -- Set up auto-deploy on push to main
    INSERT INTO omni_git.deploy_config (repo_id, branch)
    SELECT id, 'refs/heads/main' FROM repositories WHERE name = 'demo'
    ON CONFLICT DO NOTHING;
SQL

echo ""
echo "========================================="
echo "  omni_git is ready"
echo ""
echo "  Push to:  http://localhost:8080/demo"
echo "  Clone:    git clone http://localhost:8080/demo"
echo ""
echo "  psql -U omnigres -d omnigres"
echo "========================================="
echo ""
