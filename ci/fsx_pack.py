# -*- coding: utf-8 -*-
"""把两张 onnx（w600k_r50＋hyperswap_1c_256）转成手机上的两份 mlpackage，跟 PC 的标准答案对完账，
再打成 models.bin＋models.json，外加一份 chain.txt 口径标记。

发布配方：换脸网 fp16、身份证 fp32。换脸网这一格一帧跑一次，fp16 在真 fixture 上与 fp32 同一份答案
（PSNR 52.71 dB、max 3.71 灰阶、非有限数 0），Mac 上一次推理从 184 ms 掉到 79 ms；
身份证一帧只在身份复测里用两次，fp16 的 cos 会从 1.000000 掉到 0.999898，那一格直接决定
「换完还是不是那个人」，所以仍转 fp32。

帮手全从 fsx_probe 里拿（load_onnx_fixed／convert／feed_coreml／pick_out／img_diff）。
那个文件里每一式都在 mac runner 上跑绿过，在这儿重写一遍就是重新赌一遍。

判据分三层，少一层都可能把「能跑但画面是错的」发出去：
  ① onnxruntime 对账：证明 CI 下到的这两份权重和 PC 那两份逐字节是同一个行为（字节数只是第一道）；
     换脸网里 6 个 BatchNormalization 和 16 个 InstanceNormalization 转换器降不了，
     BN 折进前面的 ConvTranspose、IN 拆成基础算子，动完再用同一套标准答案对一遍；
  ② 转换器自己 --verify（只对向量网）：证明 MIL 改写没把数算歪。换脸网不用它——它拿 (0,1) 均匀随机噪声
     当人脸喂，生成式网的输出在那种输入上本来就没有参考意义（fp32 正品也会被它判 FAIL，见 convert_cli 注释）；
     换脸网的对账放在第③层，拿 PC 的真 fixture 比像素。
  ③ 落盘读回来的包再预测一遍：手机上用的是这份包，内存里那个转换对象不算数。
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import traceback

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import fsx_probe as P   # noqa: E402  所有帮手都在这张已跑绿的图上

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# 字节数钉死：换源就换字节，换字节就换画面（这两份和 PC 上验通的那两份逐字节同一个）
# 注意 hyperswap 的 1a 与 1c 字节数完全相同（402742682），光比长度分不开这两份——sha 在 workflow 那一步钉
WANT_BYTES = {
    'w600k_r50.onnx': 174383860,
    'hyperswap_1c_256.onnx': 402742682,
}
RECIPE = b'fsx-models|hyperswap_1c_256|fp16|mlpackage|v2'
ARC_PKG = 'fsx_arc'
SWAP_PKG = 'fsx_swap'
# 手机上 haveAll() 认的口径标记：资源名没变（fsx_swap.mlpackage），旧版同名包光看名字分不出来
CHAIN_TAG = 'hyperswap-1c-256'
SIDE = 256
# 这两条是「还换不换得对那个人」的底线：PC↔CoreML 实测 fp32 是 cos=1.000000／PSNR≈53，
# fp16 换脸包同样是 PSNR 52.71 dB；闸门放在远低于实测、远高于坏值的地方。
# （上一代 128 网 fp16 被随机噪声量出 PSNR 29.5 dB，那不是生成式网的有效判据，见 fsx_probe.convert_cli。）
MIN_ARC_COS = 0.999
MIN_SWAP_PSNR = 40.0


def sha_file(p, chunk=1 << 20):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def update_file(h, p, chunk=1 << 22):
    with open(p, 'rb') as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)


def fold_batchnorm(model):
    """把 BatchNormalization 折进前一张卷积——onnx2coreml 降不了 hyperswap 里的这 6 个 BN。

    6 个全挂在 ConvTranspose 后面、后面接 LeakyRelu，都是纯推理式（training_mode=0）：
      y = scale*(x-mean)/sqrt(var+eps) + bias
    折进卷积的权重／偏置后逐式等价，转换器就不用再见这个算子。
    权重保持原 dtype（整张网内部是 fp16），折完本机对 PC 标答 PSNR 79 dB、最大差 1 灰阶。
    """
    import onnx
    from onnx import numpy_helper
    g = model.graph
    init = {i.name: i for i in g.initializer}
    prod = {}
    for n in g.node:
        for o in n.output:
            prod[o] = n
    cons = {}
    for n in g.node:
        for x in n.input:
            cons[x] = cons.get(x, 0) + 1

    kept = []
    folded = 0
    for n in g.node:
        if n.op_type != 'BatchNormalization':
            kept.append(n)
            continue
        src = prod.get(n.input[0])
        if src is None or src.op_type not in ('Conv', 'ConvTranspose'):
            raise RuntimeError('BN 前面不是卷积，没有现成的折法：%s' % n.name)
        if cons.get(n.input[0], 0) != 1:
            raise RuntimeError('卷积输出还有别的消费者，折了会改到别的支路：%s' % n.name)
        groups = next((a.i for a in src.attribute if a.name == 'group'), 1)
        if groups != 1:
            raise RuntimeError('group=%d 的卷积没有试过折法：%s' % (groups, src.name))
        if any(a.name == 'training_mode' and a.i != 0 for a in n.attribute):
            raise RuntimeError('BN 是训练态，不能按推理式折：%s' % n.name)
        if src.input[1] not in init or any(x not in init for x in n.input[1:5]):
            raise RuntimeError('卷积权重或 BN 参数不是常量，折不了：%s' % n.name)
        eps = next((a.f for a in n.attribute if a.name == 'epsilon'), 1e-5)
        scale = numpy_helper.to_array(init[n.input[1]]).astype(np.float64)
        bias = numpy_helper.to_array(init[n.input[2]]).astype(np.float64)
        mean = numpy_helper.to_array(init[n.input[3]]).astype(np.float64)
        var = numpy_helper.to_array(init[n.input[4]]).astype(np.float64)
        k = scale / np.sqrt(var + eps)
        w0 = numpy_helper.to_array(init[src.input[1]])
        w = w0.astype(np.float64)
        # ConvTranspose 的权重是 (in, out/groups, kh, kw)，BN 按输出通道缩放的是第 1 维
        if w.ndim != 4 or w.shape[1] != k.size:
            raise RuntimeError('权重 %s 和 BN 通道 %d 对不上：%s' % (w.shape, k.size, src.name))
        w = w * k[None, :, None, None]
        has_bias = len(src.input) >= 3
        if has_bias and src.input[2] not in init:
            raise RuntimeError('卷积偏置不是常量，折不了：%s' % src.name)
        b0 = numpy_helper.to_array(init[src.input[2]]).astype(np.float64) if has_bias \
            else np.zeros(k.size, np.float64)
        b = (b0 - mean) * k + bias
        init[src.input[1]].CopyFrom(numpy_helper.from_array(w.astype(w0.dtype), src.input[1]))
        if has_bias:
            init[src.input[2]].CopyFrom(numpy_helper.from_array(b.astype(w0.dtype), src.input[2]))
        else:
            nb = n.input[1] + '_folded_bias'
            init[nb] = numpy_helper.from_array(b.astype(w0.dtype), nb)
            g.initializer.append(init[nb])
            src.input.append(nb)
        src.output[0] = n.output[0]
        folded += 1

    g.ClearField('node')
    g.node.extend(kept)
    if any(n.op_type == 'BatchNormalization' for n in g.node):
        raise RuntimeError('还有 BN 没折掉，转换器照样会栽')
    used = set()
    for n in g.node:
        used.update(n.input)
    keep = [i for i in g.initializer if i.name in used]
    if len(keep) != len(g.initializer):
        g.ClearField('initializer')
        g.initializer.extend(keep)
    onnx.checker.check_model(model)
    return folded


def _drop_unused_initializers(g):
    used = set()
    for n in g.node:
        used.update(n.input)
    keep = [i for i in g.initializer if i.name in used]
    if len(keep) != len(g.initializer):
        g.ClearField('initializer')
        g.initializer.extend(keep)


def materialize_constants(model):
    """把 Constant 节点落成 initializer：折 BN／拆 IN 都要按常量读它们的值，
    转换器自己的常数折叠在它内部那一步才发生，这里等不到它。"""
    import onnx
    g = model.graph
    kept = []
    n = 0
    for node in g.node:
        if node.op_type == 'Constant':
            val = next((a.t for a in node.attribute
                        if a.name == 'value' and a.type == onnx.AttributeProto.TENSOR), None)
            if val is not None:
                t = onnx.TensorProto()
                t.CopyFrom(val)
                t.name = node.output[0]
                g.initializer.append(t)
                n += 1
                continue
        kept.append(node)
    g.ClearField('node')
    g.node.extend(kept)
    return n


def decompose_instance_norm(model):
    """InstanceNormalization 也降不了：转换器给 MIL 的 epsilon 是 fp32 常数，而这张网内部是 fp16，
    类型对不上（BN 那 6 个栽的是同一条）。拆成 ReduceMean／Sub／Mul／ReduceMean／Add／Sqrt／Div
    再乘 gamma、加 beta，全部留在 fp16 里；本机对 PC 标答与原图逐像素同一份（raw max|Δ|=5e-7）。
    """
    import onnx
    from onnx import helper, numpy_helper, TensorProto
    try:
        # infer_shapes 返回的是一份拷贝（上一趟就是改了拷贝、存档的还是原图，CI 照样在 IN 上栽）；
        # 这里只借它的 value_info，图必须改传进来的这一份。
        inferred = onnx.shape_inference.infer_shapes(model)
        model.graph.ClearField('value_info')
        model.graph.value_info.extend(inferred.graph.value_info)
    except Exception:
        pass
    g = model.graph
    init = {i.name: i for i in g.initializer}
    vi = {}
    for coll in (g.value_info, g.input, g.output):
        for v in coll:
            vi[v.name] = v
    np_of = {TensorProto.FLOAT: np.float32, TensorProto.FLOAT16: np.float16,
             TensorProto.DOUBLE: np.float64}

    def rank_dtype(name):
        v = vi.get(name)
        if v is None:
            return 4, np.float16
        tt = v.type.tensor_type
        r = len(tt.shape.dim) if tt.HasField('shape') else 4
        return r, np_of.get(tt.elem_type, np.float16)

    out_nodes = []
    n_in = 0
    for n in g.node:
        if n.op_type != 'InstanceNormalization':
            out_nodes.append(n)
            continue
        x, scale, bias = n.input[0], n.input[1], n.input[2]
        if scale not in init or bias not in init:
            raise RuntimeError('IN 的 gamma／beta 不是常量，拆不了：%s' % n.name)
        eps = next((a.f for a in n.attribute if a.name == 'epsilon'), 1e-5)
        rank, x_np = rank_dtype(x)
        if rank < 3:
            raise RuntimeError('IN 的输入 rank=%d，没写过这种拆法：%s' % (rank, n.name))
        gamma = numpy_helper.to_array(init[scale])
        beta = numpy_helper.to_array(init[bias])
        c = int(gamma.size)
        # ONNX 广播从右边对齐：gamma 是 [C]，直接乘会落到 W 上，先铺成 [1,C,1,1]
        bcast = [1, c] + [1] * (rank - 2)
        tag = n.name + '_d'
        names = {}
        for suffix, arr in (('g4', gamma.astype(x_np).reshape(bcast)),
                            ('b4', beta.astype(x_np).reshape(bcast)),
                            ('eps', np.array(eps, dtype=x_np))):
            nm = tag + '_' + suffix
            t = numpy_helper.from_array(arr, nm)
            g.initializer.append(t)
            init[nm] = t
            names[suffix] = nm
        spatial = list(range(2, rank))
        out_nodes.extend([
            helper.make_node('ReduceMean', [x], [tag + '_mu'], name=tag + '_ReduceMean', axes=spatial, keepdims=1),
            helper.make_node('Sub', [x, tag + '_mu'], [tag + '_d'], name=tag + '_Sub'),
            helper.make_node('Mul', [tag + '_d', tag + '_d'], [tag + '_dd'], name=tag + '_Mul'),
            helper.make_node('ReduceMean', [tag + '_dd'], [tag + '_var'], name=tag + '_ReduceMean1', axes=spatial, keepdims=1),
            helper.make_node('Add', [tag + '_var', names['eps']], [tag + '_ve'], name=tag + '_Add'),
            helper.make_node('Sqrt', [tag + '_ve'], [tag + '_sd'], name=tag + '_Sqrt'),
            helper.make_node('Div', [tag + '_d', tag + '_sd'], [tag + '_nrm'], name=tag + '_Div'),
            helper.make_node('Mul', [tag + '_nrm', names['g4']], [tag + '_sg'], name=tag + '_Mul1'),
            helper.make_node('Add', [tag + '_sg', names['b4']], [n.output[0]], name=tag + '_Add1'),
        ])
        n_in += 1
    g.ClearField('node')
    g.node.extend(out_nodes)
    if any(n.op_type == 'InstanceNormalization' for n in g.node):
        raise RuntimeError('还有 InstanceNormalization 没拆掉，转换器照样会栽')
    _drop_unused_initializers(g)
    onnx.checker.check_model(model)
    return n_in


def pack_archive(base, files_order, out_bin, out_json, version):
    """归档：头 "SWPM"＋uint32 小端头长＋JSON 头＋各文件字节依次排下去（不压缩）。

    清单里每个 path 都相对 base（Documents/swap_models 那层）：
    mlpackage 里是一堆小文件，chain.txt 是顶层几十字节的口径标记。
    """
    import struct
    blob = bytearray()
    files = []
    for rel in files_order:
        p = os.path.join(base, rel)
        b = open(p, 'rb').read()
        files.append({'path': rel.replace(os.sep, '/'), 'size': len(b)})
        blob += b
    head = {'version': version,
            'sha256': hashlib.sha256(bytes(blob)).hexdigest(),
            'bytes': len(blob),
            'files': files}
    hb = json.dumps(head, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    arch = b'SWPM' + struct.pack('<I', len(hb)) + hb + bytes(blob)
    with open(out_bin, 'wb') as f:
        f.write(arch)
    man = {'version': version,
           'sha256': hashlib.sha256(arch).hexdigest(),
           # 载荷本身的 sha（归档头里那一格也是它）。手机下之前只读归档头，就能拿它
           # 和这一格对：CI 重跑一次换了转换器，版本号不变、字节变了，也能当场认出来。
           'payloadSha': hashlib.sha256(bytes(blob)).hexdigest(),
           'bytes': len(arch),
           'files': files}
    with open(out_json, 'w', encoding='utf-8') as f:
        f.write(json.dumps(man, ensure_ascii=False, separators=(',', ':')))
    P.log('FXP-PACK', '文件 %d 个｜载荷 %d 字节｜归档 %d 字节｜头 %d 字节'
          % (len(files), len(blob), len(arch), len(hb)))
    for f_ in files:
        if f_['path'].endswith('Manifest.json') or f_['path'] == 'chain.txt':
            P.log('FXP-PACK', '有 %s %d 字节' % (f_['path'], f_['size']))
    return man


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--onnx-dir', required=True, help='放 w600k_r50.onnx／hyperswap_1c_256.onnx 的目录')
    ap.add_argument('--fixtures', required=True, help='ci/fsx_fixtures：PC 出的标准答案')
    ap.add_argument('--out-root', default='app/SwapModel',
                    help='两份 mlpackage＋chain.txt＋models.bin/json 落这里（不能落进 SourcesSwap，xcodegen 会把 mlpackage 当编译输入）')
    ap.add_argument('--cli', default=None, help='onnx2coreml 可执行文件路径；不给就在 PATH 里找')
    a = ap.parse_args()

    arc_onnx = os.path.join(a.onnx_dir, 'w600k_r50.onnx')
    sw_onnx = os.path.join(a.onnx_dir, 'hyperswap_1c_256.onnx')
    os.makedirs(a.out_root, exist_ok=True)
    logfile = os.path.join(a.out_root, 'fsx_pack.log')
    for p in (arc_onnx, sw_onnx):
        sz = os.path.getsize(p) if os.path.isfile(p) else -1
        want = WANT_BYTES.get(os.path.basename(p), -1)
        P.log('FXP-IN', p, '字节', sz, '（要', want, '）')
        if sz != want:
            raise RuntimeError('字节数对不上：%s 拿到 %s 要 %s' % (p, sz, want))

    cli = a.cli or shutil.which('onnx2coreml')
    if not cli or not os.path.isfile(cli):
        raise RuntimeError('找不到 onnx2coreml（coremltools 9 的 ct.convert 不认 onnx，第一轮四条全败在那儿）')
    P.log('FXP-ENV', 'onnx2coreml=%s' % cli)

    ref = json.load(open(os.path.join(a.fixtures, 'fsx_ref.json'), encoding='utf-8'))
    src112 = P.imread_rgb(os.path.join(a.fixtures, 'fsx_src112.png'))
    tgt = P.imread_rgb(os.path.join(a.fixtures, 'fsx_tgt256.png'))
    out_ref = P.imread_rgb(os.path.join(a.fixtures, 'fsx_out256.png'))
    ref_emb = np.array(ref['emb'], np.float32)
    if tgt.shape[:2] != (SIDE, SIDE) or out_ref.shape[:2] != (SIDE, SIDE):
        raise RuntimeError('fixture 尺寸不对：tgt=%s out=%s（要 %d）' % (tgt.shape, out_ref.shape, SIDE))

    # ---- ① onnxruntime 基线：先确认「下到的这两份」和 PC 是同一套答案，再谈转换
    import onnxruntime as ort
    sa = ort.InferenceSession(arc_onnx, providers=['CPUExecutionProvider'])
    emb_onnx = P.ort_emb(sa, src112)
    del sa
    cos_onnx = P.cos(emb_onnx, ref_emb)
    ss = ort.InferenceSession(sw_onnx, providers=['CPUExecutionProvider'])
    # hyperswap 的喂法：图像 (x/255−0.5)/0.5，源就是归一化后的 512 维向量；出参带符号，先 ×0.5+0.5 再比
    out_onnx, raw_onnx = P.ort_swap_tuned(ss, tgt, ref_emb, 0.5, 0.5, True)
    del ss
    mx, mn, ps_onnx = P.img_diff(out_onnx / 255.0, out_ref)
    P.log('FXP-ORT', '嵌入 cos=%.6f｜256 脸 max=%.2f mean=%.3f 灰阶 PSNR=%.2f dB｜出参 %.3f..%.3f 均值 %.3f'
          % (cos_onnx, mx, mn, ps_onnx, float(raw_onnx.min()), float(raw_onnx.max()), float(raw_onnx.mean())))
    if cos_onnx < MIN_ARC_COS or ps_onnx < MIN_SWAP_PSNR:
        raise RuntimeError('onnx 基线就和 PC 不一致（cos %.6f／PSNR %.2f）⇒ 下到的不是那两份权重'
                           % (cos_onnx, ps_onnx))

    # ---- ② 钉死符号维、把 BN 折进卷积后落盘（转换器只认文件；w600k_r50 的 batch 维是 pytorch 1.8 留的 None）
    tmp = os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'fsxpack')
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    import onnx
    arc_fixed = os.path.join(tmp, 'fsx_arc_fixed.onnx')
    sw_fixed = os.path.join(tmp, 'fsx_swap_fixed.onnx')
    arc_model = P.load_onnx_fixed(arc_onnx)
    sw_model = P.load_onnx_fixed(sw_onnx)
    onnx.save(arc_model, arc_fixed)
    # onnx2coreml 降不了这张网里的 BatchNormalization／InstanceNormalization（上一趟就栽在这两种算子上）：
    # 常数落成 initializer、BN 折进前面的 ConvTranspose、IN 拆成基础算子，再转；
    # 动完必须拿同一套标准答案再对一遍——折错／拆错就是整片脸都错。
    n_const = materialize_constants(sw_model)
    n_bn = fold_batchnorm(sw_model)
    n_in = decompose_instance_norm(sw_model)
    onnx.save(sw_model, sw_fixed)
    # 回读存档本身：判据不能只看内存里改过没改过（上一趟就是改在拷贝上，存档还是原图）
    left = sorted({n.op_type for n in onnx.load(sw_fixed).graph.node
                   if n.op_type in ('BatchNormalization', 'InstanceNormalization', 'Constant')})
    if left:
        raise RuntimeError('落盘的换脸网里还留着转换器不认的算子：%s' % '／'.join(left))
    ss = ort.InferenceSession(sw_fixed, providers=['CPUExecutionProvider'])
    out_fold, _ = P.ort_swap_tuned(ss, tgt, ref_emb, 0.5, 0.5, True)
    del ss
    mx_f, mn_f, ps_f = P.img_diff(out_fold / 255.0, out_ref)
    P.log('FXP-FOLD', '常数 %d 个落盘｜BatchNorm %d 个折进卷积｜InstanceNorm %d 个拆成基础算子'
          '｜动完 vs PC max=%.2f mean=%.3f 灰阶 PSNR=%.2f dB'
          % (n_const, n_bn, n_in, mx_f, mn_f, ps_f))
    if ps_f < MIN_SWAP_PSNR:
        raise RuntimeError('BN/IN 改完对不上 PC 标答（PSNR %.2f）' % ps_f)

    # ---- ④ 两张网各转一遍（换脸网 fp16、身份证 fp32），转完立刻从盘上读回来对账
    # 换脸网 fp16：同一套 PC 标答上 PSNR 52.71 dB、max 3.71 灰阶、非有限数 0，和 fp32 一模一样；
    # 它在整条链路里一帧跑一次，Mac 上一次推理 184→79 ms，手机上的大头就是它。
    # 身份证仍 fp32：一帧只在身份复测（每 60 帧）用两次，fp16 的 cos 是 0.999898（fp32 是 1.000000），
    # 这一格直接决定「换完还是不是那个人」，不值当拿它换那 20 ms。
    rec = {}
    fails = []
    plan = [(ARC_PKG, arc_model, arc_fixed, 'arc', True, False),
            (SWAP_PKG, sw_model, sw_fixed, 'swap', False, True)]
    for pkg_name, model, fixed, which, verify, fp16 in plan:
        prec = 'fp16' if fp16 else 'fp32'
        pkg = os.path.join(a.out_root, pkg_name + '.mlpackage')
        try:
            m, el, rel = P.convert(model, pkg, fp16, fixed, cli, verify=verify)
            ins, outs = P.coreml_io(m)
            if which == 'arc':
                x112 = (src112.astype(np.float32) - 127.5) / 127.5
                res, ms = P.coreml_predict(m, P.feed_coreml(ins, [(x112.transpose(2, 0, 1)[None], x112)]))
                oname, got = P.pick_out(res, 512)
                e = got.reshape(-1)
                # max|Δ| 必须两边都归一化后再比：CoreML 回来的那一份模长≈3，PC 存的那份是归一化过的，
                # 直接相减会报出 2.9 这种吓人的数，而同一行的 cos 却是 1.000000——差的就是这层缩放。
                en = e / max(float(np.linalg.norm(e)), 1e-12)
                rn = ref_emb / max(float(np.linalg.norm(ref_emb)), 1e-12)
                c = P.cos(en, rn)
                mdelta = float(np.abs(en - rn).max())
                rec['arc'] = {'cos': c, 'max_abs': mdelta, 'precision': prec,
                              'mb': round(P.pkg_mb(pkg), 1),
                              'convert_s': round(el, 1), 'infer_ms': round(ms, 1)}
                P.log('FXP-VERDICT', 'arc(%s) 成 转换 %.0f s 读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                      '｜入 %s 出 %s 取的出参 %s｜嵌入 cos=%.6f max|Δ|=%.5f'
                      % (prec, el, rel, P.pkg_mb(pkg), ms,
                         ['%s(%s,共%d)' % (n, 'image' if im else 'multi', t) for n, im, t in ins],
                         outs, oname, c, mdelta))
                if c < MIN_ARC_COS:
                    fails.append('arc 落盘的包 cos=%.6f 掉到闸门 %.3f 以下' % (c, MIN_ARC_COS))
            else:
                # 与手机上同一条喂法：0..1 的 planar RGB 再走 (x−0.5)/0.5；源是归一化后的 512 维向量
                rgb = tgt.astype(np.float32) / 255.0
                x = ((rgb - 0.5) / 0.5).transpose(2, 0, 1)[None]
                feed = P.feed_coreml(ins, [(x, rgb), (ref_emb[None], ref_emb)])
                P.coreml_predict(m, feed)                      # 第一趟含建管线，丢掉
                res, ms = P.coreml_predict(m, feed)
                oname, got = P.pick_out(res, 3 * SIDE * SIDE)
                if got.ndim == 4:
                    got = got[0]
                bad = int(np.sum(~np.isfinite(got)))
                # 出参带符号：×0.5+0.5 还原成 0..1 再比（PC 标答也是这么还原的）
                o01 = np.clip(got.transpose(1, 2, 0) * 0.5 + 0.5, 0.0, 1.0)
                mx, mn, ps = P.img_diff(o01, out_ref)
                rec['swap'] = {'psnr': ps, 'max_abs': mx, 'nonfinite': bad, 'precision': prec,
                               'mb': round(P.pkg_mb(pkg), 1),
                               'convert_s': round(el, 1), 'infer_ms': round(ms, 1)}
                P.log('FXP-VERDICT', 'swap(%s) 成 转换 %.0f s 读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                      '｜入 %s 出 %s 取的出参 %s｜非有限数 %d 个'
                      % (prec, el, rel, P.pkg_mb(pkg), ms,
                         ['%s(%s,共%d)' % (n, 'image' if im else 'multi', t) for n, im, t in ins],
                         outs, oname, bad))
                P.log('FXP-PIX', 'swap(%s) max=%.2f mean=%.3f 灰阶 PSNR=%.2f dB' % (prec, mx, mn, ps))
                if bad != 0:
                    fails.append('swap 落盘的包出了 %d 个非有限数' % bad)
                if ps < MIN_SWAP_PSNR:
                    fails.append('swap 落盘的包 PSNR=%.2f 掉到闸门 %.1f 以下' % (ps, MIN_SWAP_PSNR))
        except Exception as e:
            fails.append('%s 转换/对账失败：%s' % (which, repr(e)[:300]))
            P.log('FXP-VERDICT', '%s 失败：' % which, repr(e)[:300])
            traceback.print_exc(file=sys.stdout)
        finally:
            m = None
    # 钉过维的两份中间产物（~695 MB）转完就没用了：归档那一步要在内存里再攒 ~694 MB，先腾出来
    shutil.rmtree(tmp, ignore_errors=True)

    # ---- ⑤ 三方都齐了才打包：少任何一张，手机上 haveAll() 就拦住，宁可不发
    if fails:
        P.log('FXP-VERDICT', '不成，不发模型：' + '；'.join(fails))
        with open(os.path.join(a.out_root, 'fsx_summary.json'), 'w', encoding='utf-8') as f:
            json.dump({'rec': rec, 'fails': fails}, f, ensure_ascii=False, indent=1)
        return 1

    vh = hashlib.sha256()
    vh.update(RECIPE)
    update_file(vh, arc_onnx)
    update_file(vh, sw_onnx)
    version = vh.hexdigest()

    # 口径标记：资源名和旧版一样，手机上只能靠这个文件分清是 inswapper 那一代还是 hyperswap 这一代。
    # 旧包里的 emap.bin 留在盘上没用，先清掉，别让它混进新归档。
    stale_emap = os.path.join(a.out_root, 'emap.bin')
    if os.path.isfile(stale_emap):
        os.remove(stale_emap)
    chain_file = os.path.join(a.out_root, 'chain.txt')
    with open(chain_file, 'w', encoding='utf-8', newline='\n') as f:
        f.write(CHAIN_TAG + '\n')

    order = []
    for pkg_name in (ARC_PKG, SWAP_PKG):
        d = os.path.join(a.out_root, pkg_name + '.mlpackage')
        paths = []
        for root, dirs, fns in os.walk(d):
            dirs.sort()
            for fn in sorted(fns):
                paths.append(os.path.join(root, fn))
        for p in sorted(paths):
            order.append(os.path.relpath(p, a.out_root))
    order.append('chain.txt')
    try:
        man = pack_archive(a.out_root, order,
                           os.path.join(a.out_root, 'models.bin'),
                           os.path.join(a.out_root, 'models.json'), version)
    except Exception as e:
        P.log('FXP-VERDICT', '打包失败：', repr(e)[:300])
        return 1

    need = {'%s.mlpackage/Manifest.json' % r for r in (ARC_PKG, SWAP_PKG)} | {'chain.txt'}
    have = {f['path'] for f in man['files']}
    if not need <= have:
        P.log('FXP-VERDICT', '清单里缺 %s ⇒ 手机上 haveAll() 会拦，这一版发出去也用不了'
              % ','.join(sorted(need - have)))
        return 1
    P.log('FXP-SUM', json.dumps(rec, ensure_ascii=False))
    P.log('FXP-VERDICT', '成 版本 %s｜归档 %d 字节（%.0f MB）｜清单 %d 个文件｜两张网＋口径标记 %s 齐'
          % (version[:12], man['bytes'], man['bytes'] / 1048576.0, len(man['files']), CHAIN_TAG))
    with open(os.path.join(a.out_root, 'fsx_summary.json'), 'w', encoding='utf-8') as f:
        json.dump({'version': version, 'recipe': RECIPE.decode(), 'rec': rec}, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == '__main__':
    rc = 1
    try:
        rc = main()
    except Exception as exc:
        P.log('FXP-VERDICT', '炸：', repr(exc)[:400])
        traceback.print_exc(file=sys.stdout)
        rc = 1
    finally:
        try:
            P.flush(os.path.join(sys.argv[sys.argv.index('--out-root') + 1], 'fsx_pack.log'))
        except Exception:
            out = 'app/SwapModel'
            os.makedirs(out, exist_ok=True)
            P.flush(os.path.join(out, 'fsx_pack.log'))
    sys.exit(rc)
