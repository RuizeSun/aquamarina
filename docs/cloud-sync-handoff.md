# 云同步开发交接文档

> 目标读者：接手本项目的下一个开发者 / 智能体。  
> 本文只描述：项目背景、云同步现有功能、已知问题、可改善方向。  
> 更细的协议设计见 `docs/cloud-sync-spec.md`，用户配置说明见 `docs/cloud-sync-setup.md`。

---

## 1. 项目速览

- 产品：**Aquamarina**，基于 Flutter 的英语学习应用（离线词典、背单词、AI 句型练习、TTS）。
- 平台：Android / iOS / Windows（未启用 Web）。
- Flutter / Dart：本机 Flutter 3.47 / Dart 3.13；CI 使用 Flutter 3.44.8；`pubspec.yaml` SDK `^3.11.5`。
- 状态管理：`ChangeNotifier` / 单例服务为主，没有引入 Provider/Riverpod/Bloc。
- 本地存储：
  - 业务数据：SQLite（`sqflite` + `sqflite_common_ffi`），当前 **schemaVersion = 14**；
  - 设置：`SharedPreferences`；
  - 密钥：`flutter_secure_storage`；
  - 备份：ZIP（`aquamarina.db` + `preferences.json` + 可选 `secure_storage.json` + `backup_meta.json`）。
- 主要目录：
  - `lib/services/`：数据库、备份、同步、AI、TTS 等；
  - `lib/pages/`：页面；
  - `lib/models/`：数据模型；
  - `test/`：单元/组件/真实 S3 集成测试；
  - `docs/`：设计与配置文档。
- 常用命令：

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

- 真实对象存储集成测试（默认跳过，需要环境变量）：

```powershell
$env:S3_ENDPOINT='cn-nb1.rains3.com'
$env:S3_BUCKET='<bucket>'
$env:S3_REGION='cn-nb1'
$env:S3_ACCESS_KEY='<access-key>'
$env:S3_SECRET_KEY='<secret-key>'
$env:S3_PREFIX='aquamarina-ci'
flutter test test/cloud_sync_s3_integration_test.dart
```

> 仓库中不要写入任何 AK/SK。测试桶凭据只通过环境变量传入。

---

## 2. 云同步功能现状

### 2.1 用户可见能力

设置页路径：`设置 → 云同步`。当前提供：

1. **对象存储配置**
   - S3 兼容端点、桶、区域、路径前缀、path-style、保留份数、AK/SK；
   - 保存前做真实读写自检（Bucket / PUT / GET / LIST / DELETE）；
   - 设备名称与设备 ID 展示、重置设备标识、清除配置。
2. **增量同步**
   - 手动「增量同步」；
   - 启动 5 秒后自动启动前台轮询；
   - 回到前台立即尝试一次，后台停止轮询；
   - 学习结束（学习/复习/拼写/词汇测试/句型练习）后 2 秒防抖触发即时同步；
   - 默认前台间隔 5 分钟，可配置 1/5/15/30 分钟；
   - 同步结果展示拉取/上传数量、冲突数、待上传数量与告警/冲突明细。
3. **完整快照**
   - 「立即上传备份」：把本机数据库 + 设置打包为 ZIP 上传到本设备目录；
   - 「从云端恢复」：列出所有设备快照，校验 SHA-256 后覆盖导入；
   - 恢复前自动保留本机数据库快照，失败可回滚。
4. **安全与隐私**
   - AK/SK 只存本机 Secure Storage，不进入备份、不上传云端；
   - 快照默认不包含 AI API Key，上传时可显式勾选；
   - 云同步配置（`cloud_sync_*`）是设备本地设置，备份导出/恢复都会跳过。

### 2.2 总体架构

```
本地写入（所有业务服务）
   │
   ▼ SQLite 触发器（与写入同事务，capture_enabled=1 时）
oplog_<entity>（本地待上传操作）
   │  SyncCaptureService：分配 HLC → JSONL chunk → 记录本地行版本
   ▼
S3: devices/{deviceId}/chunks/{hlc}-{sha16}.jsonl   ← 不可变，只追加
S3: devices/{deviceId}/snapshots/{timestamp}.zip    ← 完整快照
S3: devices/{deviceId}/manifest.json                ← 快照索引（最后写）
   │
   ▼
SyncApplyService（单事务、幂等、HLC/行版本/墓碑）
   │
   ▼
本地业务表 + sync_applied / sync_chunks / sync_row_versions / sync_tombstones
```

核心设计：

- **每台设备只写自己的前缀**：不存在跨设备覆盖同一对象的冲突；
- **oplog 捕获与业务写入同事务**：数据落库 ⇒ 变更已记录；
- **chunk 不可变**：重传幂等，远端按 `(device_id, entity, seq)` 去重；
- **HLC + 行版本 + 墓碑**：乱序/迟到操作不会覆盖新数据；

### 2.3 代码地图

| 文件 | 职责 |
|---|---|
| `lib/services/cloud_sync_settings.dart` | 非敏感配置、Secure Storage 凭据、设备 ID/名称、运行状态、配置校验 |
| `lib/services/s3_storage_service.dart` | MinIO 客户端封装：PUT/GET/HEAD/LIST/DELETE、超时、错误中文化、连接自检 |
| `lib/services/cloud_sync_service.dart` | 完整快照：上传、设备清单、恢复、历史保留、恢复前本机快照 |
| `lib/services/cloud_sync_engine.dart` | 增量同步编排：拉取远端 chunk → 应用；推送本机 chunk；基线过滤；调用 GC |
| `lib/services/cloud_sync_auto_sync_service.dart` | 启动 / 回前台自动同步，按配置间隔冷却，手动可复用 |
| `lib/services/cloud_sync_foreground_sync_service.dart` | 前台 `Timer.periodic` 轮询、生命周期启停、事件同步后重置计时 |
| `lib/services/cloud_sync_activity_sync_service.dart` | 学习结束事件同步：2 秒防抖、push 优先、按需 pull |
| `lib/services/cloud_sync_maintenance_service.dart` | 保守 chunk GC：每设备保留 1000 个 + 180 天、7 天冷却 |
| `lib/services/sync_table_spec.dart` | 同步表单一规格（键/数据列/计数列/LWW 列），生成 oplog 表与触发器 |
| `lib/services/sync_schema.dart` | 同步系统表、触发器安装、恢复后运行时状态重置 |
| `lib/services/sync_capture_service.dart` | HLC 分配、JSONL chunk 导出、本地行版本、上传后清理 |
| `lib/services/sync_apply_service.dart` | 幂等应用、行版本门禁、自然时间戳 LWW、计数增量、墓碑、父级重试 |
| `lib/models/sync_op.dart` | op/HLC 模型、JSONL 编解码 |
| `lib/models/cloud_sync_manifest.dart` | 快照清单/快照元信息、格式版本、SHA-256、对象键工具 |
| `lib/pages/settings/sections/cloud_sync_section.dart` | 设置页云同步分区与同步结果 UI |
| `lib/pages/settings/cloud_sync_config_page.dart` | 对象存储配置表单、连接测试、自动同步间隔、设备标识管理 |
| `lib/services/backup_service.dart` | ZIP 备份/恢复；保护 `cloud_sync_*` Prefs；恢复后重置同步运行时并写基线 |

### 2.4 云端对象布局

```
{prefix}/
└── devices/{deviceId}/
    ├── manifest.json
    ├── snapshots/{utcTimestamp}.zip
    └── chunks/{hlcMsHex}-{hlcCounterHex}-{sha256前16位}.jsonl
```

- `prefix` 默认 `aquamarina`；
- `deviceId` 为本机 UUID v4；
- chunk 键包含首个 op 的 HLC 与内容哈希，按字典序近似按时间排序；
- `manifest.json` 在快照 ZIP 上传成功后最后写入；
- **当前没有** `head.json` / `state.json`，尽管 `CloudSyncConfig.stateKey()` 已定义但未使用。

`manifest.json` 字段：

```json
{
  "format_version": 1,
  "device_id": "...",
  "device_name": "...",
  "schema_version": 14,
  "app_version": "1.3.0+22",
  "updated_at": "...",
  "snapshots": [
    {
      "key": ".../snapshots/20261017T130719123Z.zip",
      "size": 1834200,
      "sha256": "…",
      "created_at": "...",
      "contains_api_keys": false
    }
  ]
}
```

### 2.5 事件模型

每条 op：

```json
{
  "v": 1,
  "device_id": "uuid",
  "seq": 42,
  "hlc": "000001a14a57b3e7:00000000",
  "entity": "word_notes",
  "key": {"word": "apple"},
  "op": "upsert",
  "data": {"note": "...", "is_favorited": 1, "updated_at": "..."},
  "delta": {},
  "deleted_at": null
}
```

- `seq`：单表内自增，用于 `(device_id, entity, seq)` 去重；
- `hlc`：混合逻辑时钟（毫秒 + 计数），在导出 chunk 时分配并持久化；
- `op`：`upsert` / `delete`；
- `delta`：计数类字段增量（复习次数、错题次数、每日统计）；
- 排序键：`(hlc, entity, seq)`。

### 2.6 本地同步表

| 表 | 用途 | 是否清理 |
|---|---|---|
| `sync_meta` | 单行：设备 ID、`applying`、HLC、基线、`capture_enabled` | 不清理 |
| `sync_applied` | 已应用远端 `(device_id, entity, seq)` | **不清理（已知问题）** |
| `sync_chunks` | 已应用 chunk key + sha256 | 仅 GC 删除对应远端 chunk 时清理 |
| `sync_row_versions` | 每实体键的最新 HLC，LWW 门禁 | 不清理（规模≈实体数） |
| `sync_tombstones` | 删除墓碑 | 不清理（已知问题） |
| `oplog_<entity>` | 待上传操作（每同步表一张） | 上传成功后删除 |

同步表共 14 张，见 `SyncSpecs.all`；`sentence_eval_cache`、`ai_usage_records`、`ai_estimate_samples` 明确不同步。

### 2.7 捕获机制

- 每张同步表 3 个触发器：`AFTER INSERT / UPDATE / DELETE`；
- 触发条件：
  ```sql
  (SELECT applying FROM sync_meta WHERE id = 1) = 0
  AND (SELECT capture_enabled FROM sync_meta WHERE id = 1) = 1
  ```
- `capture_enabled` 默认 **0**：未配置云同步时不记录 oplog；保存配置 / 引擎运行时开启；清除配置关闭并清空 oplog；
- 计数列在触发器中计算增量（INSERT：NEW；UPDATE：NEW-OLD）；
- 触发器写入类型化 oplog 表，不依赖 SQLite JSON1（兼容 Android 系统 SQLite）。


### 2.8 一次增量同步的流程

```
1. 确保 sync_meta.device_id 与 capture_enabled=1
2. LIST {prefix}/devices/（递归）
3. 过滤 */chunks/*.jsonl
4. 跳过：自己设备的 chunk、本地 sync_chunks 已记录的、早于 baseline_hlc 的
5. 按对象 key（HLC 前缀）排序
6. 逐个 GET → 校验 SHA-256 前 16 位 → 解码 JSONL
7. SyncApplyService.applyOps（单事务）
   - sync_applied 去重
   - 行版本门禁
   - 按表语义应用
   - 缺失父级的 op 不记录 applied，后续重试
8. 应用成功后写入 sync_chunks
9. 本机推送：
   - takePendingBatch：分配 HLC、记录 sync_row_versions、切 500 op / 900 KB
   - PUT 到自己的 chunks/
   - markUploaded 删除本地 oplog
   - 最多 20 批 / 次
10. 每 7 天执行一次保守 GC（1000 chunk/设备 + 180 天）
```

### 2.9 表级合并语义

| 实体 | 语义 |
|---|---|
| `user_word_records` | 字段 LWW（`last_reviewed_at` + 行版本）；`review_count` 增量累加 |
| `wrong_words` | 行 LWW / delete |
| `word_notes` / `sentence_notes` | 笔记/收藏 LWW（`updated_at`），delete = 墓碑 |
| `daily_activity` | 四个计数增量累加；`completed/daily_goal` LWW |
| `word_books` | UUID 键，字段 LWW（`updated_at`），delete 级联条目 |
| `word_book_entries` | `(book_uuid, word)` grow-only；缺少父书时重试 |
| `sentences` | `id` 键，行 LWW；`sort_index` 保序 |
| `sentence_sets` | v14 起在 SQLite；`updated_at` LWW，delete 级联句子/进度/错题 |
| `attempted_sentence_ids` / `practiced_sentence_ids` | grow-only 集合 |
| `wrong_sentences` | `wrong_count` 增量；`last_wrong_at` 取新；delete 墓碑 |
| `learning_sessions` | UUID 键；`duration_seconds` 取较新事件 |
| `vocab_test_history` | UUID 键，幂等插入 |

### 2.10 快照与恢复

- 上传：`BackupService.exportBackup` → SHA-256 → PUT ZIP → 更新 manifest → 按 `retainCount` 清理旧 ZIP；
- 恢复：
  1. 下载并校验 size + SHA-256；
  2. 恢复前 `VACUUM INTO` 本机快照；
  3. `BackupService.importBackup` 覆盖 DB / Prefs；
  4. 重新打开数据库后调用 `SyncSchema.resetRuntimeState`：
     - 清空快照携带的 oplog；
     - 保留 `sync_applied` / `sync_chunks` / 行版本 / 墓碑（快照已包含其效果）；
     - 清空 `sync_meta.device_id`，写入 `baseline_hlc = 备份创建时间`；
  5. 引擎拉取时跳过 HLC ≤ baseline 的 chunk，避免历史计数重复累加。

### 2.11 触发时机

| 触发 | 实现 |
|---|---|
| 冷启动 | 启动 5 秒后 `CloudSyncForegroundSyncService.start()`，首次 tick 立即尝试 |
| 回到前台 | `AppLifecycleListener.onResume` → start（内部受间隔冷却） |
| 切后台 | `onHide/onPause` → stop，取消轮询 |
| 前台轮询 | 默认 5 分钟，配置 1/5/15/30 |
| 学习结束 | `CloudSyncActivitySyncService.notifyLearningCompleted()`，2 秒防抖；完成后重置轮询 |
| 手动 | 设置页「增量同步」；同时重置轮询计时 |
| 失败重试 | 静默；下一次事件/轮询/回前台重试 |

学习结束钩子：
- `LearningService.saveLearningBatchResults`（学习/复习/拼写，含每日统计）
- `LearningService.saveVocabTestResult`
- `LearningService.markAsMasteredBatch` / `resetMasteredBatch`
- `AiPracticeSessionPage._exitPractice`

### 2.12 配置与默认值

| 项 | 默认值 |
|---|---|
| 前缀 | `aquamarina` |
| 快照保留份数 | 5（1–50） |
| chunk 批量 | 500 op / 900 KB |
| 前台自动同步 | 开启 |
| 自动同步间隔 | 5 分钟（1/5/15/30，校验范围 1–60） |
| 学习结束防抖 | 2 秒 |
| 每次 run 最大推送批数 | 20 |
| chunk GC | 7 天冷却；每设备 1000 个；180 天 |
| 备份大小上限 | 500 MB |
| 数据库 schema | 14 |
| 凭据存储 | Secure Storage：`cloud_sync_access_key` / `cloud_sync_secret_key` |
| 非敏感配置 | Prefs：`cloud_sync_config_v1`、`cloud_sync_state_v1`、`cloud_sync_device_id_v1`、`cloud_sync_device_name_v1` |

### 2.13 测试现状

- `flutter test`：无 S3 环境变量时 **195 passed / 3 skipped**；
- 含真实 S3：**198 passed**；
- 覆盖：
  - v13/v14 迁移、UUID/顺序回填、触发器数量与抑制；
  - 捕获开关、HLC 单调、chunk 编解码、上传后清理；
  - 应用引擎：幂等、行版本门禁、计数增量、墓碑/复活、LWW、词书父级重试、句式集级联；
  - 引擎：远端拉取、推送、缺失父级重试、上传失败重试、损坏 chunk、基线；
  - 前台轮询：start/stop/reset、fake_async；
  - 学习结束事件：防抖合并、无变更跳过、到期 pull、关闭自动同步；
  - 真实 Rain S3：连接自检、设备清单、双设备增量收敛。

当前分支：`feat/cloud-sync`（未 push）。提交：

```
0cdefd9 feat(sync): sync after learning sessions and poll in foreground
93d54cf test(sync): cover conflict details, upload retry and corrupted chunks
4b483f6 feat(sync): migrate sentence sets to SQLite for incremental sync
20be210 feat(sync): add auto sync, capture gating and conservative chunk GC
9ee7c7f feat(sync): add v13 oplog capture, apply engine and S3 incremental sync
d8adb0f test(cloud-sync): add settings section widget smoke test
7682c24 feat(cloud-sync): add device-scoped S3 snapshot backup and restore
```


---

## 3. 当前存在的问题（按优先级）

### P0-1：每次同步全量 LIST 云端 chunk

**现象**：`CloudSyncEngine._pull` 每次 `LIST {devicesPrefix}/` 递归，再在内存过滤。  
**后果**：对象数增长后延迟、请求成本、内存与限流风险；前台 5 分钟轮询会持续 LIST。  
**根因**：缺少每设备 `head.json` / `state.json` 水位对象；`CloudSyncConfig.stateKey()` 已定义但未使用；`sync_state` 表已创建但未使用。  
**相关**：`cloud_sync_engine.dart`、`cloud_sync_settings.dart`、`sync_schema.dart`。

### P0-2：快照全量进内存，移动端有 OOM 风险

**现象**：`BackupService.exportBackup` 返回 `Uint8List`；`CloudSyncService.uploadSnapshot` PUT 整个字节数组；下载同样 `getBytes` 整包。  
**后果**：DB 100 MB 时峰值可能 200–300 MB；500 MB 为硬上限。  
**根因**：快照链路没有流式 ZIP / 分片上传 / 流式解压。

### P0-3：`sync_applied` 与墓碑永久增长

**现象**：远端每个 op 写入 `sync_applied`，从不清理；墓碑也不清理。  
**后果**：长期使用后本地 DB 膨胀，应用每条 op 前的去重查询变慢。  
**修复方向**：GC 删除 chunk 时按该 chunk 的 op 列表清理 `sync_applied`；墓碑按保留期/水位清理。

### P0-4：快照恢复会跳过本机自己更新的 chunk

**现象**：`_pull` 过滤 `_deviceOf(key) == deviceId`。  
**场景**：设备 A 上传 chunk → 之后恢复较旧的快照（同一设备）→ 恢复后 A 不拉取自己更新的 chunk，快照之后的本机变更不会回到本地（仍留在云端，但无法自动恢复）。  
**修复方向**：恢复后允许重放 `baseline` 之后且属于本设备的 chunk；或在恢复前明确警告“将丢失快照之后的变更”。

### P1-1：GC 按时间而非水位，可能删掉离线设备仍需要的 chunk

**现象**：每设备保留最近 1000 chunk + 只删 180 天前的对象。  
**后果**：重度用户超过 1000 chunk 或设备离线 >180 天时，旧变更可能被删。  
**修复方向**：每设备上传 `state.json`（已应用到各设备的最大 HLC）；仅删除所有活跃设备都越过的 chunk；时间作为兜底。

### P1-2：应用/推送逐条查询，缺少批量与时间预算

**现象**：
- `SyncApplyService` 每个 op 多次 `SELECT/UPDATE`；
- `SyncCaptureService.takePendingBatch` 每行一次 `UPDATE` 分配 HLC，再每行写 `sync_row_versions`；
- `CloudSyncEngine.run` 无进度、无取消、无时间预算，一次处理所有待拉取 chunk。  
**后果**：首次合并/大数据量时耗时长，占用前台与 SQLite 写锁；移动端可能被系统中断（chunk 级已可恢复）。  
**修复方向**：按实体批量 upsert、预编译语句、每 chunk 单事务（已有）；单次 run 时间预算 + 下一 tick 续跑；进度与取消。

### P1-3：批量导入放大 oplog

**现象**：导入 N 个单词 → `word_book_entries` 每次 INSERT 都触发一条 oplog，N=10 万就是 10 万条 op。  
**后果**：导入变慢、本地 DB 膨胀、上传需要多轮（引擎每次最多 20 批 = 1 万 op）。  
**修复方向**：批量导入快速路径（暂停逐行捕获，导入后写一条批量 op / 检查点）；或合并同类 op。

### P1-4：chunk 未压缩、哈希只用前 16 位

**现象**：JSONL 纯文本；chunk 文件名使用 SHA-256 前 16 位；引擎只校验前 16 位。  
**后果**：体积与带宽浪费（通常可压 5–10 倍）；校验强度低于完整哈希。  
**修复方向**：gzip 压缩；文件名/校验使用完整 SHA-256。

### P1-5：运行并发没有全局锁

**现象**：手动同步、自动同步、学习结束事件同步各自有 `_running` 保护，但彼此之间不是同一把锁；`CloudSyncEngine.run` 本身无全局互斥。  
**后果**：极端时序下可能两个 run 同时执行，增加 SQLite 锁竞争与重复 LIST/PUT。  
**修复方向**：`CloudSyncEngine` 或独立 `CloudSyncRunLock` 全局互斥；后到请求合并/跳过。


### P2-1：快照包含同步运行时表

**现象**：`aquamarina.db` 内包含 `oplog_*` / `sync_*`，恢复后再清理。  
**后果**：快照体积偏大；恢复逻辑需处理“先污染再清理”。  
**修复方向**：快照导出时排除同步表，或使用只含业务表的 checkpoint 格式。

### P2-2：没有自动检查点 / 引导仍需手动

**现象**：完整快照仅手动上传；新设备需要用户手动选择恢复。  
**后果**：大数据量下首次引导依赖人工；chunk 历史不能安全大幅裁剪。  
**修复方向**：每 N op / 7 天自动 checkpoint；`checkpoint + 尾部 chunk` 自动引导；checkpoint 水位用于 GC。

### P2-3：无端到端加密，仅 TLS + 私有桶

**现象**：笔记、学习记录以明文 JSON/DB 存在对象存储。  
**后果**：第三方或共享桶场景隐私不足。  
**修复方向**：可选口令 → Argon2id → AES-GCM 加密 chunk/checkpoint；口令不落盘。

### P2-4：无账号 / 设备管理 / 多用户隔离

**现象**：同一 bucket + prefix 下按设备 ID 隔离；没有登录、设备吊销、权限模型。  
**后果**：多人共用需要各自规划前缀；无法在 App 内管理/撤销遗失设备。  
**修复方向**：用户/租户 prefix + 设备列表 + 吊销；或引入服务端账号。

### P2-5：恢复是覆盖式，不在后台自动合并

**现象**：快照恢复覆盖本地数据库；恢复后提示重启。  
**后果**：不能把另一台设备的快照与本地数据自动合并；适合灾备/引导，不适合日常。  
**修复方向**：保持现状并在 UI 明确；如需合并，走增量同步或实现快照归并引擎。

### P2-6：没有逐条冲突解决 UI

**现象**：LWW 后写胜出；同步结果只展示冲突数量与前几条明细。  
**后果**：同一笔记两端同时编辑时，旧值只能从远端历史 chunk 找回，普通用户难以操作。  
**修复方向**：冲突详情页，逐条选择本地/远端；或保留双方版本为两条记录。

### P2-7：前台轮询的网络成本与蜂窝流量

**现象**：默认每 5 分钟 LIST；无 Wi-Fi 限制。  
**后果**：移动网络下可能产生不必要的流量/耗电。  
**修复方向**：`connectivity_plus` 仅 Wi-Fi；退避策略（连续失败/无变更延长间隔）。

### P2-8：设备 ID 重置 / 重装后的数据视图

**现象**：重装/重置设备标识后，云端旧设备目录仍在；本机只按新 ID 写入。  
**后果**：设备列表出现“旧设备”，需要手动恢复其快照；旧 chunk 不会自动合并。  
**修复方向**：设备管理页支持删除/接管旧设备；首次配置时提示选择恢复。

### P2-9：HLC 在“导出时”分配，而非“写入时”

**现象**：本地 op 的 HLC 在 `takePendingBatch` 时分配；若两台设备先后修改同一字段，但 A 的 op 很晚才导出，A 可能获得更晚的 HLC。  
**缓解**：对带 `updated_at` / `last_reviewed_at` 等自然时间戳的表，应用时先做自然时间比较；没有时间戳的表依赖 HLC。  
**修复方向**：在触发器写入时记录墙钟（或应用层写入时间），导出时结合自然时间生成 HLC；或为所有表补 `updated_at`。

---

## 4. 可改善方向（建议路线）

### 阶段 A：低成本、高收益（建议优先）

1. **每设备 `head.json`**
   - 内容：`latest_chunk_key`、`latest_hlc`、`chunk_count`、`updated_at`、`device_name`；
   - 推送成功后最后写；
   - 拉取时先 GET 各设备 head，再按水位决定是否 LIST / 拉取。
2. **每设备 `state.json`**
   - 内容：`applied: { otherDeviceId: maxHlc }`；
   - 应用 chunk 后更新；
   - GC 仅删除所有设备水位都越过的 chunk。
3. **清理 `sync_applied` / 墓碑**
   - GC 删除 chunk 时，按 chunk 中的 op 删除对应 `sync_applied`；
   - 墓碑按“所有设备水位 + 保留期”清理。
4. **修复恢复后本机 chunk 不重放**
   - 恢复后按 `baseline_hlc` 拉取自己设备的新 chunk（只重放，不重复上传）；
   - 或在 UI 明确警告“快照之后的变更将丢失”。

### 阶段 B：性能与体积

1. **chunk gzip + 完整 SHA-256**
   - 文件名：`{hlc}-{fullSha256}.jsonl.gz`；
   - 引擎按 magic/后缀识别；
   - 兼容旧 chunk（未压缩）。
2. **apply 批量化**
   - 每 chunk 内按 entity 分组；
   - `batch` + `INSERT OR IGNORE` / 多行 UPDATE；
   - 减少逐条 SELECT。
3. **同步 run 时间预算**
   - 例如单次最多 20–30 秒，处理 N 个 chunk 后退出；
   - 前台轮询下次继续（chunk 级已可恢复）；
   - 增加进度回调与取消 Token。
4. **批量导入快速路径**
   - 大批量 `word_book_entries` 导入时暂停 capture（`applying=1` 类似标记），导入完成后生成单条“批量添加”op 或 checkpoint。

### 阶段 C：快照与引导

1. **流式快照**
   - `VACUUM INTO` 后流式 ZIP 到临时文件；分片/流式 PUT；
   - 恢复流式解压到临时 DB，再原子替换；
   - 避免整包 `Uint8List`。
2. **快照只含业务表**
   - 导出时排除 `oplog_*` / `sync_*`；
   - 同步状态单独维护，恢复后无需清理。
3. **自动 checkpoint**
   - 每 N op / 7 天生成；
   - `checkpoint.json` 记录各设备水位；
   - 新设备：checkpoint + 尾部 chunk 自动引导；
   - 旧 chunk 按 checkpoint 水位回收。

### 阶段 D：安全与产品能力

1. **可选端到端加密**
   - 用户口令 → Argon2id → AES-GCM；
   - chunk / checkpoint 加密，口令不落盘；
   - 设置页明确“忘记口令无法恢复”。
2. **仅 Wi-Fi / 网络退避**
   - `connectivity_plus`；
   - 连续失败指数退避。
3. **账号与设备管理**
   - 每用户独立 prefix；
   - 设备列表、吊销、接管；
   - 或引入服务端账号体系。
4. **冲突解决 UI**
   - 从 `SyncApplyResult.conflictDetails` 扩展为可操作列表；
   - 支持保留本地 / 远端 / 双方版本。

### 阶段 E：测试与压测

建议新增基准数据集：

| 场景 | 数据规模 |
|---|---|
| 小 | 1 万词 + 1 万记录 + 2 千笔记 |
| 中 | 10 万词 + 10 万记录 + 1 万笔记/句子 |
| 大 | 50 万–100 万记录 |

测量指标：
- 本地 DB 大小、快照 ZIP 大小、快照峰值内存；
- 一次 LIST 的耗时与对象数；
- 200 / 1000 / 5000 chunk 的拉取与应用耗时；
- 单 chunk 应用吞吐、失败恢复时间；
- 前台轮询 1 小时的电量/流量（真机）。


---

## 5. 交接注意事项（不要破坏的约束）

### 5.1 必须保持的协议不变量

1. **设备隔离**：每台设备只写 `devices/{deviceId}/`，不要引入多设备共享的可变对象。
2. **chunk 不可变**：已上传 chunk 不要原地修改；需要修正就发新 op。
3. **manifest 最后写**：先快照 ZIP，成功后写 manifest。
4. **捕获与业务写入同事务**：不要改为应用层异步打点，否则会漏变更。
5. **`applying=1` 时触发器静默**：否则应用远端操作会无限回环。
6. **`capture_enabled` 默认关闭**：未配置云同步时不积累 oplog。
7. **云端不存 API Key**：默认 `includeApiKeys=false`；Secure Storage 不进入备份白名单。
8. **`cloud_sync_*` Prefs 是设备本地的**：备份导出/恢复必须跳过。
9. **恢复后写同步基线**：否则历史 chunk 会重复累加计数。
10. **计数按增量、删除按墓碑、集合按 grow-only**：不要把计数改成整行 LWW。

### 5.2 新增一张同步表的步骤

1. 在 `sync_table_spec.dart` 的 `SyncSpecs.all` 增加 `SyncTableSpec`：
   - 跨设备稳定键（优先 UUID / 自然键）；
   - 数据列、计数列、可选 `lwwColumn`；
2. 确认源表在 `DatabaseService.onCreate` / 迁移中存在；
3. 如果键是 UUID，创建表时补列并在插入路径生成；
4. `SyncSchema.ensure` 会自动创建 `oplog_<entity>` 与 3 个触发器；
5. 现有数据库需要一次 schema 升级（`schemaVersion++` + `migrateToVx`）；
6. 在 `SyncApplyService._applyUpsert/_applyDelete` 中确认通用逻辑是否足够；
   - 有父子依赖时实现“pendingParent”重试；
   - 需要级联删除时补 switch 分支；
7. 补测试：触发器产生预期 op、应用幂等、计数/删除/LWW；
8. 检查备份/恢复流程是否需要特殊处理（一般不需要）。

### 5.3 数据库迁移注意事项

- 当前 `schemaVersion=14`；
- `migrateToV13` 幂等，负责同步就绪列、oplog、触发器；
- `migrateToV14` 创建 `sentence_sets` 并再次 `SyncSchema.ensure`；
- 修改同步系统表结构（如 `sync_applied` 主键）时：
  - 已发布版本必须新增迁移重建表；
  - 未发布分支可直接改，但要在文档说明；
- `BackupService._validateImportedDatabase` 允许导入低版本 DB，随后 `onUpgrade` 迁移；不要拒绝 v12/v13 备份。

### 5.4 测试与验收

基础：

```powershell
flutter test
flutter analyze
```

真实 S3（环境变量见文首）：

```powershell
flutter test test/cloud_sync_s3_integration_test.dart
```

手工双设备验收：

1. A 写入笔记/复习记录 → 学习结束后自动同步；
2. B 前台等待一个轮询周期（或点手动同步）→ 数据出现；
3. B 修改 → A 下一轮同步拿到 B 的修改；
4. 删除一条笔记 → 另一端同步后消失，且旧 chunk 重放不会复活；
5. A 上传完整快照 → B 从云端恢复 → 两端继续增量同步；
6. 断网/错误密钥/错误桶 → 不崩溃、不丢本地数据、恢复网络后重试成功。

### 5.5 当前分支与工作区

- 分支：`feat/cloud-sync`；
- 最新提交：`0cdefd9`（学习结束同步 + 前台轮询）；
- 尚未 push，等待人工 PR；
- 工作区在最后一次提交后应保持干净；
- 测试桶凭据不得写入仓库或 CI 日志。

### 5.6 推荐先看哪些文件

按理解顺序：

1. `docs/cloud-sync-spec.md`（协议设计）
2. `lib/services/sync_table_spec.dart`（哪些表、如何生成触发器）
3. `lib/services/database_service.dart` 的 `migrateToV13/14`
4. `lib/services/sync_capture_service.dart`
5. `lib/services/sync_apply_service.dart`
6. `lib/services/cloud_sync_engine.dart`
7. `lib/services/cloud_sync_service.dart`（快照）
8. `lib/services/backup_service.dart`（导入/导出、基线）
9. `lib/pages/settings/cloud_sync_config_page.dart` / `sections/cloud_sync_section.dart`
10. `test/sync_*`、`test/cloud_sync_*`

---

## 6. 一句话总结

当前云同步是**设备隔离的不可变 oplog + 完整快照**：正确性、幂等、并发安全已经比较扎实，适合个人多设备；  
下一步最有价值的改进是：**head/state 水位（减少 LIST + 精确 GC）→ 清理 sync 表 → chunk 压缩 → 批量 apply / 流式快照 → 自动 checkpoint**。

- **快照只用于灾备 / 引导**，不作为日常合并手段。
