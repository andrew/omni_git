/*
 * omni_git.c -- Postgres C extension for git packfile operations
 *
 * Provides:
 *   unpack_packfile(repo_id, data) -- unpack received packfile into objects table
 *   generate_packfile(repo_id, oids bytea[]) -- generate packfile from stored objects
 */

#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/array.h"

#include <git2.h>
#include <zlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <arpa/inet.h>

/* SHA1 from OpenSSL */
#include <openssl/evp.h>

PG_MODULE_MAGIC;

void _PG_init(void);

void
_PG_init(void)
{
    git_libgit2_init();
}

/* Insert a single object into omni_git.objects via SPI */
static int
insert_object(int repo_id, const git_oid *oid, const void *data,
              size_t size, git_object_t type)
{
    int         ret;
    Oid         argtypes[5] = {INT4OID, BYTEAOID, INT2OID, INT4OID, BYTEAOID};
    Datum       values[5];
    bytea      *oid_bytea;
    bytea      *content_bytea;
    int16       type_val;
    int32       size_val;

    /* Build OID bytea (20 bytes) */
    oid_bytea = (bytea *) palloc(GIT_OID_RAWSZ + VARHDRSZ);
    SET_VARSIZE(oid_bytea, GIT_OID_RAWSZ + VARHDRSZ);
    memcpy(VARDATA(oid_bytea), oid->id, GIT_OID_RAWSZ);

    /* Build content bytea */
    content_bytea = (bytea *) palloc(size + VARHDRSZ);
    SET_VARSIZE(content_bytea, size + VARHDRSZ);
    memcpy(VARDATA(content_bytea), data, size);

    type_val = (int16) type;
    size_val = (int32) size;

    values[0] = Int32GetDatum(repo_id);
    values[1] = PointerGetDatum(oid_bytea);
    values[2] = Int16GetDatum(type_val);
    values[3] = Int32GetDatum(size_val);
    values[4] = PointerGetDatum(content_bytea);

    ret = SPI_execute_with_args(
        "INSERT INTO omni_git.objects (repo_id, oid, type, size, content) "
        "VALUES ($1, $2, $3, $4, $5) "
        "ON CONFLICT (repo_id, oid) DO NOTHING",
        5, argtypes, values, NULL, false, 0);

    pfree(oid_bytea);
    pfree(content_bytea);

    return (ret == SPI_OK_INSERT) ? 0 : -1;
}

/* Callback for git_odb_foreach: copy each object from pack ODB to Postgres */
typedef struct {
    git_odb    *pack_odb;
    int         repo_id;
    int         count;
    int         errors;
} copy_ctx;

static int
copy_object_cb(const git_oid *oid, void *payload)
{
    copy_ctx       *ctx = (copy_ctx *) payload;
    git_odb_object *obj = NULL;
    int             error;

    error = git_odb_read(&obj, ctx->pack_odb, oid);
    if (error < 0)
        return error;

    error = insert_object(
        ctx->repo_id,
        oid,
        git_odb_object_data(obj),
        git_odb_object_size(obj),
        git_odb_object_type(obj));

    git_odb_object_free(obj);

    if (error == 0)
        ctx->count++;
    else
        ctx->errors++;

    return 0;
}

/* Recursively remove a directory */
static void
rmdir_recursive(const char *path)
{
    char cmd[1280];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", path);
    (void) system(cmd);
}

PG_FUNCTION_INFO_V1(omni_git_unpack_packfile);

/*
 * unpack_packfile(repo_id integer, packdata bytea) returns integer
 *
 * Takes raw packfile bytes (the PACK... data that follows the ref commands
 * in a git-receive-pack request), unpacks using libgit2's indexer, and
 * inserts all objects into omni_git.objects. Returns the number of objects
 * unpacked.
 */
Datum
omni_git_unpack_packfile(PG_FUNCTION_ARGS)
{
    int32       repo_id = PG_GETARG_INT32(0);
    bytea      *packdata = PG_GETARG_BYTEA_PP(1);
    char       *data = VARDATA_ANY(packdata);
    int         data_len = VARSIZE_ANY_EXHDR(packdata);

    char        tmpdir[] = "/tmp/omni-git-unpack-XXXXXX";
    char        packdir[256];
    char        idx_path[1024];

    git_indexer *indexer = NULL;
    git_indexer_progress stats = {0};
    git_indexer_options opts = {0};
    git_odb    *pack_odb = NULL;
    git_odb_backend *pack_backend = NULL;
    const char *pack_name;
    int         error;
    copy_ctx    ctx;

    /* Create temp directory for indexer */
    if (!mkdtemp(tmpdir))
        ereport(ERROR,
                (errmsg("omni_git: failed to create temp directory")));

    snprintf(packdir, sizeof(packdir), "%s/pack", tmpdir);
    if (mkdir(packdir, 0700) < 0)
    {
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: failed to create pack subdirectory")));
    }

    /* Index the packfile */
    opts.version = GIT_INDEXER_OPTIONS_VERSION;

    error = git_indexer_new(&indexer, packdir, 0, NULL, &opts);
    if (error < 0)
    {
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_indexer_new failed: %s",
                        git_error_last()->message)));
    }

    error = git_indexer_append(indexer, data, data_len, &stats);
    if (error < 0)
    {
        git_indexer_free(indexer);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_indexer_append failed: %s",
                        git_error_last()->message)));
    }

    error = git_indexer_commit(indexer, &stats);
    if (error < 0)
    {
        git_indexer_free(indexer);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_indexer_commit failed: %s",
                        git_error_last()->message)));
    }

    pack_name = git_indexer_name(indexer);
    if (!pack_name)
    {
        git_indexer_free(indexer);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: indexer produced no packfile name")));
    }

    snprintf(idx_path, sizeof(idx_path), "%s/pack/pack-%s.idx", tmpdir, pack_name);

    git_indexer_free(indexer);
    indexer = NULL;

    /* Open the pack as an ODB to iterate objects */
    error = git_odb_new(&pack_odb);
    if (error < 0)
    {
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_odb_new failed: %s",
                        git_error_last()->message)));
    }

    error = git_odb_backend_one_pack(&pack_backend, idx_path);
    if (error < 0)
    {
        git_odb_free(pack_odb);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_odb_backend_one_pack failed: %s",
                        git_error_last()->message)));
    }

    error = git_odb_add_backend(pack_odb, pack_backend, 1);
    if (error < 0)
    {
        git_odb_free(pack_odb);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: git_odb_add_backend failed: %s",
                        git_error_last()->message)));
    }

    /* Copy all objects from pack into Postgres */
    if (SPI_connect() != SPI_OK_CONNECT)
    {
        git_odb_free(pack_odb);
        rmdir_recursive(tmpdir);
        ereport(ERROR,
                (errmsg("omni_git: SPI_connect failed")));
    }

    ctx.pack_odb = pack_odb;
    ctx.repo_id = repo_id;
    ctx.count = 0;
    ctx.errors = 0;

    error = git_odb_foreach(pack_odb, copy_object_cb, &ctx);

    SPI_finish();
    git_odb_free(pack_odb);
    rmdir_recursive(tmpdir);

    if (error < 0)
        ereport(ERROR,
                (errmsg("omni_git: git_odb_foreach failed: %s",
                        git_error_last()->message)));

    if (ctx.errors > 0)
        ereport(WARNING,
                (errmsg("omni_git: %d objects failed to insert", ctx.errors)));

    PG_RETURN_INT32(ctx.count);
}

/*
 * Growable byte buffer for building packfiles in memory.
 */
typedef struct {
    char   *data;
    size_t  len;
    size_t  cap;
} packbuf;

static void
packbuf_init(packbuf *buf)
{
    buf->cap = 8192;
    buf->data = palloc(buf->cap);
    buf->len = 0;
}

static void
packbuf_append(packbuf *buf, const void *data, size_t len)
{
    while (buf->len + len > buf->cap)
    {
        buf->cap *= 2;
        buf->data = repalloc(buf->data, buf->cap);
    }
    memcpy(buf->data + buf->len, data, len);
    buf->len += len;
}

/*
 * Encode the pack object header: type (3 bits) + size (variable length).
 * Returns number of bytes written to out (max 10).
 */
static int
encode_pack_obj_header(unsigned char *out, int type, size_t size)
{
    int         i = 0;
    unsigned char c;

    c = (type << 4) | (size & 0x0F);
    size >>= 4;

    while (size > 0)
    {
        c |= 0x80;
        out[i++] = c;
        c = size & 0x7F;
        size >>= 7;
    }

    out[i++] = c;
    return i;
}

PG_FUNCTION_INFO_V1(omni_git_generate_packfile);

/*
 * generate_packfile(repo_id integer, oids bytea[]) returns bytea
 *
 * Reads the requested objects from omni_git.objects and produces a valid
 * git packfile (version 2, no delta compression). Each object is stored
 * as type+size header followed by zlib-compressed raw content.
 */
Datum
omni_git_generate_packfile(PG_FUNCTION_ARGS)
{
    int32           repo_id = PG_GETARG_INT32(0);
    ArrayType      *oid_array = PG_GETARG_ARRAYTYPE_P(1);
    Datum          *oid_datums;
    bool           *oid_nulls;
    int             oid_count;
    packbuf         buf;
    uint32_t        net_val;
    unsigned char   obj_header[10];
    int             obj_header_len;
    int             i, ret;
    EVP_MD_CTX     *sha_ctx;
    unsigned char   sha_result[20];
    unsigned int    sha_len;
    bytea          *result;

    deconstruct_array(oid_array, BYTEAOID, -1, false, TYPALIGN_INT,
                      &oid_datums, &oid_nulls, &oid_count);

    packbuf_init(&buf);

    /* Pack header: "PACK" + version 2 + object count */
    packbuf_append(&buf, "PACK", 4);
    net_val = htonl(2);
    packbuf_append(&buf, &net_val, 4);
    net_val = htonl((uint32_t) oid_count);
    packbuf_append(&buf, &net_val, 4);

    /* Connect to SPI to read objects */
    if (SPI_connect() != SPI_OK_CONNECT)
        ereport(ERROR, (errmsg("omni_git: SPI_connect failed")));

    for (i = 0; i < oid_count; i++)
    {
        bytea      *oid_bytea;
        Oid         argtypes[2] = {INT4OID, BYTEAOID};
        Datum       args[2];
        int16       obj_type;
        int32       obj_size;
        char       *obj_content;
        int         obj_content_len;
        unsigned char *compressed;
        uLongf      compressed_len;

        if (oid_nulls[i])
            continue;

        oid_bytea = DatumGetByteaPP(oid_datums[i]);

        args[0] = Int32GetDatum(repo_id);
        args[1] = PointerGetDatum(oid_bytea);

        ret = SPI_execute_with_args(
            "SELECT type, size, content FROM omni_git.objects "
            "WHERE repo_id = $1 AND oid = $2",
            2, argtypes, args, NULL, true, 1);

        if (ret != SPI_OK_SELECT || SPI_processed == 0)
        {
            elog(WARNING, "omni_git: object not found, skipping");
            continue;
        }

        obj_type = DatumGetInt16(SPI_getbinval(SPI_tuptable->vals[0],
                                               SPI_tuptable->tupdesc, 1, &oid_nulls[0]));
        obj_size = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0],
                                               SPI_tuptable->tupdesc, 2, &oid_nulls[0]));

        {
            bytea *content_bytea = DatumGetByteaPP(
                SPI_getbinval(SPI_tuptable->vals[0],
                              SPI_tuptable->tupdesc, 3, &oid_nulls[0]));
            obj_content = VARDATA_ANY(content_bytea);
            obj_content_len = VARSIZE_ANY_EXHDR(content_bytea);
        }

        /* Encode type+size header */
        obj_header_len = encode_pack_obj_header(obj_header, obj_type, obj_size);
        packbuf_append(&buf, obj_header, obj_header_len);

        /* Zlib compress the content */
        compressed_len = compressBound(obj_content_len);
        compressed = palloc(compressed_len);

        if (compress2(compressed, &compressed_len,
                      (const Bytef *) obj_content, obj_content_len,
                      Z_DEFAULT_COMPRESSION) != Z_OK)
        {
            pfree(compressed);
            SPI_finish();
            ereport(ERROR, (errmsg("omni_git: zlib compress failed")));
        }

        packbuf_append(&buf, compressed, compressed_len);
        pfree(compressed);
    }

    SPI_finish();

    /* SHA1 checksum over entire pack */
    sha_ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(sha_ctx, EVP_sha1(), NULL);
    EVP_DigestUpdate(sha_ctx, buf.data, buf.len);
    EVP_DigestFinal_ex(sha_ctx, sha_result, &sha_len);
    EVP_MD_CTX_free(sha_ctx);

    packbuf_append(&buf, sha_result, 20);

    /* Return as bytea */
    result = (bytea *) palloc(buf.len + VARHDRSZ);
    SET_VARSIZE(result, buf.len + VARHDRSZ);
    memcpy(VARDATA(result), buf.data, buf.len);

    pfree(buf.data);

    PG_RETURN_BYTEA_P(result);
}
