"""在这个 job 里对单个 coremltools 版本试一次 onnx → CoreML，只吐一行 SUM。

为什么要逐版本：coremltools 9.0 明确拒绝 onnx 输入（source 的合法值只剩
tensorflow/pytorch/milinternal），而"苹果的工具链认不认这把尺"不能靠一个版本的
回答下定论。老版本是 numpy 1.x 时代编的，所以每个版本各占一个 venv，不跟 9.0 共用环境。
"""
import os
import sys

V = sys.argv[1]
SRC = "/tmp/sc/w600k_mbf.onnx"


def size(path):
    if os.path.isdir(path):
        return sum(os.path.getsize(os.path.join(r, f))
                   for r, _, files in os.walk(path) for f in files)
    return os.path.getsize(path) if os.path.exists(path) else 0


def flat(e):
    return " ".join(str(e).split())[:45]


try:
    import coremltools as ct
except Exception as e:
    print("SUM v=%s 装不上/导不进来 %s %s" % (V, type(e).__name__, flat(e)))
    sys.exit(0)

flags = ["ct=%s" % ct.__version__,
         "有无onnx子模块=%s" % hasattr(getattr(ct, "converters", None), "onnx")]

try:
    import onnx
    m0 = onnx.load(SRC)
except Exception as e:
    print("SUM v=%s %s onnx读不了 %s" % (V, " ".join(flags), type(e).__name__))
    sys.exit(0)

res = []
for name in ("iOS15", "iOS13", "nn"):
    kw = {}
    if name != "nn":
        t = getattr(ct.target, name, None)
        if t is None:
            res.append("%s=没有这个target" % name)
            continue
        kw["minimum_deployment_target"] = t
    try:
        m = ct.convert(m0, **kw)
        out = "/tmp/mbf_%s_%s" % (V.replace(".", ""), name)
        m.save(out)
        ins = ",".join(i.name for i in m.get_spec().description.input)
        res.append("%s=OK(%dKB,in=%s)" % (name, size(out) // 1024, ins))
    except Exception as e:
        res.append("%s=%s:%s" % (name, type(e).__name__, flat(e)))

print("SUM v=%s %s %s" % (V, " ".join(flags), " ".join(res)))
