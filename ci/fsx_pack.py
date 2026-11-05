# -*- coding: utf-8 -*-
"""把两张 onnx（w600k_r50＋hyperswap_1a_256）转成手机上的两份 mlpackage，跟 PC 的标准答案对完账，
再打成 models.bin＋models.json，外加一份 chain.txt 口径标记。

这一条是「将来真装到手机上」那一条，不是探针：探针在 mac runner 上量过 fp16 的代价（上一代 128 换脸网
差 74 个灰阶、PSNR 29.5 dB）。所以这里只转 fp32、一遍、不留第二条配方；对账不过就地失败，一个文件都不发。

帮手全从 fsx_probe 里拿（load_onnx_fixed／convert／feed_coreml／pick_out／img_diff）。
那个文件里每一式都在 mac runner 上跑绿过，在这儿重写一遍就是重新赌一遍。

判据分三层，少一层都可能把「能跑但画面是错的」发出去：
  ① onnxruntime 对账：证明 CI 下到的这两份权重和 PC 那两份逐字节是同一个行为（字节数只是第一道）；
  ② 转换器自己 --verify：证明 MIL 改写没把数算歪；
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
WANT_BYTES = {
    'w600k_r50.onnx': 174383860,
    'hyperswap_1a_256.onnx': 402742682,
}
RECIPE = b'fsx-models|hyperswap_1a_256|fp32|mlpackage|v2'
ARC_PKG = 'fsx_arc'
SWAP_PKG = 'fsx_swap'
# 手机上 haveAll() 认的口径标记：资源名没变（fsx_swap.mlpackage），旧版同名包光看名字分不出来
CHAIN_TAG = 'hyperswap-1a-256'
SIDE = 256
# 这两条是「还换不换得对那个人」的底线：PC↔CoreML 实测 fp32 是 cos=1.000000／PSNR≈53，
# 闸门放在远低于实测、远高于坏值的地方，坏值长什么样探针里也有（fp16 那趟 PSNR 29.5）。
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
    ap.add_argument('--onnx-dir', required=True, help='放 w600k_r50.onnx／hyperswap_1a_256.onnx 的目录')
    ap.add_argument('--fixtures', required=True, help='ci/fsx_fixtures：PC 出的标准答案')
    ap.add_argument('--out-root', default='app/SwapModel',
                    help='两份 mlpackage＋chain.txt＋models.bin/json 落这里（不能落进 SourcesSwap，xcodegen 会把 mlpackage 当编译输入）')
    ap.add_argument('--cli', default=None, help='onnx2coreml 可执行文件路径；不给就在 PATH 里找')
    a = ap.parse_args()

    arc_onnx = os.path.join(a.onnx_dir, 'w600k_r50.onnx')
    sw_onnx = os.path.join(a.onnx_dir, 'hyperswap_1a_256.onnx')
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

    # ---- ② 钉死符号维后落盘（转换器只认文件；w600k_r50 的 batch 维是 pytorch 1.8 留的 None）
    tmp = os.path.join(os.environ.get('RUNNER_TEMP', '/tmp'), 'fsxpack')
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    import onnx
    arc_fixed = os.path.join(tmp, 'fsx_arc_fixed.onnx')
    sw_fixed = os.path.join(tmp, 'fsx_swap_fixed.onnx')
    arc_model = P.load_onnx_fixed(arc_onnx)
    sw_model = P.load_onnx_fixed(sw_onnx)
    onnx.save(arc_model, arc_fixed)
    onnx.save(sw_model, sw_fixed)

    # ---- ④ 两张各转 fp32 一遍，转完立刻从盘上读回来对账
    rec = {}
    fails = []
    plan = [(ARC_PKG, arc_model, arc_fixed, 'arc'), (SWAP_PKG, sw_model, sw_fixed, 'swap')]
    for pkg_name, model, fixed, which in plan:
        pkg = os.path.join(a.out_root, pkg_name + '.mlpackage')
        try:
            m, el, rel = P.convert(model, pkg, False, fixed, cli)
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
                rec['arc'] = {'cos': c, 'max_abs': mdelta, 'mb': round(P.pkg_mb(pkg), 1),
                              'convert_s': round(el, 1), 'infer_ms': round(ms, 1)}
                P.log('FXP-VERDICT', 'arc(fp32) 成 转换 %.0f s 读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                      '｜入 %s 出 %s 取的出参 %s｜嵌入 cos=%.6f max|Δ|=%.5f'
                      % (el, rel, P.pkg_mb(pkg), ms,
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
                rec['swap'] = {'psnr': ps, 'max_abs': mx, 'nonfinite': bad,
                               'mb': round(P.pkg_mb(pkg), 1),
                               'convert_s': round(el, 1), 'infer_ms': round(ms, 1)}
                P.log('FXP-VERDICT', 'swap(fp32) 成 转换 %.0f s 读回 %.1f s 包 %.1f MB 一次推理 %.1f ms'
                      '｜入 %s 出 %s 取的出参 %s｜非有限数 %d 个'
                      % (el, rel, P.pkg_mb(pkg), ms,
                         ['%s(%s,共%d)' % (n, 'image' if im else 'multi', t) for n, im, t in ins],
                         outs, oname, bad))
                P.log('FXP-PIX', 'swap(fp32) max=%.2f mean=%.3f 灰阶 PSNR=%.2f dB' % (mx, mn, ps))
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
