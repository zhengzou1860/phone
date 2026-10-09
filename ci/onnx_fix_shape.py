"""把 insightface 的 w600k_mbf.onnx 的 batch 维从符号 'None' 钉成 1。

pytorch 1.8 导出时给了 dynamic_axes，onnx2coreml 明确要求固定输入形状，
coremltools 的 onnx 前端同样不欢迎符号维。高宽本来就是静态 112×112，只有 batch 要改。
改完必须证 embedding 没变，否则这把尺的标定值 0.9/0.10 全作废。
"""
import sys

import onnx

SRC = sys.argv[1]
DST = sys.argv[2]


def dims(inp):
    out = []
    for d in inp.type.tensor_type.shape.dim:
        out.append(d.dim_value if d.HasField("dim_value") else d.dim_param)
    return out


m = onnx.load(SRC)
print("before", [(i.name, dims(i)) for i in m.graph.input])
for i in m.graph.input:
    for d in i.type.tensor_type.shape.dim:
        if d.HasField("dim_param") or d.dim_value == 0:
            d.ClearField("dim_param")
            d.dim_value = 1
onnx.checker.check_model(m)
onnx.save(m, DST)

c = onnx.load(DST)
print("after  ", [(i.name, dims(i)) for i in c.graph.input],
               [(o.name, dims(o)) for o in c.graph.output])
