"""声音 app 的转换探测：这 11 张图 onnx2coreml 到底认不认，认了之后跟 onnxruntime 差多少。

剪辑项目那一格只验过一张 98 节点的小 CNN（--verify 到 max_abs 0.034 / 43 dB）。这里最大的一张有
2162 节点，还带 LayerNormalization / Einsum / Erf 这些 MIL 不一定接得住的算子 ⇒ "能不能以 CoreML
出货"在这台 runner 上是从没量过的问题，而且它一票否决的可能性最高，所以排在任何 UI 之前。

逐图判据、逐图立刻落盘：runner 撞超时也已经有前面几张的判决。不发回来的探测等于没做。
"""
import json
import os
import shutil
import subprocess
import sys
import time
import traceback

import numpy as np
import onnx
import onnxruntime as ort

ORDER = [
    # 最便宜的一张先当金丝雀：它挂了后面全不用试
    "vocos.onnx",
    # 最贵也最热的一张：稳态 DiT 每个 chunk 都要跑，节点最多
    "dit_state_6.onnx",
    "fastu2plusplus_state_c_steady.onnx",
    "dit_state_0.onnx",
    "fastu2plusplus_state_a_first.onnx",
    "fastu2plusplus_state_b_second.onnx",
    "dit_state_1.onnx",
    "dit_state_2.onnx",
    "dit_state_3.onnx",
    "dit_state_4.onnx",
    "dit_state_5.onnx",
]

DT = {"tensor(float)": np.float32, "tensor(double)": np.float64,
      "tensor(int64)": np.int64, "tensor(int32)": np.int32, "tensor(bool)": np.bool_}

LOG = None


def emit(line):
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def tail(text, n=2):
    keep = [l for l in (text or "").splitlines() if l.strip()]
    return " ｜ ".join(keep[-n:])[:260]


def o2c_bin():
    w = shutil.which("onnx2coreml")
    if w:
        return w
    cand = os.path.join(os.path.dirname(sys.executable), "onnx2coreml")
    return cand if os.path.exists(cand) else None


def make_feeds(sess, rng):
    """形状全静态才谈得上转换；一遇动态维就把这张图判死并说是哪个维。"""
    feeds = {}
    for i in sess.get_inputs():
        shape = []
        for d in i.shape:
            if isinstance(d, int):
                shape.append(d)
            else:
                return None, "动态维 %s%s" % (i.name, i.shape)
        dt = DT.get(i.type)
        if dt is None:
            return None, "没 dtype 映射 %s(%s)" % (i.name, i.type)
        if dt == np.bool_:
            a = rng.random(size=shape or (1)) > 0.5
        elif np.issubdtype(dt, np.integer):
            a = rng.integers(0, 2, size=shape or (1))
        else:
            a = rng.standard_normal(size=shape or (1)).astype(dt)
        feeds[i.name] = np.asarray(a, dtype=dt)
    return feeds, None


def compare(ref, got, names):
    """max_abs 必须和输出自身幅度一起报：随机输入喂进扩散模型，绝对差大不等于转错了。"""
    rows, worst_abs, worst_rel = [], 0.0, 0.0
    for n, a, b in zip(names, ref, got):
        a = np.asarray(a, dtype=np.float64)
        b = np.asarray(b, dtype=np.float64)
        if a.shape != b.shape:
            rows.append("%s 形状 %s vs %s" % (n, a.shape, b.shape))
            worst_rel = 9e9
            continue
        if a.size == 0:
            continue
        d = float(np.abs(a - b).max())
        scale = max(float(np.abs(a).max()), 1e-9)
        worst_abs = max(worst_abs, d)
        worst_rel = max(worst_rel, d / scale)
        rows.append("%s abs %.2e/幅 %.2e" % (n, d, scale))
    return worst_abs, worst_rel, " ".join(rows)


def main():
    global LOG
    src, out, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
    budget = float(sys.argv[4]) if len(sys.argv) > 4 else 1200.0
    t0 = time.time()
    open(LOG, "w").close()
    rng = np.random.default_rng(0)

    binp = o2c_bin()
    emit("ENV python=%s onnx2coreml=%s ort=%s onnx=%s numpy=%s｜待试 %d 张"
         % (sys.version.split()[0], binp, ort.__version__, onnx.__version__,
            np.__version__, len(ORDER)))
    if binp is None:
        emit("SUM 全部判死=onnx2coreml 这个命令不存在，转换根本没开始")
        return

    import coremltools as ct
    emit("ENV coremltools=%s" % ct.__version__)

    tried = 0
    for fn in ORDER:
        p = os.path.join(src, fn)
        if not os.path.isfile(p):
            emit("SUM %s 文件不在，跳过" % fn)
            continue
        if time.time() - t0 > budget:
            emit("SUM 预算 %.0f s 用尽，剩下没试的从这张开始：%s" % (budget, fn))
            break
        tried += 1
        pkg = os.path.join(out, fn[:-5] + ".mlpackage")
        shutil.rmtree(pkg, ignore_errors=True)
        try:
            size = os.path.getsize(p)
            sess = ort.InferenceSession(p, providers=["CPUExecutionProvider"])
            onames = [o.name for o in sess.get_outputs()]
            feeds, why = make_feeds(sess, rng)
            if feeds is None:
                emit("SUM %s bytes=%d 判死=形状 %s" % (fn, size, why))
                continue
            ref = sess.run(None, feeds)
            n_in = [(k, v.shape, str(v.dtype)) for k, v in feeds.items()]

            tc = time.time()
            r = subprocess.run([binp, "convert", p, "-o", pkg, "--format", "mlpackage"],
                               capture_output=True, text=True)
            conv_s = time.time() - tc
            if r.returncode != 0 or not os.path.isdir(pkg):
                emit("SUM %s bytes=%d 转换=失败 rc=%s 用时%.0fs 错因 %s"
                     % (fn, size, r.returncode, conv_s, tail(r.stderr or r.stdout, 3)))
                continue
            pkg_b = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(pkg) for f in fs)

            tp = time.time()
            try:
                mm = ct.models.MLModel(pkg, compute_unit=ct.ComputeUnit.CPU_ONLY)
                res = mm.predict(feeds)
            except Exception as e:
                emit("SUM %s bytes=%d 转换=成功 mlpackage=%dKB 但 CoreML 侧加载/预测不起来：%s｜输入 %s"
                     % (fn, size, pkg_b // 1024, str(e)[:200], json.dumps(n_in)[:200]))
                continue
            load_s = time.time() - tp
            if not isinstance(res, dict):
                res = {onames[0]: res} if len(onames) == 1 else {}
            miss = [n for n in onames if n not in res]
            if miss:
                got_names = sorted(res)
                emit("SUM %s 转换=成功 但 CoreML 的输出口径对不上：缺 %s｜它给的是 %s"
                     % (fn, miss[:6], got_names[:10]))
                continue
            abs_, rel_, detail = compare(ref, [res[n] for n in onames], onames)
            emit("SUM %s bytes=%d 转换=成功 mlpackage=%dKB(%+.1f%%) 加载%.1fs "
                 "对拍 max_abs=%.3e 相对最差=%.3e 转%.0fs [%s]"
                 % (fn, size, pkg_b // 1024, 100.0 * (pkg_b - size) / max(size, 1),
                    load_s, abs_, rel_, conv_s, detail[:220]))
        except Exception:
            tb = traceback.format_exc().splitlines()
            emit("SUM %s 探测自己崩了：%s" % (fn, " | ".join(tb[-4:-1])[:240]))

    emit("BUDGET 用了 %.0f s，试了 %d/%d 张" % (time.time() - t0, tried, len(ORDER)))


main()
