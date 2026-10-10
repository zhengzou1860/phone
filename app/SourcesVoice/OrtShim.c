#include "OrtShim.h"
#include "onnxruntime_c_api.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 报错走线程局部缓冲：推理只在一条线程上跑，但 Swift 侧随时可能读，别用共享全局。 */
static _Thread_local char g_msg[512] = "";

static void note(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_msg, sizeof(g_msg), fmt, ap);
    va_end(ap);
}

const char *ortshim_last_error(void)
{
    return g_msg;
}

struct OrtshimEngine {
    const OrtApi *api;
    OrtEnv *env;
    OrtMemoryInfo *mem;
    OrtSessionOptions *opts;
    OrtAllocator *alloc;
};

struct OrtshimGraph {
    OrtshimEngine *eng;
    OrtSession *sess;
    char **names_in;
    int n_in;
    char **names_out;
    int n_out;
};

/* ORT 的每个调用都返回 OrtStatus*，NULL 才是成功。这里统一转成 0/1 并把文案抄进 g_msg。 */
static int chk(OrtshimEngine *e, OrtStatus *st, const char *what)
{
    const char *m;
    if (st == NULL) return 0;
    /* GetErrorMessage 的返回值在 ReleaseStatus 之后就失效，note 当场抄走。 */
    m = e->api->GetErrorMessage(st);
    note("%s: %s", what, m ? m : "(没有文案)");
    e->api->ReleaseStatus(st);
    return 1;
}

OrtshimEngine *ortshim_open(int intra_threads, int log_level)
{
    const OrtApiBase *base;
    const OrtApi *api;
    OrtshimEngine *e;
    OrtLoggingLevel lv;

    g_msg[0] = '\0';
    base = OrtGetApiBase();
    if (base == NULL) { note("OrtGetApiBase() 返回空"); return NULL; }
    api = base->GetApi(ORT_API_VERSION);
    if (api == NULL) {
        note("GetApi(%u) 返回空：链接进来的 ORT 二进制和头文件的 API 版本不一致",
             (unsigned)ORT_API_VERSION);
        return NULL;
    }
    e = (OrtshimEngine *)calloc(1, sizeof(*e));
    if (e == NULL) { note(" calloc 失败"); return NULL; }
    e->api = api;

    switch (log_level) {
    case 0: lv = ORT_LOGGING_LEVEL_VERBOSE; break;
    case 1: lv = ORT_LOGGING_LEVEL_INFO;    break;
    case 3: lv = ORT_LOGGING_LEVEL_ERROR;   break;
    case 4: lv = ORT_LOGGING_LEVEL_FATAL;   break;
    default: lv = ORT_LOGGING_LEVEL_WARNING; break;
    }

    if (chk(e, api->CreateEnv(lv, "voice", &e->env), "CreateEnv")) goto fail;
    if (chk(e, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &e->mem),
            "CreateCpuMemoryInfo")) goto fail;
    if (chk(e, api->CreateSessionOptions(&e->opts), "CreateSessionOptions")) goto fail;
    if (intra_threads > 0 &&
        chk(e, api->SetIntraOpNumThreads(e->opts, intra_threads), "SetIntraOpNumThreads")) goto fail;
    if (chk(e, api->SetInterOpNumThreads(e->opts, 1), "SetInterOpNumThreads")) goto fail;
    /* 拿默认 allocator 只为了 SessionGetInputName/OutputName 那一块临时内存。 */
    if (chk(e, api->GetAllocatorWithDefaultOptions(&e->alloc), "GetAllocatorWithDefaultOptions")) goto fail;
    return e;

fail:
    if (e->opts) api->ReleaseSessionOptions(e->opts);
    if (e->mem)  api->ReleaseMemoryInfo(e->mem);
    if (e->env)  api->ReleaseEnv(e->env);
    free(e);
    return NULL;
}

void ortshim_close(OrtshimEngine *engine)
{
    const OrtApi *api;
    if (engine == NULL) return;
    api = engine->api;
    /* alloc 是 ORT 自己的默认 allocator，不归我们释放。 */
    if (engine->opts) api->ReleaseSessionOptions(engine->opts);
    if (engine->mem)  api->ReleaseMemoryInfo(engine->mem);
    if (engine->env)  api->ReleaseEnv(engine->env);
    free(engine);
}

OrtshimGraph *ortshim_load(OrtshimEngine *e, const char *path_utf8)
{
    const OrtApi *api;
    OrtshimGraph *g;
    size_t ni = 0, no = 0, i;
    OrtSession *sess = NULL;

    g_msg[0] = '\0';
    if (e == NULL) { note("engine 是空的"); return NULL; }
    if (path_utf8 == NULL) { note("路径是空的"); return NULL; }
    api = e->api;

    if (chk(e, api->CreateSession(e->env, path_utf8, e->opts, &sess), "CreateSession")) return NULL;

    g = (OrtshimGraph *)calloc(1, sizeof(*g));
    if (g == NULL) { note("calloc 失败"); api->ReleaseSession(sess); return NULL; }
    g->eng = e;
    g->sess = sess;

    if (chk(e, api->SessionGetInputCount(sess, &ni), "SessionGetInputCount")) goto fail;
    if (chk(e, api->SessionGetOutputCount(sess, &no), "SessionGetOutputCount")) goto fail;
    g->n_in = (int)ni;
    g->n_out = (int)no;
    g->names_in = (char **)calloc(ni > 0 ? ni : 1, sizeof(char *));
    g->names_out = (char **)calloc(no > 0 ? no : 1, sizeof(char *));
    if (g->names_in == NULL || g->names_out == NULL) { note("calloc 名字表失败"); goto fail; }

    for (i = 0; i < ni; i++) {
        char *nm = NULL;
        if (chk(e, api->SessionGetInputName(sess, i, e->alloc, &nm), "SessionGetInputName")) goto fail;
        if (nm == NULL) { note("第 %u 个输入的指针是空", (unsigned)i); goto fail; }
        g->names_in[i] = strdup(nm);
        api->AllocatorFree(e->alloc, nm);
        if (g->names_in[i] == NULL) { note("strdup 输入名失败"); goto fail; }
    }
    for (i = 0; i < no; i++) {
        char *nm = NULL;
        if (chk(e, api->SessionGetOutputName(sess, i, e->alloc, &nm), "SessionGetOutputName")) goto fail;
        if (nm == NULL) { note("第 %u 个输出的指针是空", (unsigned)i); goto fail; }
        g->names_out[i] = strdup(nm);
        api->AllocatorFree(e->alloc, nm);
        if (g->names_out[i] == NULL) { note("strdup 输出名失败"); goto fail; }
    }
    return g;

fail:
    ortshim_unload(g);
    return NULL;
}

void ortshim_unload(OrtshimGraph *graph)
{
    int i;
    if (graph == NULL) return;
    if (graph->sess) graph->eng->api->ReleaseSession(graph->sess);
    if (graph->names_in) {
        for (i = 0; i < graph->n_in; i++) free(graph->names_in[i]);
        free(graph->names_in);
    }
    if (graph->names_out) {
        for (i = 0; i < graph->n_out; i++) free(graph->names_out[i]);
        free(graph->names_out);
    }
    free(graph);
}

int ortshim_input_count(const OrtshimGraph *graph)
{
    return graph ? graph->n_in : -1;
}

int ortshim_output_count(const OrtshimGraph *graph)
{
    return graph ? graph->n_out : -1;
}

const char *ortshim_input_name(const OrtshimGraph *graph, int index)
{
    if (graph == NULL || index < 0 || index >= graph->n_in) return NULL;
    return graph->names_in[index];
}

const char *ortshim_output_name(const OrtshimGraph *graph, int index)
{
    if (graph == NULL || index < 0 || index >= graph->n_out) return NULL;
    return graph->names_out[index];
}

static size_t elem_size(int dtype)
{
    return dtype == ORTSHIM_F32 ? (size_t)4 : (dtype == ORTSHIM_I64 ? (size_t)8 : (size_t)0);
}

void ortshim_release(OrtshimFetch *outs, int n)
{
    int i;
    if (outs == NULL) return;
    for (i = 0; i < n; i++) {
        free(outs[i].dims);
        free(outs[i].data);
        outs[i].dims = NULL;
        outs[i].data = NULL;
        outs[i].count = 0;
        outs[i].ndims = 0;
        outs[i].dtype = 0;
    }
}

int ortshim_run(OrtshimGraph *graph, const OrtshimFeed *feeds, int nfeeds,
                const int *want_idx, int nwants, OrtshimFetch *outs)
{
    const OrtApi *api;
    OrtshimEngine *e;
    const char **in_names = NULL;
    const char **out_names = NULL;
    OrtValue **ins = NULL;
    OrtValue **vals = NULL;
    int rv = 1;
    int i, j;

    g_msg[0] = '\0';
    if (graph == NULL || graph->sess == NULL) { note("graph 是空的"); return 2; }
    if (outs == NULL) { note("outs 是空的"); return 2; }
    if (nfeeds < 0 || nwants < 0) { note("条目数是负的"); return 2; }
    if (nfeeds > 0 && feeds == NULL) { note("feeds 是空的"); return 2; }
    if (nwants > 0 && want_idx == NULL) { note("want_idx 是空的"); return 2; }
    e = graph->eng;
    api = e->api;
    memset(outs, 0, (size_t)(nwants > 0 ? nwants : 1) * sizeof(*outs));

    in_names = (const char **)calloc((size_t)(nfeeds > 0 ? nfeeds : 1), sizeof(char *));
    out_names = (const char **)calloc((size_t)(nwants > 0 ? nwants : 1), sizeof(char *));
    ins = (OrtValue **)calloc((size_t)(nfeeds > 0 ? nfeeds : 1), sizeof(OrtValue *));
    vals = (OrtValue **)calloc((size_t)(nwants > 0 ? nwants : 1), sizeof(OrtValue *));
    if (in_names == NULL || out_names == NULL || ins == NULL || vals == NULL) {
        note("calloc 运行期数组失败");
        goto done;
    }
    for (j = 0; j < nwants; j++) {
        int k = want_idx[j];
        if (k < 0 || k >= graph->n_out) {
            note("要的第 %d 个输出下标 %d 超出图的范围（共 %d 个输出）", j, k, graph->n_out);
            goto done;
        }
        out_names[j] = graph->names_out[k];
    }

    for (i = 0; i < nfeeds; i++) {
        const OrtshimFeed *f = &feeds[i];
        size_t esz;
        long long prod = 1;
        int d;
        ONNXTensorElementDataType t;
        if (f->name == NULL) { note("第 %d 个 feed 没有名字", i); goto done; }
        in_names[i] = f->name;
        esz = elem_size(f->dtype);
        if (esz == 0) { note("feed %s 的 dtype 不认识（=%d）", f->name, f->dtype); goto done; }
        if (f->count < 0) { note("feed %s 元素个数是负的", f->name); goto done; }
        if (f->count > 0 && f->data == NULL) { note("feed %s 说要 %lld 个元素但数据指针是空", f->name, f->count); goto done; }
        for (d = 0; d < f->ndims; d++) {
            if (f->dims[d] <= 0) { note("feed %s 第 %d 维是 %lld，非正", f->name, d, (long long)f->dims[d]); goto done; }
            prod *= f->dims[d];
        }
        if (f->ndims > 0 && prod != f->count) {
            note("feed %s 声明 %lld 个元素，形状乘出来是 %lld", f->name, f->count, prod);
            goto done;
        }
        t = f->dtype == ORTSHIM_F32 ? ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
                                    : ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
        /* 包装调用方的内存：不拷贝，所以这些数组在本次 Run 结束前必须活着（Swift 侧用 withUnsafe* 保证）。 */
        if (chk(e, api->CreateTensorWithDataAsOrtValue(e->mem, (void *)f->data,
                                                       (size_t)f->count * esz,
                                                       f->dims, (size_t)(f->ndims > 0 ? f->ndims : 0),
                                                       t, &ins[i]), "CreateTensorWithDataAsOrtValue")) goto done;
    }

    if (chk(e, api->Run(graph->sess, NULL, in_names, (const OrtValue *const *)ins, (size_t)nfeeds,
                        out_names, (size_t)nwants, vals), "Run")) goto done;

    for (j = 0; j < nwants; j++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        size_t nd = 0, elems = 0, bytes;
        ONNXTensorElementDataType et = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
        int64_t *dtmp = NULL;
        OrtStatus *s;
        void *raw = NULL, *copy = NULL;
        size_t esz;
        const char *wn = out_names[j] ? out_names[j] : "?";

        if (vals[j] == NULL) { note("输出 %s 没被填回来", wn); goto done; }
        if (chk(e, api->GetTensorTypeAndShape(vals[j], &info), "GetTensorTypeAndShape")) goto done;
        s = api->GetDimensionsCount(info, &nd);
        if (!s && nd > 0) {
            dtmp = (int64_t *)malloc(nd * sizeof(int64_t));
            if (dtmp == NULL) { api->ReleaseTensorTypeAndShapeInfo(info); note("输出 %s 形状 malloc 失败", wn); goto done; }
            s = api->GetDimensions(info, dtmp, nd);
        }
        if (!s) s = api->GetTensorElementType(info, &et);
        if (!s) s = api->GetTensorShapeElementCount(info, &elems);
        api->ReleaseTensorTypeAndShapeInfo(info);
        if (chk(e, s, "读输出形状")) { free(dtmp); goto done; }

        esz = (et == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) ? (size_t)4
              : (et == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) ? (size_t)8 : (size_t)0;
        if (esz == 0) {
            note("输出 %s 的元素类型不是 float32/int64（=%d）", wn, (int)et);
            free(dtmp);
            goto done;
        }
        if (chk(e, api->GetTensorMutableData(vals[j], &raw), "GetTensorMutableData")) { free(dtmp); goto done; }
        bytes = elems * esz;
        if (bytes > 0 && raw == NULL) { note("输出 %s 要 %zu 字节但数据指针是空", wn, bytes); free(dtmp); goto done; }
        copy = malloc(bytes > 0 ? bytes : 1);
        if (copy == NULL) { note("输出 %s 拷贝 %zu 字节 malloc 失败", wn, bytes); free(dtmp); goto done; }
        if (bytes > 0) memcpy(copy, raw, bytes);
        outs[j].dtype = (esz == 4) ? ORTSHIM_F32 : ORTSHIM_I64;
        outs[j].ndims = (int)nd;
        outs[j].dims = dtmp;
        outs[j].count = (long long)elems;
        outs[j].data = copy;
    }
    rv = 0;

done:
    if (ins != NULL) {
        for (i = 0; i < nfeeds; i++) if (ins[i] != NULL) api->ReleaseValue(ins[i]);
        free(ins);
    }
    if (vals != NULL) {
        for (j = 0; j < nwants; j++) if (vals[j] != NULL) api->ReleaseValue(vals[j]);
        free(vals);
    }
    if (in_names != NULL) free(in_names);
    if (out_names != NULL) free(out_names);
    if (rv != 0) ortshim_release(outs, nwants);
    return rv;
}
