import Foundation

/// OrtShim.c 的 Swift 侧。整个文件只做三件事：把张量摊平成一维字节、填 OrtshimFeed、
/// 把 OrtshimFetch 读回 Swift 数组。所有 C 指针都只在 ortshim_run 那一次调用里存在。
///
/// 张量只有两种：f32 / i64（i64 只用于 offset 那个标量输入）。
enum OrtTensor {
    case f32(dims: [Int], data: [Float])
    case i64(dims: [Int], data: [Int64])

    var dims: [Int] {
        switch self {
        case .f32(let d, _), .i64(let d, _): return d
        }
    }

    /// 元素个数。dims 为空（标量）按 1 算，和 shim 那边的 ndims==0 口径一致。
    var count: Int {
        switch self {
        case .f32(_, let a), .i64(_, let a): return a.count
        }
    }
}

struct OrtNamedFeed {
    let name: String
    let value: OrtTensor
}

enum OrtError: Error, LocalizedError {
    case openFailed(String)
    case loadFailed(String)
    case runFailed(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "ONNX Runtime 起不来：\(m)"
        case .loadFailed(let m): return "模型加载失败：\(m)"
        case .runFailed(let m): return "推理失败：\(m)"
        case .missing(let m): return "缺 \(m)"
        }
    }
}

private func shimMessage(_ fallback: String) -> String {
    guard let p = ortshim_last_error() else { return fallback }
    let s = String(cString: p)
    return s.isEmpty ? fallback : s
}

final class OrtRuntime {
    private let engine: UnsafeMutablePointer<OrtshimEngine>

    /// intraThreads：CPU 推理线程数。iPhone 11 上 4 是稳的，再多也只是抢核。
    init(intraThreads: Int = 4, logLevel: Int = 4) throws {
        guard let e = ortshim_open(Int32(intraThreads), Int32(logLevel)) else {
            throw OrtError.openFailed(shimMessage("ortshim_open 返回空"))
        }
        engine = e
    }

    deinit { ortshim_close(engine) }

    func graph(at url: URL) throws -> OrtGraph {
        return try OrtGraph(engine: engine, path: url.path)
    }
}

final class OrtGraph {
    private var handle: UnsafeMutablePointer<OrtshimGraph>?
    let inputNames: [String]
    let outputNames: [String]

    init(engine: UnsafeMutablePointer<OrtshimEngine>, path: String) throws {
        guard let g = path.withCString({ ortshim_load(engine, $0) }) else {
            throw OrtError.loadFailed(shimMessage(path))
        }
        handle = g
        let ni = Int(ortshim_input_count(g))
        let no = Int(ortshim_output_count(g))
        var ins: [String] = []
        var outs: [String] = []
        ins.reserveCapacity(ni)
        outs.reserveCapacity(no)
        for i in 0..<ni {
            if let p = ortshim_input_name(g, Int32(i)) { ins.append(String(cString: p)) }
        }
        for i in 0..<no {
            if let p = ortshim_output_name(g, Int32(i)) { outs.append(String(cString: p)) }
        }
        inputNames = ins
        outputNames = outs
    }

    /// 显式提前释放：一张图（sv 那张 386 MB）用完就该把内存还给系统，
    /// 不能等 ARC 哪天想起 deinit。
    func close() {
        if let g = handle { ortshim_unload(g) }
        handle = nil
    }

    deinit { close() }

    /// 图吃不吃这个输入（DiT 的 offset/cache/kv 只在部分状态图里存在，
    /// Python 那边走的是 `if "offset" in ins` 的过滤，这里一一对应）。
    func takes(_ name: String) -> Bool { inputNames.contains(name) }

    /// 跑一次。feeds 里的数组在本函数返回前都被闭包罩住，指针不会失效。
    /// wants 用输出名，函数内部换成下标——shim 只收下标数组。
    func run(_ feeds: [OrtNamedFeed], wants: [String]) throws -> [OrtTensor] {
        guard let g = handle else { throw OrtError.missing("图已关闭") }
        guard !feeds.isEmpty else { throw OrtError.runFailed("一个输入都没有，这张图不用跑") }

        var wantIdx: [Int32] = []
        wantIdx.reserveCapacity(wants.count)
        for w in wants {
            guard let k = outputNames.firstIndex(of: w) else {
                throw OrtError.missing("输出 \(w)（这张图的输出是 \(outputNames.joined(separator: ","))）")
            }
            wantIdx.append(Int32(k))
        }

        var names: [CChar] = []
        var dimStore: [Int64] = []
        var plan: [(nameAt: Int, dtype: Int, dimAt: Int, ndims: Int, byteAt: Int, count: Int)] = []
        plan.reserveCapacity(feeds.count)

        // 每个 feed 单独一块 64 字节对齐的原始缓冲：ORT 的 CPU kernel 直接把这个指针
        // 当 float* / int64_t* 读，而 [UInt8] 摊平出来的偏移只保证 1 字节对齐。
        // 名字用一整块 [CChar]（char 只要 1 字节对齐）、形状用一整块 [Int64]
        // （Swift 数组基址 8 字节对齐，偏移都是 8 的倍数，天然够用）。
        var bufs: [UnsafeMutableRawPointer] = []
        bufs.reserveCapacity(feeds.count)
        defer { for p in bufs { p.deallocate() } }

        for f in feeds {
            let nameAt = names.count
            names.append(contentsOf: Array(f.name.utf8))
            names.append(0)
            let d = f.value.dims
            let dimAt = dimStore.count
            dimStore.append(contentsOf: d.map { Int64($0) })
            let cnt: Int
            let dtype: Int
            switch f.value {
            case .f32(_, let a):
                dtype = Int(ORTSHIM_F32)
                cnt = a.count
                let p = UnsafeMutableRawPointer.allocate(byteCount: max(a.count * 4, 1),
                                                          alignment: 64)
                a.withUnsafeBytes { raw in
                    if let src = raw.baseAddress, a.count > 0 {
                        p.copyMemory(from: src, byteCount: a.count * 4)
                    }
                }
                bufs.append(p)
            case .i64(_, let a):
                dtype = Int(ORTSHIM_I64)
                cnt = a.count
                let p = UnsafeMutableRawPointer.allocate(byteCount: max(a.count * 8, 1),
                                                          alignment: 64)
                a.withUnsafeBytes { raw in
                    if let src = raw.baseAddress, a.count > 0 {
                        p.copyMemory(from: src, byteCount: a.count * 8)
                    }
                }
                bufs.append(p)
            }
            plan.append((nameAt, dtype, dimAt, d.count, bufs.count - 1, cnt))
        }
        // 空数组的 baseAddress 是 nil，下面全是 ! 取法；垫一个不会被引用到的占位元素。
        if dimStore.isEmpty { dimStore = [0] }

        var fetch = [OrtshimFetch](repeating: OrtshimFetch(dtype: 0, ndims: 0, dims: nil,
                                                           count: 0, data: nil),
                                   count: max(wants.count, 1))

        return try names.withUnsafeBufferPointer { nb in
            try dimStore.withUnsafeBufferPointer { db in
                try bufs.withUnsafeBufferPointer { pb in
                    let structs = plan.map { p in
                        OrtshimFeed(name: nb.baseAddress!.advanced(by: p.nameAt),
                                    dtype: Int32(p.dtype),
                                    dims: db.baseAddress!.advanced(by: p.dimAt),
                                    ndims: Int32(p.ndims),
                                    data: UnsafeRawPointer(pb.baseAddress![p.byteAt]),
                                    count: Int64(p.count))
                    }
                    let rc = structs.withUnsafeBufferPointer { sb in
                        wantIdx.withUnsafeBufferPointer { ib in
                            fetch.withUnsafeMutableBufferPointer { ftb in
                                ortshim_run(g, sb.baseAddress, Int32(structs.count),
                                            ib.baseAddress, Int32(wantIdx.count), ftb.baseAddress)
                            }
                        }
                    }
                    if rc != 0 {
                        throw OrtError.runFailed(shimMessage("ortshim_run 返回 \(rc)"))
                    }

                    var out: [OrtTensor] = []
                    out.reserveCapacity(wants.count)
                    for i in 0..<wants.count {
                        let f = fetch[i]
                        let n = Int(f.count)
                        let dims: [Int]
                        if let dp = f.dims, f.ndims > 0 {
                            dims = UnsafeBufferPointer(start: dp, count: Int(f.ndims)).map { Int($0) }
                        } else {
                            dims = []
                        }
                        if f.dtype == Int32(ORTSHIM_F32) {
                            var vals: [Float] = []
                            if let p = f.data, n > 0 {
                                vals = [Float](UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self),
                                                                   count: n))
                            }
                            out.append(.f32(dims: dims, data: vals))
                        } else if f.dtype == Int32(ORTSHIM_I64) {
                            var vals: [Int64] = []
                            if let p = f.data, n > 0 {
                                vals = [Int64](UnsafeBufferPointer(start: p.assumingMemoryBound(to: Int64.self),
                                                                   count: n))
                            }
                            out.append(.i64(dims: dims, data: vals))
                        } else {
                            ortshim_release(&fetch, Int32(wants.count))
                            throw OrtError.runFailed("输出 \(wants[i]) 的类型 shim 不认识（\(f.dtype)）")
                        }
                    }
                    ortshim_release(&fetch, Int32(wants.count))
                    return out
                }
            }
        }
    }
}
