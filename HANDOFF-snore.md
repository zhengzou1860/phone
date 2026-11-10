# SnoreBench 交接（2026-11-10，由上一会话 a291c331 压缩生成）

任务原文：在 iPhone 11 上写睡眠打鼾记录 app，记录响度、频率、是否突然中断，医学观察用途。分发流程参照 iPhone video cut。

## 现在在哪
- 仓库 `E:\Python project\Phone`，分支 `snore`。v0.11（`app/project-snore.yml` 0.10→0.11、build 11），CI 产物 `snore.ipa` 走 `channel-snore`，SideStore 安装。
- 0.11 两件事，都是用户原话「去掉app里的录音，只留记录。手机里出的报告太复杂，看不懂，写成普通人看得懂内容」：
  1. **不再存录音片段**。麦克风整晚照开（判定要用），但 8 秒环形缓冲、WAV 写盘、播放、「听」按钮、设置里的片段开关全删了。落盘只剩 curve.csv / events.jsonl / report.txt / meta.json，一晚约 1 MB；开录磁盘门槛 500 MB→60 MB。老晚上遗留的 `snippets/` 目录不主动删（用户数据），随 14 晚保留期自然淘汰。
  2. **报告改大白话**。`SnoreAnalyze.reportText` 重写成【一句话】＋几行「打鼾多久／分几段／什么时候打的／响不响／打鼾节奏」＋【建议】【怎么算的】【说明】，术语（dBFS、频谱分、盲区线、判定口径六条）一律不进报告。约 700–850 字，旧版约 1878 字。
- **判定路径一个字没改**：absGateDb −58、六项打分权重、enterScore 0.68/0.60/0.52、0.10 的连续背景声剔除全部原样。
- 历史页打开老晚上时**就地重算报告**，不读盘上那份 report.txt——0.11 以前存的是满屏术语的旧文案，曲线和事件都在，重算就能让老晚上也读得懂。
- 报告文案已拿 8 个真实晚上（11-04 两场试录 + 11-05/06/07×2/09×2/10）在 Python 移植版上逐晚渲染核对：无术语、开头定性与【建议】不分裂。移植版 `Temp/snore_probe/plain_report.py`，全量核对 `check_all.py`。
- CI 新增守门：合成样例报告里出现 dBFS/频谱分、或少了【一句话】就 FAIL。

## 待办（按序）
1. 确认 CI 出 0.11 的 ipa；出了就让他下载。
2. 用 0.11 跑一整晚：看白话报告读不读得懂、内存增长（此前约 +19–21 MB/h）有没有因为去掉环形缓冲而缓解。
3. 每晚报告照旧格式生成：`E:\Python project\AI doctor\i watch\export\snore_YYYY-MM-DD\README.md` + `ANALYSIS.md`。取数来源是 app「发到电脑」落地的每晚目录（meta.json + curve.csv + events.jsonl + report.txt）。**0.11 起 report.txt 是白话版，不含技术数字**——要重算占比/盲区/分级一律从 curve.csv 取，别从报告里抄。

## 代码地图（只列入口，别整读 13 个文件）
- `app/SourcesSnore/` 13 个 Swift：`SnoreAudio.swift` AVAudioEngine 采集＋1Hz 看门狗重连（0.11 删掉了 SnoreSnippetRing/SnoreWav）；`SnoreDetect.swift` 自写 radix-2 DIT FFT 4096 点 @48kHz；`SnoreTrack.swift` 「一次发声」收口判定（等静音 0.30s 后总账）；`SnoreStore.swift` 每晚一目录持久化（0.11 删掉 snippets 那一摊）；`SnoreReport.swift` 汇总＋白话报告＋连续背景声剔除（0.11 主要改这里）；`SnoreSynth.swift` CI 合成用例；`SnoreMonitor/SnoreUI/SnoreChart/SnoreCommon/SnoreConfig/SnoreCore/SnoreApp`。
- 关键参数：响度门 `absGateDb` = −58 dBFS；盲区线 0.75；三关＝段长形状分 ≥0.60 ＋ 频谱像鼾分 ≥ 判定线 ＋ 帧间稳定度 ≥0.72；需配邻鼾间隔 1–10s。
- curve.csv 列序（位置敏感，`maxScoreNoGate` 必须留在最后）：`t0,maxDb,meanDb,snoreSec,vocalSec,maxScore,floorDb,stale,maxScoreNoGate`。`SnoreNightMeta` 不要加非可选字段；`SnoreSummary` 不是 Codable（每次重算），加减字段安全。
- 自测：`ci/snoreselftest/main.swift`；PC 端服务 `tools/report_server_snore.py`（0.0.0.0:8717，GET /ping→200，落地 `tools/phone-reports-snore.txt`）。

## 已证伪，别再走
- 「电脑嗡嗡声造成的」→ 已撤回：没开电脑那晚底噪 −86.0、有电脑 −85.6，相邻分钟几乎不变比例两晚都是 59.7%。
- 「打分公式白送分」→ 已证伪：app 内置模拟房间噪声跑同一算法最高 0.696，过不了 0.75。
- 「用音调低不低滤机器声」→ 不通，风扇也是低音。「用一呼一吸节奏滤」→ 从导出数据量不出来。
- 有效判据只有一个：**打鼾跟呼吸走，必有间隙**；整晚每秒都在响的一定不是人（真鼾 31s 相邻两秒变 5.0dB，那片 26,885s 只变 1.05dB）。
- 「按鼾声高出底噪多少分贝分轻/响档」→ 不通：门 = max(底噪+4, −58)，房间一安静任何判成鼾的声音都高出底噪 25 dB 以上，会把每一晚都写成「比较响」。报告只给差值、不下断语。

## 坑
- Windows 这台**没有 Swift 工具链**，CI 是唯一的编译器：一个编译错误就要浪费一整轮 CI。改完先在脑子里过一遍类型（元组标签要显式写、别留未使用的绑定变量）。
- 控制台是 GBK：跑 Python 一律带 `PYTHONIOENCODING=utf-8`；中文字面量别经 bash heredoc 传，用 Write 工具写 .py。
- 分析脚本全在 `C:\Users\Administrator\AppData\Local\Temp\snore_probe\*.py`（60+ 个），Temp 会被清，重要结论要落到 export 的 md 里才算存住。
- 提交时只 stage 自己明确列出的文件；仓库里 Cut.swift、project.yml、`.wt-*` 等是别的 app 线的未提交改动/别人的在制品，不要 add、stash、删或回退。不碰 main 和别的 app 的 release channel。
- 报告数字必须能对上曲线文件，历史上有过两次改了又更正的结论，改口径要在 ANALYSIS.md 里写明「上一条撤回」。
- 措辞红线：未复鼾那条**不算中断**、也**不许写成「起床」**（用户是整晚睡到醒的）；没判成鼾的声音**不许猜**是说话/咳嗽/翻身；「鼾声停住」量的是鼾声安静了多久，不是呼吸停了多久，几分钟那种多半是整段没打鼾。
