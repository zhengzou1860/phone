"""在这个 job 里对单个 coremltools 版本试 onnx → CoreML，只吐一行 SUM。

为什么要逐版本：coremltools 9.0 明确拒绝 onnx 输入（source 的合法值只剩
tensorflow/pytorch/milinternal），而"苹果的工具链认不认这把尺"不能靠一个版本的
回答下定论。老版本是 numpy 1.x 时代编的，所以每个版本各占一个 venv。

为什么要两种输入：原版 w600k_mbf.onnx 的 batch 维是符号 None，转换器要求固定形状；
把 None 钉成 1 之后能不能被吃下，是另一回事。两个都要试，才能分清"苹果不认 onnx"
和"苹果只是不认动态形状"。完整报错留在 /tmp/ver.log（已发到 channel-coreml 匿名可读），
annotation 里只放紧凑码，免得超了每步约 10 条的配额把判定行挤掉。
"""
import os
import sys

V = sys.argv[1]
SRC = {"原": "/tmp/sc/w600k_mbf.onnx", "钉": "/tmp/sc/w600k_fixed.onnx"}


def size(path):
    if os.path.isdir(path):
        return sum(os.path.getsize(os.path.join(r, f))
                   for r, _, files in os.walk(path) for f in files)
    return os.path.getsize(path) if os.path.exists(path) else 0


def code(e):
    return type(e).__name__[:9]


def shapes(i):
    d = []
    for x in i.type.tensor_type.shape.dim:
        d.append(str(x.dim_value) if x.HasField("dim_value") else str(x.dim_param))
    return "x".join(d)


try:
    import coremltools as ct
except Exception as e:
    print("SUM v=%s 装不上 %s" % (V, code(e)))
    sys.exit(0)

flags = "ct=%s onnxmod=%s" % (ct.__version__,
                              "y" if hasattr(getattr(ct, "converters", None), "onnx") else "n")
ok_total = 0
parts = []
for tag, path in SRC.items():
    if not os.path.exists(path):
        parts.append("%s=没有这个文件" % tag)
        continue
    ins = "?"
    try:
        import onnx
        m0 = onnx.load(path)
        ins = ",".join("%s:%s" % (i.name, shapes(i)) for i in m0.graph.input)
    except Exception as e:
        parts.append("%s(%s)=读不了%s" % (tag, ins, code(e)))
        continue
    res = []
    for name in ("iOS15", "nn"):
        kw = {}
        if name != "nn":
            t = getattr(ct.target, name, None)
            if t is None:
                res.append("%s=noTarget" % name)
                continue
            kw["minimum_deployment_target"] = t
        try:
            m = ct.convert(m0, **kw)
            out = "/tmp/mbf_%s_%s_%s" % (V.replace(".", ""), tag, name)
            m.save(out)
            res.append("%s=OK%dKB" % (name, size(out) // 1024))
            ok_total += 1
        except Exception as e:
            res.append("%s=%s" % (name, code(e)))
    parts.append("%s(%s) %s" % (tag, ins, " ".join(res)))

print("SUM v=%s %s ok=%d | %s" % (V, flags, ok_total, " | ".join(parts)))
