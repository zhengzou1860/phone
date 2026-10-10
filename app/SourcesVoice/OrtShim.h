#ifndef ORTSHIM_H
#define ORTSHIM_H

/*
 ONNX Runtime C API 的薄封装，只暴露这套 MeanVC 图用得上的那几件事。

 为什么不直接从 Swift 调 OrtApi：那个结构体有八百多个函数指针成员，Swift 导入器
 怎么把它们翻成 @convention(c) 我在这台机器上验证不了（本机没有 swiftc，每次猜错
 就是一轮 CI）。中间垫一层 C，Swift 看到的就全是普通指针和整数，签名我自己写死。

 句柄为什么是 void * 而不是 `typedef struct OrtshimEngine OrtshimEngine;`：
 只有前向声明、没有定义的不透明 struct，clang 的 Swift 导入器根本不给导入，
 实跑 CI 报的就是 "cannot find type 'OrtshimEngine' in scope"。void * 进来就是
 UnsafeMutableRawPointer，形态唯一，不用再猜。结构体真正的定义只在 OrtShim.c 里。

 图里的张量只有两种元素类型：float32 和 int64（int64 只出现在 offset 这一个标量输入）。
 所以这里不做通用 dtype，只认这两种。
*/

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORTSHIM_F32 1
#define ORTSHIM_I64 2

/* log_level 用 ORT 的数值口径：0 verbose / 1 info / 2 warning / 3 error / 4 fatal。
   返回 NULL 就是失败，原因看 ortshim_last_error()。 */
void *ortshim_open(int intra_threads, int log_level);
void ortshim_close(void *engine);

/* 最近一次失败的说明，永远是有效 C 字符串；成功时是空串。 */
const char *ortshim_last_error(void);

void *ortshim_load(void *engine, const char *path_utf8);
void ortshim_unload(void *graph);

int ortshim_input_count(void *graph);
int ortshim_output_count(void *graph);
/* 名字由 graph 持有，生命周期到 ortshim_unload 为止。 */
const char *ortshim_input_name(void *graph, int index);
const char *ortshim_output_name(void *graph, int index);

typedef struct {
    const char *name;
    int dtype;              /* ORTSHIM_F32 / ORTSHIM_I64 */
    const int64_t *dims;    /* ndims==0 表示标量 */
    int ndims;
    const void *data;       /* 调用方持有，本次调用内够用即可 */
    long long count;
} OrtshimFeed;

typedef struct {
    int dtype;
    int ndims;
    int64_t *dims;          /* 由 shim malloc，ortshim_release 负责还 */
    long long count;
    void *data;             /* 同上 */
} OrtshimFetch;

/* 要哪几个输出：按 ortshim_output_name 的下标给。用下标而不是字符串数组，
   是因为 `const char *const *` 这种二级指针被 Swift 导入成什么形态，本机没有
   swiftc 验证不了；下标就只是一个 Int32 数组。
   成功返回 0 并把 outs[0..nwants) 填满；失败返回非 0，outs 里不会留下要还的东西。 */
int ortshim_run(void *graph, const OrtshimFeed *feeds, int nfeeds,
                const int *want_idx, int nwants, OrtshimFetch *outs);
void ortshim_release(OrtshimFetch *outs, int n);

#ifdef __cplusplus
}
#endif
#endif
