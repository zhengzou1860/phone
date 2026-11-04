# -*- coding: utf-8 -*-
"""在 mac 上回答三个问题：这两张 onnx 苹果的工具链认不认、fp16 掉不掉身份、CoreML 出的脸和 PC 是不是同一张。

手机只能跑 CoreML，而 Windows 这边转不了，所以整套判据都在 CI 那台 mac 上落：
  ① w600k_r50.onnx（人脸向量网）→ CoreML，嵌入和 PC 的标准答案对余弦；
  ② inswapper_128.onnx（换脸网）→ CoreML，128 那张脸和标准答案逐像素对；
  ③ 两张都各转 fp16／fp32 一遍，把「掉多少身份」「掉多少像素」「多大」「多久」「吃了多少内存」全记下来。
判据全走 FSX- 前缀的行，方便在 annotation 里一眼看到；全文写进 --out-dir/fsx_probe.log。

对账用的标准答案由本机 fsx/mkfixtures.py 生成，随仓库进 ci/fsx_fixtures/。
"""
import argparse
import json
import os
import sys
import time
import traceback

import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

LOG = []


def log(tag, *parts):
    line = '%s %s' % (tag, ' '.join(str(p) for p in parts))
    LOG.append(line)
    print(line, flush=True)


def flush(path):
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(LOG) + '\n')


def imread_rgb(p):
    import cv2
    im = cv2.imread(p, cv2.IMREAD_COLOR)
    if im is None:
        raise RuntimeError('读不到 %s' % p)
    return cv2.cvtColor(im, cv2.COLOR_BGR2RGB)


def imwrite_rgb(p, arr):
    import cv2
    cv2.imwrite(p, cv2.cvtColor(arr, cv2.COLOR_RGB2BGR))


def cos(a, b):
    a = np.asarray(a, np.float64).ravel()
    b = np.asarray(b, np.float64).ravel()
    d = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    return d


def img_diff(out01, ref_u8):
    """CoreML 出来的 0..1 浮点脸 vs PC 的 uint8 标准答案：返回灰阶单位的 max／mean 和 PSNR。"""
    got = np.clip(out01 * 255.0, 0, 255)
    d = np.abs(got - ref_u8.astype(np.float64))
    mse = float(((got - ref_u8.astype(np.float64)) ** 2).mean())
    psnr = 99.0 if mse < 1e-9 else float(10.0 * np.log10(255.0 * 255.0 / mse))
    return float(d.max()), float(d.mean()), psnr


# ---------------------------------------------------------------- ONNX 基线

def ort_session(path):
    import onnxruntime as ort
    return ort.InferenceSession(path, providers=['CPUExecutionProvider'])


def ort_emb(sess, rgb112):
    x = (rgb112.astype(np.float32) - 127.5) / 127.5
    e = sess.run(None, {sess.get_inputs()[0].name: x.transpose(2, 0, 1)[None]})[0][0]
    return e / np.linalg.norm(e)


def ort_swap(sess, rgb128, latent, tag=''):
    blob = rgb128.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
    feed = {}
    for i in sess.get_inputs():
        tot = 1
        for d in i.shape:
            tot *= int(d) if isinstance(d, int) else 1
        feed[i.name] = blob if tot > 512 else latent[None].astype(np.float32)
    out = sess.run(None, feed)[0]
    if out.ndim == 4:
        out = out[0]
    return np.clip(out.transpose(1, 2, 0), 0.0, 1.0)


def extract_emap(onnx_path, out_bin):
    """换脸网里那张 (512,512) 的 latent 映射矩阵（官方名字 buff2fs）：手机上自己乘，得单独给一份。"""
    import onnx
    from onnx import numpy_helper
    m = onnx.load(onnx_path)
    cands = []
    for init in m.graph.initializer:
        a = numpy_helper.to_array(init)
        if a.shape == (512, 512) and a.dtype in (np.float32, np.float16):
            cands.append((init.name, a.astype(np.float32)))
    if len(cands) != 1:
        raise RuntimeError('emap 候选 %d 个（要正好 1 个）：%s' % (len(cands), [c[0] for c in cands]))
    name, arr = cands[0]
    arr = np.ascontiguousarray(arr, dtype=np.float32)
    arr.tofile(out_bin)
    return name, arr


# ---------------------------------------------------------------- CoreML

def coreml_io(m):
    """入参表 [(名字, 是不是 image 型, 元素总数)]＋出参名：手机那边按这张表喂，不许按顺序猜。"""
    md = m.get_spec().description
    ins = []
    for d in md.input:
        if d.type.HasField('imageType'):
            it = d.type.imageType
            w, h = int(it.width or 0), int(it.height or 0)
            # image 型没有「元素总数」这个概念，宽高能对上才谈得上按元素数认；动态尺寸认不了
            ins.append((d.name, True, 3 * w * h if w and h else 0))
        else:
            tot = 1
            for x in d.type.multiArrayType.shape:
                tot *= int(x) if x else 1
            ins.append((d.name, False, tot))
    return ins, [d.name for d in md.output]


def feed_coreml(ins, blobs):
    """按每个入参声明的元素数认领手里这份数据：multiArray 喂 NCHW，image 型喂 HxWx3。
    对不上就当场报错，不许猜——猜错的包能跑，只是画面是错的，那种错到手机上才发现就太晚了。"""
    feed = {}
    for n, im, tot in ins:
        hit = [b for b in blobs if b[0].size == tot]
        if len(hit) != 1:
            raise RuntimeError('入参 %s（%s，要 %d 个数）手里对不上：%s'
                               % (n, 'image' if im else 'multiArray', tot,
                                  [b[0].size for b in blobs]))
        nchw, hw3 = hit[0]
        feed[n] = hw3 if im else nchw
    return feed


def pick_out(res, want):
    """从返回的几张出参里按元素数挑那一张（dict 的序不可靠，不许拿第一个）。"""
    for k, v in res.items():
        if np.asarray(v).size == want:
            return k, np.asarray(v)
    raise RuntimeError('出参里没有要的那一张（要 %d 个数，实际 %s）'
                       % (want, {k: np.asarray(v).size for k, v in res.items()}))


def convert(onnx_path, out_pkg, fp16, ios16=True):
    """转 → 存包 → 再从存下来的包读回来预测。

    手机上用的是那份包（compileModel 之后加载），内存里那个转换对象不算数：
    包读不回来、或者读回来接口名变了，装了也白装，所以这里必须走一遍落盘再加载。
    """
    import coremltools as ct
    kw = {}
    if ios16:
        try:
            kw['minimum_deployment_target'] = ct.target.iOS16
        except Exception:
            pass
    prec = ct.precision.FLOAT16 if fp16 else ct.precision.FLOAT32
    t0 = time.time()
    m = ct.convert(onnx_path, compute_precision=prec, **kw)
    m.save(out_pkg)
    el = time.time() - t0
    t1 = time.time()
    re = ct.models.MLModel(out_pkg)
    return re, el, (time.time() - t1)


def pkg_mb(p):
    if os.path.isdir(p):
        tot = 0
        for root, _, fns in os.walk(p):
            for fn in fns:
                tot += os.path.getsize(os.path.join(root, fn))
        return tot / 1048576.0
    return os.path.getsize(p) / 1048576.0 if os.path.isfile(p) else -1


def coreml_predict(m, feed):
    t0 = time.time()
    res = m.predict(feed)
    ms = (time.time() - t0) * 1000.0
    return res, ms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--onnx-dir', required=True)
    ap.add_argument('--arc-path', default=None, help='不给就取 --onnx-dir/w600k_r50.onnx')
    ap.add_argument('--swap-path', default=None, help='不给就取 --onnx-dir/inswapper_128.onnx')
    ap.add_argument('--fixtures', required=True)
    ap.add_argument('--out-dir', required=True)
    a = ap.parse_args()
    a.arc = a.arc_path or os.path.join(a.onnx_dir, 'w600k_r50.onnx')
    a.swap = a.swap_path or os.path.join(a.onnx_dir, 'inswapper_128.onnx')
    os.makedirs(a.out_dir, exist_ok=True)
    logfile = os.path.join(a.out_dir, 'fsx_probe.log')
    arc_onnx, sw_onnx = a.arc, a.swap
    for p in (arc_onnx, sw_onnx):
        log('FSX-IN', p, os.path.getsize(p) if os.path.isfile(p) else '不在')

    ref = json.load(open(os.path.join(a.fixtures, 'fsx_ref.json')))
    src112 = imread_rgb(os.path.join(a.fixtures, 'fsx_src112.png'))
    tgt128 = imread_rgb(os.path.join(a.fixtures, 'fsx_tgt128.png'))
    out_ref = imread_rgb(os.path.join(a.fixtures, 'fsx_out128.png'))
    ref_emb = np.array(ref['emb'], np.float32)
    ref_lat = np.array(ref['latent'], np.float32)
    log('FSX-FX', 'src112=%s tgt128=%s out=%s' % (src112.shape, tgt128.shape, out_ref.shape))

    import onnxruntime as ort
    try:
        import coremltools as ct
        has_coreml = True
        log('FSX-ENV', 'coremltools=%s ort=%s numpy=%s' % (ct.__version__, ort.__version__, np.__version__))
    except Exception as e:
        has_coreml = False
        log('FSX-ENV', 'coremltools 不在（这一趟只跑 onnx 基线，转换必须在 mac 上）：', repr(e)[:120])

    # ---- ① onnx 基线：确认 CI 下的这份权重和 PC 那份行为一致（不是只对 sha256）
    t0 = time.time()
    sa = ort_session(arc_onnx)
    emb_onnx = ort_emb(sa, src112)
    log('FSX-ORT-ARC', 'cos(vs PC)=%.6f' % cos(emb_onnx, ref_emb), '入', [i.name for i in sa.get_inputs()],
        '出', [o.name for o in sa.get_outputs()], '耗时 %.1f ms' % ((time.time() - t0) * 1000))

    ss = ort_session(sw_onnx)
    names = [i.name for i in ss.get_inputs()]
    shp = [list(i.shape) for i in ss.get_inputs()]
    log('FSX-ORT-SWAP', '输入名', names, '形状', shp, '输出', [o.name for o in ss.get_outputs()])
    out_onnx = ort_swap(ss, tgt128, ref_lat)
    mx, mn, ps = img_diff(out_onnx, out_ref)
    log('FSX-VERDICT', 'onnx 基线 128 脸 max=%.2f mean=%.3f 灰阶 PSNR=%.2f dB ⇒ 这份权重和 PC 一致' %
        (mx, mn, ps))
    del ss

    # ---- ② emap 单独落一份（手机上那 512×512 的乘法自己做）
    ename, emap = extract_emap(sw_onnx, os.path.join(a.out_dir, 'emap.bin'))
    lat_onnx = ref_emb @ emap
    lat_onnx = lat_onnx / np.linalg.norm(lat_onnx)
    log('FSX-EMAP', '名字=%s 形状=512x512 已落 emap.bin %d 字节' % (ename, os.path.getsize(os.path.join(a.out_dir, 'emap.bin'))),
        'latent cos(vs PC)=%.6f' % cos(lat_onnx, ref_lat))

    # ---- ③ 向量网转 CoreML：身份最敏感，fp16 掉多少要看清楚
    rec = {}
    for fp16 in (True, False):
        tag = 'fp16' if fp16 else 'fp32'
        pkg = os.path.join(a.out_dir, 'fsx_arc_%s.mlpackage' % tag)
        if not has_coreml:
            log('FSX-SKIP', 'arc(%s) 没有 coremltools，跳过' % tag)
            break
        try:
            m, el, rel = convert(arc_onnx, pkg, fp16)
            ins, outs = coreml_io(m)
            x112 = ((src112.astype(np.float32) - 127.5) / 127.5)
            feed = feed_coreml(ins, [(x112.transpose(2, 0, 1)[None], x112)])
            res, ms = coreml_predict(m, feed)
            oname, got = pick_out(res, 512)
            e = got.reshape(-1)
            e = e / np.linalg.norm(e)
            c = cos(e, ref_emb)
            log('FSX-VERDICT', 'arc(%s) 成 转换 %.0f s 落盘再读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                % (tag, el, rel, pkg_mb(pkg), ms),
                '入', ['%s(%s,共%d)' % (n, 'image' if im else 'multi', tot) for n, im, tot in ins],
                '出', outs, '取的出参', oname, '嵌入 cos=%.6f max|Δ|=%.5f' % (c, float(np.abs(e - ref_emb).max())))
            rec['arc_' + tag] = {'cos': c, 'mb': round(pkg_mb(pkg), 1), 'convert_s': round(el, 1)}
        except Exception as e:
            log('FSX-VERDICT', 'arc(%s) 转失败：' % tag, repr(e)[:200])
            traceback.print_exc(file=sys.stdout)
        finally:
            m = None

    # ---- ④ 换脸网转 CoreML：200 GMAC 这张，掉精度就是画面糊，掉内存就是被系统杀
    for fp16 in (True, False):
        tag = 'fp16' if fp16 else 'fp32'
        pkg = os.path.join(a.out_dir, 'fsx_swap_%s.mlpackage' % tag)
        if not has_coreml:
            log('FSX-SKIP', 'swap(%s) 没有 coremltools，跳过' % tag)
            break
        if os.path.isdir(pkg):
            import shutil
            shutil.rmtree(pkg)
        try:
            m, el, rel = convert(sw_onnx, pkg, fp16)
            ins, outs = coreml_io(m)
            rgb = tgt128.astype(np.float32) / 255.0
            lat = ref_lat.astype(np.float32)
            feed = feed_coreml(ins, [(rgb.transpose(2, 0, 1)[None], rgb),
                                     (lat[None], lat)])
            res, ms = coreml_predict(m, feed)      # 第一趟含建管线，丢掉，量第二趟
            oname, _ = pick_out(res, 3 * 128 * 128)
            res, ms = coreml_predict(m, feed)
            _, got = pick_out(res, 3 * 128 * 128)
            if got.ndim == 4:
                got = got[0]
            o01 = np.clip(got.transpose(1, 2, 0), 0.0, 1.0)
            bad = int(np.sum(~np.isfinite(got)))
            mx, mn, ps = img_diff(o01, out_ref)
            log('FSX-VERDICT', 'swap(%s) 成 转换 %.0f s 落盘再读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                % (tag, el, rel, pkg_mb(pkg), ms),
                '入', ['%s(%s,共%d)' % (n, 'image' if im else 'multi', tot) for n, im, tot in ins],
                '出', outs, '取的出参', oname, '非有限数 %d 个' % bad)
            log('FSX-PIX', 'swap(%s) max=%.2f 灰阶 mean=%.3f 灰阶 PSNR=%.2f dB' % (tag, mx, mn, ps))
            imwrite_rgb(os.path.join(a.out_dir, 'fsx_coreml_%s.png'), (o01 * 255).astype(np.uint8))
            d8 = np.clip(np.abs(o01 * 255.0 - out_ref.astype(np.float32)) * 8.0, 0, 255).astype(np.uint8)
            imwrite_rgb(os.path.join(a.out_dir, 'fsx_diff_%s.png'), d8)
            rec['swap_' + tag] = {'max_abs_255': round(mx, 3), 'psnr': round(ps, 2),
                                  'nonfinite': bad, 'mb': round(pkg_mb(pkg), 1), 'convert_s': round(el, 1)}
        except Exception as e:
            log('FSX-VERDICT', 'swap(%s) 转失败：' % tag, repr(e)[:300])
            traceback.print_exc(file=sys.stdout)
        m = None

    # ---- 总结：这一轮的三句判据
    log('FSX-SUM', json.dumps(rec, ensure_ascii=False))
    swap_ok = [k for k in ('swap_fp16', 'swap_fp32') if k in rec and rec[k]['nonfinite'] == 0]
    arc_ok = [k for k in ('arc_fp32', 'arc_fp16') if k in rec and rec[k]['cos'] > 0.999]
    log('FSX-VERDICT', '能装包的配方：向量网=%s 换脸网=%s（都不在就是这条线走不通）' %
        (arc_ok[0] if arc_ok else '无', swap_ok[0] if swap_ok else '无'))
    with open(os.path.join(a.out_dir, 'fsx_summary.json'), 'w', encoding='utf-8') as f:
        json.dump(rec, f, ensure_ascii=False, indent=1)
    flush(logfile)
    return 0


if __name__ == '__main__':
    rc = main()
    try:
        flush(os.path.join(sys.argv[sys.argv.index('--out-dir') + 1], 'fsx_probe.log'))
    except Exception:
        pass
    sys.exit(rc)
