# 云同步设计规格（S3 兼容对象存储）

> 状态：设计冻结草案 v1（2026-10-17）
> 目标：多设备同时使用时**不丢数据**；质量优先，允许较长工期。
> 关联代码：`BackupService`、`DatabaseService`、`CloudSyncService`、`S3StorageService`。

## 1. 结论与边界

- 采用**本地优先的事件日志同步（oplog）+ 周期检查点**，快照不再作为同步协议，仅用于：
  1. 新设备引导（bootstrap）；
  2. 灾难恢复；
  3. oplog 压缩后的基线。
- 不做中心服务端：对象存储只承担不可变对象读写。
- **不参与同步**：API Key、S3 凭据、主题/TTS/更新/隐私等本机设置、`sentence_eval_cache`、`ai_usage_records`、`ai_estimate_samples`。

## 2. 对象布局

```
{prefix}/devices/{deviceId}/
  meta.json                     # 设备名、平台、schemaVersion、lastSeen
  manifest.json                 # 该设备快照索引（引导用）
  snapshots/{utcTimestamp}.zip  # 全量快照（默认不含 API Key）
  chunks/{startSeq}-{endSeq}.jsonl
  checkpoints/{seq}.zip
  checkpoints/{seq}.json
  state.json                    # 本设备已应用到其它设备的水位线
```

约束：

- **每台设备只写自己的前缀**，对象写入后不可变（snapshots/chunks/checkpoints），因此不存在跨设备写冲突。
- 只使用 `PUT / GET / HEAD / LIST / DELETE`；不依赖条件写、对象锁、厂商扩展头。
- 单 chunk 上限 1 MB 或 500 条 op，先到者切分；单快照上限沿用 `BackupService.maxBackupSize`。
- 对象键只使用 `[a-z0-9._/-]`；时间戳统一 UTC `yyyyMMdd'T'HHmmssSSS'Z'`。

## 3. 事件模型

每条 op：

```json
{
  "v": 1,
  "device_id": "uuid-v4",
  "seq": 123,
  "hlc": "0000018f2c3a4b5c:0007",
  "entity": "word_notes",
  "key": {"word": "apple"},
  "op": "upsert",
  "data": {"note": "...", "is_favorited": 1, "updated_at": "..."},
  "delta": null,
  "deleted_at": null
}
```

- `seq`：设备内单调递增，用于**恰好一次**去重（`sync_applied(device_id, seq)` 唯一索引）。
- `hlc`：混合逻辑时钟（毫秒时间 + 逻辑计数），用于跨设备确定性排序；`HLC = max(now_ms, last_ms) ++`，相同毫秒用计数推进。
- `op`：`upsert` / `delete` / `increment`。
- `delta`：仅计数类实体使用（复习次数、错题次数、每日统计）。
- `deleted_at`：墓碑时间；删除后保留墓碑 ≥ 12 个月（或所有设备水位线越过）。

排序键：`(hlc, device_id, seq)`。相同实体同一字段冲突时取排序靠后者（LWW）；旧值仍保留在历史 chunk 中。

## 4. 表级语义

| 实体 | 键 | 同步模式 | 说明 |
|---|---|---|---|
| `user_word_records` | `word` | upsert(LWW) + increment(`review_count`) | `created_at = MIN`；状态取较新事件 |
| `wrong_words` | `word` | upsert / delete | `scheduled_date` LWW |
| `word_notes` | `word` | upsert / delete | 笔记、收藏 |
| `sentence_notes` | `sentence_id` | upsert / delete | 笔记、收藏 |
| `daily_activity` | `date` | increment ×4 + upsert(LWW) | 四个计数用增量；`completed/daily_goal` LWW |
| `word_books` | `uuid`（v13 新增） | upsert / delete | 删除级联条目（墓碑 + 级联 op） |
| `word_book_entries` | `(book_uuid, word)` | grow-only set / remove | 加入与移除分别记录 |
| `sentences` | `id` | upsert / delete | `sort_index REAL`（v13 新增）保证顺序 |
| `sentence_sets` | `id` | upsert / delete | v13 从 `SharedPreferences:sentence_sets_v1` 迁入 SQLite |
| `attempted_sentence_ids` | `(set_id, sentence_id)` | grow-only | 幂等插入 |
| `practiced_sentence_ids` | `(set_id, sentence_id)` | grow-only | 幂等插入 |
| `wrong_sentences` | `sentence_id` | upsert + increment(`wrong_count`) | `last_wrong_at = MAX` |
| `learning_sessions` | `uuid`（v13 新增） | upsert(LWW) | `duration_seconds` 为累计值，取较新事件的绝对值 |
| `vocab_test_history` | `uuid`（v13 新增） | insert | 幂等 |
| `sentence_eval_cache` | — | **排除** | 可重建缓存 |
| `ai_usage_records` / `ai_estimate_samples` | — | **排除** | 本机诊断 |

## 5. 捕获：SQLite 触发器

- 每张同步表 3 个触发器：`AFTER INSERT / UPDATE / DELETE`。
- 触发器与业务写入处于**同一事务**：数据落库 ⇒ op 已记录，不存在应用层漏打点。
- 触发器写入类型化 `oplog_<entity>` 表（避免依赖 SQLite JSON1，Android 系统 SQLite 版本差异大）。
- 抑制远程写入回环：

```sql
WHEN (SELECT applying FROM sync_meta WHERE id = 1) = 0
```

- 计数器在触发器中计算增量：`NEW.review_count - COALESCE(OLD.review_count, 0)`。
- 触发器由 `SyncTableSpec` 统一生成，避免与执行引擎语义漂移。

## 6. 应用：幂等与事务

```
for chunk in pull():
  verify sha256
  BEGIN IMMEDIATE
    applying = 1
    for op in sort(chunk.ops):
      if sync_applied 已存在 (device_id, seq): continue
      apply(op)
      insert sync_applied
    applying = 0
  COMMIT
```

失败处理：

- 任一 op 抛错 → 整个 chunk 回滚，记录错误，保留待重试；不阻塞其它 chunk 的下载。
- 应用前本地 `VACUUM INTO` 快照（沿用 `DatabaseService.exportDatabaseCopy`）。
- 单 chunk 可重复应用（幂等）。

## 7. 引导、检查点与回收

- 新设备：下载最近 checkpoint + 恢复 → 按 checkpoint 中记录的各设备水位线补拉 chunk。
- 检查点频率：每 5000 条 op 或 7 天（先到者），保留最近 3 个。
- chunk/checkpoint 回收：只有当所有活跃设备的 `state.json` 水位线都越过该对象、且超过保留期（默认 30 天）才允许删除。
- 设备失联：180 天未更新 `meta.json` 视为失联，可从水位线计算中排除（需手动确认）。

## 8. 安全

- AK/SK 仅存 `flutter_secure_storage`；日志、错误、崩溃信息禁止包含密钥或签名。
- 快照/ chunk 默认不含 API Key；`ai_profiles_v2` 不同步。
- 传输强制 HTTPS；HTTP 端点仅在开发调试中允许，并在 UI 明确警告。
- 建议私有桶 + 最小权限：`s3:GetObject/PutObject/DeleteObject/ListBucket`，资源限制到 `{prefix}/*`。
- 可选端到端加密：口令 → Argon2id → AES-GCM（chunk 头存 nonce/KDF 参数），口令不落盘。

## 9. 测试门禁

1. **表分类覆盖率**：所有业务表必须显式标记「同步 / 排除」，同步表必须有 3 个触发器。
2. **写路径覆盖**：每个 service 代表性写操作都产生预期 op。
3. **收敛性**：随机多设备操作 + 多轮同步 → 同步表内容一致。
4. **幂等性**：同一 chunk 应用两次结果一致。
5. **崩溃注入**：上传后标记失败、应用中断、哈希不符均可安全重试。
6. **迁移测试**：v12 → v13（含空库、历史重复错题、Prefs 句式集空 id）。
7. **多端手工矩阵**：MinIO / R2 / AWS / Rain（本项目测试桶），Windows ↔ Android。

## 10. 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | PoC：Rain S3 读写/列举/删除 | ✅ 已完成（path-style + `cn-nb1`） |
| 1 | 配置与凭据、S3 客户端封装、连接测试、设置页 UI | ✅ 已完成 |
| 2 | 设备隔离快照上传/下载 + manifest（引导/灾备能力） | ✅ 已完成 |
| 3 | schema v13 + 触发器生成器（`sentence_sets` 入库暂缓） | ✅ 已完成（DB 内 13 张表） |
| 4 | chunk push/pull + 应用引擎（LWW/delta/墓碑） | ✅ 已完成 |
| 5 | 自动同步编排、GC、冲突/状态 UI | ✅ 自动同步（启动/回前台 + 15 分钟冷却）、保守 chunk GC 已完成；冲突明细 UI 待补 |
| 6 | 收敛性/幂等/崩溃/迁移测试与文档 | 🚧 单测 + 真实 S3 双设备 E2E 已通过；崩溃注入待补 |

> 阶段 2 的快照能力不会白做：它就是阶段 3+ 的 checkpoint/bootstrap 载体。

## 11. 阶段 2 实现清单

| 文件 | 职责 |
|---|---|
| `lib/models/cloud_sync_manifest.dart` | 清单/快照模型、版本校验、SHA-256、对象键时间戳 |
| `lib/services/cloud_sync_settings.dart` | 配置校验、Prefs 持久化、Secure Storage 凭据、设备标识 |
| `lib/services/s3_storage_service.dart` | MinIO 客户端封装、超时、错误中文化、连接自检 |
| `lib/services/cloud_sync_service.dart` | 设备隔离快照上传/恢复、清单维护、历史清理、恢复前本机快照 |
| `lib/pages/settings/cloud_sync_config_page.dart` | 配置表单、连接测试、设备标识管理 |
| `lib/pages/settings/sections/cloud_sync_section.dart` | 云同步入口、上传、设备选择与恢复 |
| `lib/services/backup_service.dart` | 新增 `localOnlyPrefPrefix`：云同步配置不进入备份、不被恢复覆盖；恢复后清理快照携带的 oplog 并写入同步基线 |
| `lib/services/sync_table_spec.dart` | 同步表规格 + oplog 表 / 触发器生成 |
| `lib/services/sync_schema.dart` | 同步系统表、v13 安装、恢复后运行时状态重置 |
| `lib/services/sync_capture_service.dart` | HLC 分配、JSONL chunk 导出、本地行版本、上传后清理 |
| `lib/services/sync_apply_service.dart` | 幂等应用、行版本门禁、计数增量、墓碑、父级重试 |
| `lib/services/cloud_sync_engine.dart` | 拉取远端 chunk + 推送本机 chunk、基线过滤、消费 `sync_chunks` |
| `lib/services/cloud_sync_auto_sync_service.dart` | 启动 / 回前台自动同步、15 分钟冷却、并发保护 |
| `lib/services/cloud_sync_maintenance_service.dart` | 保守 chunk GC（每设备保留最近 1000 个 + 180 天） |

已通过的验证：

- `flutter analyze`：新增文件无告警；
- 186 个测试通过（含 v13 迁移、捕获开关、触发器、捕获/应用引擎、词书父级重试、墓碑与计数、自动同步配置）；
- 真实 Rain S3 集成测试通过（连接自检、设备清单、**双设备增量同步收敛**）。

### 当前已知限制

- `sentence_sets` 元数据仍在 SharedPreferences 中，暂只通过完整快照同步；
- 冲突明细 UI 与崩溃注入测试待补；远程 GC 采用保守策略：
  离线超过 180 天的设备可能错过已清理的 chunk，可用完整快照恢复；
- 首次接入云同步时，历史数据不会被追溯为 oplog：
  建议先「立即上传备份」并在其它设备「从云端恢复」，再使用增量同步；
- 未配置云同步时默认不捕获（`sync_meta.capture_enabled = 0`），
  配置成功后自动开启；清除配置会停止捕获并清空 oplog。

