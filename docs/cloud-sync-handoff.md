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
  - 业务数据：SQLite（`sqflite` + `sqflite_common_ffi`），当前 **schemaVersion = 17**；
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
   - 可选「仅 Wi-Fi / 以太网自动同步」，连续失败指数退避（最长 60 分钟）；
   - 同步结果展示拉取/上传数量、冲突数、待上传数量、时间预算与告警/冲突明细；
   - 「同步冲突」页可逐条选择保留本地 / 采用远端 / 保留双方；
   - 「云端设备」页可查看设备列表并删除旧设备数据。
3. **完整快照**
   - 「立即上传备份」：把本机数据库 + 设置打包为 ZIP 上传到本设备目录；
   - 「从云端恢复」：列出所有设备快照，校验 SHA-256 后覆盖导入；
   - 恢复前自动保留本机数据库快照，失败可回滚；
   - 自动检查点：每 7 天或累计 5000 条变更自动上传一份完整快照；
   - 新设备首次配置时，如果本机为空且云端有快照，会提示立即引导。
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
S3: devices/{deviceId}/chunks/{hlc}-{sha256}.jsonl.gz ← 不可变，只追加（gzip）
S3: devices/{deviceId}/head.json                    ← 本机最新 chunk 水位（推送后最后写）
S3: devices/{deviceId}/state.json                   ← 已应用到其它设备的水位（GC 依据）
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
- **head / state 水位**：其它设备先读 head 判断是否需要 LIST，再按 `startAfter` 只拉增量；
- **oplog 捕获与业务写入同事务**：数据落库 ⇒ 变更已记录；
- **chunk 不可变**：重传幂等，远端按 `(device_id, entity, seq)` 去重；
- **HLC + 行版本 + 墓碑**：乱序/迟到操作不会覆盖新数据；
- **GC 按水位**：所有活跃设备都应用后才删除 chunk，并同步收缩本地应用记录。

### 2.3 代码地图

| 文件 | 职责 |
|---|---|
| `lib/services/cloud_sync_settings.dart` | 非敏感配置、Secure Storage 凭据、设备 ID/名称、运行状态、配置校验 |
| `lib/services/s3_storage_service.dart` | MinIO 客户端封装：PUT/GET/HEAD/LIST/DELETE、超时、错误中文化、连接自检 |
| `lib/services/cloud_sync_service.dart` | 完整快照：上传、设备清单、恢复、历史保留、恢复前本机快照 |
| `lib/services/cloud_sync_engine.dart` | 增量同步编排：head/state 水位、按设备增量拉取、恢复后重放本机 chunk、推送本机 chunk、调用 GC |
| `lib/services/cloud_sync_device_meta_service.dart` | 设备发现（CommonPrefixes）、`head.json` / `state.json` 读写与容错 |
| `lib/services/cloud_sync_run_lock.dart` | 进程内全局互斥，手动 / 自动 / 事件同步串行执行 |
| `lib/services/cloud_sync_auto_sync_service.dart` | 启动 / 回前台自动同步，按配置间隔冷却，手动可复用 |
| `lib/services/cloud_sync_foreground_sync_service.dart` | 前台 `Timer.periodic` 轮询、生命周期启停、事件同步后重置计时 |
| `lib/services/cloud_sync_activity_sync_service.dart` | 学习结束事件同步：2 秒防抖、push 优先、按需 pull |
| `lib/services/cloud_sync_maintenance_service.dart` | 按所有活跃设备水位清理 chunk，并清理本地 `sync_chunks` / `sync_applied` / 墓碑 |
| `lib/services/cloud_sync_checkpoint_service.dart` | 自动检查点：7 天 / 5000 op 触发完整快照 |
| `lib/services/cloud_sync_bootstrap_service.dart` | 新设备首配时查找最新快照并引导 |
| `lib/services/cloud_sync_network_service.dart` | 仅 Wi-Fi / 以太网策略与测试注入 |
| `lib/services/sync_conflict_store.dart` | 冲突持久化、采用远端、保留双方 |
| `lib/pages/settings/cloud_sync_conflict_page.dart` | 冲突逐条处理 UI |
| `lib/pages/settings/cloud_sync_devices_page.dart` | 云端设备列表与旧设备删除 |
| `lib/services/sync_table_spec.dart` | 同步表单一规格（键/数据列/计数列/LWW 列），生成 oplog 表与触发器 |
| `lib/services/sync_schema.dart` | 同步系统表、触发器安装、恢复后运行时状态重置 |
| `lib/services/sync_capture_service.dart` | HLC 分配、JSONL chunk 导出、本地行版本、上传后清理 |
| `lib/services/sync_apply_service.dart` | 幂等应用、行版本门禁、自然时间戳 LWW、计数增量、墓碑、父级重试 |
| `lib/models/sync_op.dart` | op/HLC 模型、JSONL 编解码 |
| `lib/models/cloud_sync_manifest.dart` | 快照清单/快照元信息、格式版本、SHA-256、对象键工具 |
| `lib/models/cloud_sync_device_state.dart` | `head.json` / `state.json` 模型、JSON 编解码与水位合并 |
| `lib/pages/settings/sections/cloud_sync_section.dart` | 设置页云同步分区与同步结果 UI |
| `lib/pages/settings/cloud_sync_config_page.dart` | 对象存储配置表单、连接测试、自动同步间隔、设备标识管理 |
| `lib/services/backup_service.dart` | ZIP 备份/恢复；保护 `cloud_sync_*` Prefs；恢复后重置同步运行时并写基线 |

### 2.4 云端对象布局

```
{prefix}/
└── devices/{deviceId}/
    ├── manifest.json
    ├── snapshots/{utcTimestamp}.zip
    ├── head.json
    ├── state.json
    └── chunks/{hlcMsHex}-{hlcCounterHex}-{sha256完整64位}.jsonl.gz
```

- `prefix` 默认 `aquamarina`；
- `deviceId` 为本机 UUID v4；
- chunk 键包含首个 op 的 HLC 与完整 SHA-256，按字典序近似按时间排序；
- chunk 内容为 gzip 压缩 JSONL；引擎同时兼容旧的未压缩 `.jsonl`；
- `manifest.json` 在快照 ZIP 上传成功后最后写入；
- `head.json` 在本轮 chunk 推送成功后最后写入，记录 `latest_chunk_key` / `latest_hlc` / `chunk_count`；
- `state.json` 在拉取应用后写入，记录 `applied: {其它设备 ID: 已完整应用的最大 chunk 起始 HLC}`，是 GC 的唯一删除依据；
- head/state 写入失败不会丢数据：`sync_meta.head_dirty` 会在下一次同步重试 head。

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
  "v": 2,
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
- `hlc`：混合逻辑时钟（毫秒 + 计数），导出 chunk 时以 oplog 的 `captured_at_ms` 为基准分配并持久化；
- `op`：`upsert` / `delete` / `bulk`；`bulk` 使用 `items` 数组承载多条实体操作；
- `delta`：计数类字段增量（复习次数、错题次数、每日统计）；
- 排序键：`(hlc, entity, seq)`。

### 2.6 本地同步表

| 表 | 用途 | 是否清理 |
|---|---|---|
| `sync_meta` | 单行：设备 ID、`applying`、HLC、基线、`capture_enabled`、head 水位 / `head_dirty`、`total_ops` | 不清理 |
| `sync_applied` | 已应用远端 `(device_id, entity, seq)` + `hlc` | GC 删除 chunk 时按 HLC 边界清理 |
| `sync_chunks` | 已应用 chunk key + sha256 + `min_hlc` / `max_hlc` | GC 删除对应远端 chunk 时清理 |
| `sync_row_versions` | 每实体键的最新 HLC，LWW 门禁 | 不清理（规模≈实体数） |
| `sync_state` | 每个来源设备已完整应用的最大 chunk 起始 HLC / 最后 chunk key | 随拉取进度更新 |
| `sync_tombstones` | 删除墓碑 | 所有活跃设备水位越过 + 180 天后清理 |
| `sync_conflicts` | 待处理冲突（本地 JSON 快照，不同步） | 用户处理后标记 resolved |
| `oplog_<entity>` | 待上传操作（每同步表一张，含 `captured_at_ms`） | 上传成功后删除 |
| `oplog_bulk` | 批量 op（大批量导入压缩为一条 payload） | 上传成功后删除 |

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
2. 非递归 LIST {prefix}/devices/，用 CommonPrefixes 发现设备（不递归列举全部 chunk）
3. 对每个设备 GET head.json：
   - head.latest_hlc ≤ 本地 sync_state.last_hlc → 直接跳过（不 LIST）
   - 否则只 LIST 该设备的 chunks/，并用 startAfter=sync_state.last_chunk_key 只取尾部增量
4. 过滤：本地 sync_chunks 已记录的、baseline 之前的
5. 按对象 key（HLC 前缀）排序
6. 逐个 GET → 校验 SHA-256 前 16 位 → 解码 JSONL
7. SyncApplyService.applyOps（单事务）
   - sync_applied 去重
   - 行版本门禁
   - 按表语义应用
   - 缺失父级的 op 不记录 applied，后续重试
8. 应用成功后写入 sync_chunks(min_hlc / max_hlc) 并推进 sync_state
   - 只有连续成功的前缀才推进；中途失败保留旧位置
9. 拉取结束后写本机 state.json（applied 水位）
10. 本机推送：
   - takePendingBatch：按 captured_at_ms 分配 HLC、记录 sync_row_versions、切 500 op / 900 KB，gzip 后上传
   - PUT 到自己的 chunks/
   - markUploaded 删除本地 oplog
   - 更新 sync_meta head 水位并置 head_dirty=1
   - 最多 20 批 / 次
11. 补写 head.json（失败保留 dirty，下次同步重试）
12. 每 7 天执行一次水位 GC（所有活跃设备越过 + 30 天）
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

### 2.11 变更捕获不变量

**只要云同步配置完整（endpoint / bucket / AK / SK），`sync_meta.capture_enabled` 必须为 1。**

原因：oplog 只在业务写入时由 SQLite 触发器记录。如果捕获关闭，写入仍然成功，但之后无法补传；
快照恢复会把 `sync_meta` 按默认值重建（`capture_enabled=0`），所以恢复后到首次同步之间
是高风险窗口。

当前保证点：

- 保存云同步配置后立即开启；
- `BackupService.importBackupFromFile` 恢复完成后，如果配置完整，立即重新开启；
- 应用启动时（`main.dart`）在任何业务写入 / 闪退会话恢复之前校正；
- 设置页检测到「已配置但捕获关闭」时显示警告并支持一键修复。

### 2.12 触发时机

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

### 2.13 配置与默认值

| 项 | 默认值 |
|---|---|
| 前缀 | `aquamarina` |
| 快照保留份数 | 5（1–50） |
| chunk 批量 | 500 op / 900 KB（未压缩 JSONL 尺寸；上传时 gzip） |
| chunk 哈希 | 完整 SHA-256（兼容旧 16 位） |
| 单次 run 时间预算 | 25 秒；耗尽后下次续跑 |
| 前台自动同步 | 开启 |
| 自动同步间隔 | 5 分钟（1/5/15/30，校验范围 1–60） |
| 仅 Wi-Fi 自动同步 | 关闭（可开启；手动同步不受限） |
| 失败退避 | 连续失败按间隔 × 2^n，最长 60 分钟 |
| 学习结束防抖 | 2 秒 |
| 每次 run 最大推送批数 | 20 |
| 自动检查点 | 开启；7 天或 5000 条变更；失败退避 30 分钟–24 小时 |
| 冲突保留 | 已解决 30 天；未解决 180 天 |
| chunk GC | 7 天冷却；所有活跃设备水位越过 + 至少保留 30 天；墓碑 180 天 |
| 设备活跃窗口 | head/state 180 天内更新 |
| 备份大小上限 | 500 MB |
| 数据库 schema | 17 |
| 凭据存储 | Secure Storage：`cloud_sync_access_key` / `cloud_sync_secret_key` |
| 非敏感配置 | Prefs：`cloud_sync_config_v1`、`cloud_sync_state_v1`、`cloud_sync_device_id_v1`、`cloud_sync_device_name_v1` |

### 2.14 测试现状

- `flutter test`：无 S3 环境变量时 **225 passed / 4 skipped**；设置真实 S3 后 **229 passed**；
- 新增覆盖：gzip chunk、完整 SHA-256、时间预算续跑、`captured_at_ms` HLC、批量 oplog 回填、冲突持久化/解决/清理、检查点空库与退避、流式文件上传下载、网络策略；
- 覆盖：
  - v13/v14/v15 迁移、UUID/顺序回填、触发器数量与抑制；
  - 捕获开关、HLC 单调、chunk 编解码、上传后清理；
  - 应用引擎：幂等、行版本门禁、计数增量、墓碑/复活、LWW、词书父级重试、句式集级联；
  - 引擎：head/state 水位、按设备增量拉取、`startAfter`、head 命中跳过、恢复后重放、缺失父级重试、上传失败重试、损坏 chunk、基线；
  - GC：所有活跃设备水位、最小保留期、`sync_applied` / `sync_chunks` / 墓碑清理；
  - 全局同步锁串行执行；
  - 前台轮询：start/stop/reset、fake_async；
  - 学习结束事件：防抖合并、无变更跳过、到期 pull、关闭自动同步；
  - 真实 Rain S3：连接自检、设备清单、head/state、双设备增量收敛。

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

### P0-1：每次同步全量 LIST 云端 chunk（✅ 已解决）

**原现象**：`CloudSyncEngine._pull` 每次 `LIST {devicesPrefix}/` 递归，再在内存过滤。  
**修复（v15）**：新增 `head.json`；设备发现改用非递归 LIST 的 CommonPrefixes；head 水位未变化直接跳过；变化时只 LIST 该设备 `chunks/` 并带 `startAfter`。  
**相关**：`cloud_sync_engine.dart`、`cloud_sync_device_meta_service.dart`、`cloud_sync_settings.dart`。

### P0-2：快照全量进内存，移动端有 OOM 风险（✅ 已解决）

**原现象**：`BackupService.exportBackup` 返回 `Uint8List`；上传/下载整包进内存。  
**修复（v16）**：
- 新增 `exportBackupToFile` / `importBackupFromFile`，使用 `ZipFileEncoder` 流式写 ZIP、`ArchiveFile.writeContent` 流式解压；
- `S3StorageService.putFile` / `downloadToFile` 流式传输并同时计算 SHA-256；
- 云快照与手动导出/导入均改用文件版 API；
- 保留旧的 `exportBackup` / `importBackup(Uint8List)` 作为兼容包装。

### P0-3：`sync_applied` 与墓碑永久增长（✅ 已解决）

**原现象**：远端每个 op 写入 `sync_applied`，从不清理；墓碑也不清理。  
**修复（v15）**：`sync_applied` 记录 op HLC；GC 删除 chunk 后按「下一个保留 chunk 的起始 HLC」清理应用记录；墓碑在所有活跃设备水位越过且超过 180 天后清理。  
**修复方向**：GC 删除 chunk 时按该 chunk 的 op 列表清理 `sync_applied`；墓碑按保留期/水位清理。

### P0-4：快照恢复会跳过本机自己更新的 chunk（✅ 已解决）

**原现象**：`_pull` 过滤 `_deviceOf(key) == deviceId`。  
**修复（v15）**：基线存在时允许重放本机 `HLC > baseline` 的 chunk（只重放、不重复上传）；无基线时仍跳过本机 chunk。  
**场景**：设备 A 上传 chunk → 之后恢复较旧的快照（同一设备）→ 恢复后 A 会拉回快照之后的本机变更。

### P1-1：GC 按时间而非水位，可能删掉离线设备仍需要的 chunk（✅ 已解决）

**原现象**：每设备保留最近 1000 chunk + 只删 180 天前的对象。  
**修复（v15）**：每设备上传 `state.json`（已应用到各设备的最大 chunk 起始 HLC）；只有所有活跃设备（head/state 180 天内更新）都越过，且对象超过 30 天才删除；任一非 owner 活跃设备缺少 state 时本轮不删。

### P1-2：应用/推送逐条查询，缺少批量与时间预算（✅ 已解决）

**原现象**：`SyncApplyService` 每 op 多次 SELECT/INSERT；`CloudSyncEngine.run` 无预算/进度/取消。  
**修复（v16）**：
- `SyncApplyService` 按 `(device, entity)` 预载 `sync_applied`、按实体预载行版本与墓碑；
- 去重记录、行版本、墓碑在事务末尾用 batch 写回；
- `takePendingBatch` 的 HLC 分配改为一次 batch 更新；行版本改为按实体预载 + batch 写回；
- `CloudSyncEngine.run` 增加 `maxDuration`（默认 25 秒）、`isCancelled`、`onProgress` 与 `budgetExhausted`；
- 未处理完的 chunk 不推进水位，下次同步自动续跑；设置页展示进度与预算提示。
- 每个 chunk 按 50 条 op 切分为小事务提交；时间预算/取消可在小批之间生效，未完成 chunk 不写水位，下次从已应用 op 继续。
- 已预载业务行，避免逐 op SELECT；业务 UPDATE/INSERT/DELETE 进入 `_RowWrite` 队列，事务末尾一次 batch 提交；`word_books` 插入因需要自增 id 仍即时执行。

### P1-3：批量导入放大 oplog（✅ 已解决本地捕获开销）

**原现象**：导入 N 个单词 → 每行触发器各写一条 oplog。  
**修复（v17）**：
- `word_book_entries` ≥ 1000 条、`sentences` ≥ 500 条时走快速路径；
- 事务内临时关闭 `capture_enabled`，batch 插入后写入 `oplog_bulk`；
- 批量 op 使用 `op='bulk'` + `items` 数组，上传/应用只占一条 op 记录；
- 1000 条 item 一个 bulk op；超大导入拆成多个 bulk chunk；极大减少上传轮次与 oplog 行数。

### P1-4：chunk 未压缩、哈希只用前 16 位（✅ 已解决）

**原现象**：JSONL 纯文本；文件名/校验只用 SHA-256 前 16 位。  
**修复（v16）**：
- chunk 上传前 gzip 压缩，键名 `{hlc}-{sha256完整64位}.jsonl.gz`；
- 下载按 gzip magic / 后缀自动解压，兼容旧 `.jsonl`；
- 文件名哈希校验支持 64 位与旧 16 位。

### P1-5：运行并发没有全局锁（✅ 已解决）

**原现象**：手动同步、自动同步、学习结束事件同步各自有 `_running` 保护，但彼此之间不是同一把锁。  
**修复（v15）**：新增 `CloudSyncRunLock` 串行队列，`CloudSyncEngine.run` 统一走全局互斥；后到请求等待前一个完成。


### P2-1：快照包含同步运行时表（✅ 已解决）

**原现象**：`aquamarina.db` 内包含 `oplog_*` / `sync_*`。  
**修复（v16）**：`VACUUM INTO` 后打开副本，删除 `sync_*` / `oplog_*` 并 `VACUUM`；恢复时 `SyncSchema.ensure` 重建并写基线。

### P2-2：没有自动检查点 / 引导仍需手动（✅ 已解决）

**原现象**：完整快照仅手动上传；新设备需要手动恢复。  
**修复（v16）**：
- `CloudSyncCheckpointService` 在自动同步成功后按 7 天 / 5000 op 冷却生成完整快照；
- `sync_meta.total_ops` 统计本机上传 + 远端应用数量；累计为 0 时不生成空检查点；
- 检查点失败按 30 分钟 → 24 小时指数退避，不会每个轮询周期重试大文件上传；
- 恢复快照后重置检查点水位，允许重新生成；
- 新设备首次配置且本机为空时，`CloudSyncBootstrapService` 查找最新快照并提示立即引导；
- 设置页新增「从最新检查点引导」，不再只限于首次配置；
- 仍复用现有 manifest/snapshot 布局；**未使用 checkpoint 水位裁剪 GC**（避免让仍在线设备回退到快照）。

### P2-3：无端到端加密，仅 TLS + 私有桶

**现象**：笔记、学习记录以明文 JSON/DB 存在对象存储。  
**后果**：第三方或共享桶场景隐私不足。  
**修复方向**：可选口令 → Argon2id → AES-GCM 加密 chunk/checkpoint；口令不落盘。

### P2-4：无账号 / 设备管理 / 多用户隔离

**现象**：同一 bucket + prefix 下按设备 ID 隔离；没有登录、设备吊销、权限模型。  
**后果**：多人共用需要各自规划前缀；无法在 App 内管理/撤销遗失设备。  
**修复方向**：用户/租户 prefix + 设备列表 + 吊销；或引入服务端账号。

### P2-5：恢复是覆盖式，不在后台自动合并（✅ 已在 UI / 文档明确）

**处理**：保持覆盖式语义，设置页与文档明确「快照用于灾备 / 引导；日常合并走增量同步」。自动检查点与新设备引导均复用该语义。

### P2-6：没有逐条冲突解决 UI（✅ 已解决）

**修复（v16）**：
- 自然时间戳冲突写入本地 `sync_conflicts`（entity / key / 双方 JSON / 时间）；
- 新增「同步冲突」页，逐条支持「保留本地」「采用远端」「保留双方」（笔记类）；
- 采用远端时按实体键直接更新本地行，绕过 LWW 门禁，由用户显式决定；
- 行版本门禁挡住但远端自然时间更新时，也会记录为冲突（典型：时钟偏差/晚导出）；
- 解决冲突会推进 `sync_row_versions`，防止更旧远端 op 覆盖；
- 维护任务清理已解决 > 30 天、未解决 > 180 天的冲突记录；计数增量按设计直接累加，不进入冲突页。

### P2-7：前台轮询的网络成本与蜂窝流量（✅ 已解决）

**修复（v16）**：
- 新增 `connectivity_plus` 与「仅 Wi-Fi / 以太网自动同步」开关（默认关闭）；
- 自动同步与学习结束同步遵守该策略，手动同步不受限制；
- 连续失败按间隔 × 2^n 退避，最长 60 分钟；成功后清零。

### P2-8：设备 ID 重置 / 重装后的数据视图（✅ 已解决）

**修复（v16）**：
- 新增「云端设备」页：列出所有设备、标记本机、显示设备名；
- 支持「接管并合并」：先拉取旧设备全部变更，再删除其云端目录；也支持仅删除；
- 重置设备标识沿用原入口，并明确提示旧目录需要手动恢复或删除；
- 新设备首次配置时自动提示从最新快照引导。

### P2-9：HLC 在“导出时”分配，而非“写入时”（✅ 已解决）

**修复（v16）**：
- 每张 oplog 表新增 `captured_at_ms`，触发器在业务写入时记录墙钟；
- `takePendingBatch` 以 `captured_at_ms` 为 HLC 基准，并用 `lastMs` 保证本机单调；
- 未来墙钟超过 5 分钟时按当前时间处理，避免一次时钟错误把 HLC 推到未来；
- 晚导出不会再凭空获得更晚的 HLC；自然时间戳 LWW 仍作为第二道保护。

---

## 4. 可改善方向（建议路线）

### 阶段 A：低成本、高收益（✅ 已完成，v15）

1. **每设备 `head.json`** ✅
2. **每设备 `state.json`** ✅
3. **清理 `sync_applied` / 墓碑** ✅
4. **修复恢复后本机 chunk 不重放** ✅
5. **全局同步互斥** ✅

### 阶段 B：性能与体积（✅ 已完成，v16）

1. **chunk gzip + 完整 SHA-256** ✅
2. **apply 批量化（预载 + batch 写回）** ✅
3. **同步 run 时间预算 / 进度 / 取消** ✅
4. **批量导入快速路径（关闭触发器 + INSERT SELECT 回填）** ✅

### 阶段 C：快照与引导（✅ 已完成，v16）

1. **流式快照** ✅
2. **快照只含业务表** ✅
3. **自动 checkpoint + 新设备引导** ✅
   - 复用完整快照作为检查点；每 7 天 / 5000 op；
   - 新设备首配时提示从最新快照引导。

### 阶段 D：安全与产品能力

1. **可选端到端加密**（未做，P2-3）
2. **仅 Wi-Fi / 网络退避** ✅
3. **账号体系**（未做，P2-4；当前仍按设备前缀隔离）
4. **冲突解决 UI** ✅
5. **设备管理** ✅（云端设备列表 / 删除旧设备）

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
4. **head / state 是派生水位**：head 记录本机最新 chunk，state 记录已应用到的来源水位；二者丢失可从对象列表重建，但不得用于伪造进度。
5. **捕获与业务写入同事务**：不要改为应用层异步打点，否则会漏变更。
6. **`applying=1` 时触发器静默**：否则应用远端操作会无限回环。
7. **`capture_enabled` 默认关闭**：未配置云同步时不积累 oplog。
8. **云端不存 API Key**：默认 `includeApiKeys=false`；Secure Storage 不进入备份白名单。
9. **`cloud_sync_*` Prefs 是设备本地的**：备份导出/恢复必须跳过。
10. **恢复后写同步基线**：否则历史 chunk 会重复累加计数。
11. **计数按增量、删除按墓碑、集合按 grow-only**：不要把计数改成整行 LWW。
12. **GC 只按水位删除**：没有足够 state 时宁可本轮不删；不要退回“仅按时间”直接删除。

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

- 当前 `schemaVersion=17`；
- `migrateToV13` 幂等，负责同步就绪列、oplog、触发器；
- `migrateToV14` 创建 `sentence_sets` 并再次 `SyncSchema.ensure`；
- `migrateToV15` 补齐 head/state/应用 HLC 列，并从 chunk 键回填 `sync_chunks.min_hlc`；
- `migrateToV16` 为 oplog 补 `captured_at_ms`、重建触发器、创建 `sync_conflicts` / `total_ops`；
- `migrateToV17` 创建 `oplog_bulk` 与批量 op 索引；
- 修改同步系统表结构（如 `sync_applied` 主键）时：
  - 已发布版本必须新增迁移重建表；
  - 未发布分支可直接改，但要在文档说明；
- `BackupService._validateImportedDatabase` 允许导入低版本 DB，随后 `onUpgrade` 迁移；不要拒绝 v12/v13/v14 备份。

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

当前云同步是**设备隔离的不可变 oplog + head/state 水位 + 流式完整快照**：正确性、幂等、并发安全已经比较扎实，适合个人多设备。  
阶段 A（head/state、水位 GC、应用记录清理、恢复重放、全局锁）与阶段 B/C（gzip、完整 SHA、批量 apply、时间预算、流式快照、自动 checkpoint）均已完成。  
剩余两项为产品 / 安全增强：**P2-3 端到端加密**、**P2-4 账号与多租户**。

- **快照只用于灾备 / 引导**，不作为日常合并手段；日常合并走增量同步。

---

## 7. 残余限制（v17 之后）

以下不是阻塞性问题，但仍是后续可改进项：

1. **P1-2 仍有少量即时写入**：业务行已预载并批量 flush，chunk 切成 50 op 小事务；`word_books` 插入因需要自增 id 仍即时执行，未使用 SQLite 多行 upsert。
2. **P2-2 未使用 checkpoint 水位裁剪 GC**：自动检查点复用完整快照，GC 仍只按活跃设备 `state.json` 水位。直接用 checkpoint 删除 chunk 会让仍在线设备失去增量，因此保持保守策略。
3. **P2-6 计数不产生冲突**：计数字段按增量累加，不进入冲突页；行版本冲突与自然时间冲突已记录，解决冲突会推进 `sync_row_versions`。
4. **P2-8 无真正吊销**：已支持「接管并合并」和删除旧设备目录；但旧设备再次同步仍会重建目录，没有服务端吊销机制。
5. **P2-9 历史遗留**：v16 之前且未分配 HLC 的 oplog 仍以导出时间为准；跨设备墙钟偏差仍有影响，已对未来 5 分钟以上的异常墙钟做钳制。
6. **流式快照仍有磁盘峰值**：`VACUUM INTO` + 瘦身 `VACUUM` + ZIP 需要约 2–3 倍 DB 空间；未做剩余空间预检，未做 10 万/50 万级真机基准。
7. **gzip / bulk op 滚动升级**：旧版本客户端不识别 `.jsonl.gz` 与 `op='bulk'`；发布时需确保所有设备升级。
8. **并发锁是进程内锁**：`CloudSyncRunLock` 不能跨进程/跨 isolate 生效；单进程内已覆盖增量同步、快照上传/恢复、检查点与设备删除。
