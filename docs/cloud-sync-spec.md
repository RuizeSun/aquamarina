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
  head.json                     # 最近一个 chunk 的键 / HLC / 数量（拉取前先读）
  state.json                    # 本设备已应用到其它设备的水位线（GC 依据）
  chunks/{hlc}-{sha256}.jsonl.gz    # gzip 压缩，完整 SHA-256
  checkpoints/                       # 当前复用 snapshots/ 作为自动检查点
```

约束：

- **每台设备只写自己的前缀**，对象写入后不可变（snapshots/chunks/checkpoints），因此不存在跨设备写冲突；`head.json` 与 `state.json` 也只由所属设备写。
- 只使用 `PUT / GET / HEAD / LIST / DELETE`；不依赖条件写、对象锁、厂商扩展头。
- 设备发现使用 `LIST {prefix}/devices/` 的非递归 CommonPrefixes，不递归列举全部 chunk。
- 单 chunk 上限 1 MB（未压缩 JSONL）或 500 条 op，先到者切分；上传前 gzip；单快照上限沿用 `BackupService.maxBackupSize`。
- 对象键只使用 `[a-z0-9._/-]`；时间戳统一 UTC `yyyyMMdd'T'HHmmssSSS'Z'`。

## 3. 事件模型

每条 op：

```json
{
  "v": 2,
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
- `hlc`：混合逻辑时钟（毫秒时间 + 逻辑计数），用于跨设备确定性排序；`HLC = max(now_ms, last_ms) ++`，相同毫秒用计数推进。应用远端 op 时必须执行 receive 步骤：把本地 HLC 推进到本批远端 op 的最大 HLC，保证“看到远端后再编辑”的本地写入排在远端之后。
- `op`：`upsert` / `delete` / `bulk`；`bulk` 使用 `items: [{entity,key,data,delta}]` 承载多条实体操作（用于大批量导入，只占一条 seq）。
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
| `sentence_sets` | `id` | upsert / delete | v14 从 `SharedPreferences:sentence_sets_v1` 迁入 SQLite |
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
- 触发器同时写入 `captured_at_ms`（UTC 墙钟），导出时以此生成 HLC，避免晚导出获得不合理的更晚时间。
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

- 新设备：首次配置时若本机为空，提示恢复云端最新快照（checkpoint）；设置页也提供「从最新检查点引导」，可随时灾备恢复。
- 检查点频率（v16 已实现）：每 5000 条 op 或 7 天（先到者）自动上传完整快照，受「保留份数」约束。
- **head / state 水位（v15 已实现）**：
  - `head.json`：所属设备最近一个 chunk 的 `latest_chunk_key` / `latest_hlc` / `chunk_count`；
  - `state.json`：`applied: {来源设备 ID: 已完整应用的最大 chunk 起始 HLC}`；
  - 拉取前先读 head；`head.latest_hlc <= 本地 sync_state.last_hlc` 时跳过 LIST；
  - 需要拉取时只 LIST 该设备 `chunks/`，并用 `startAfter=last_chunk_key` 取尾部增量；
  - 缺失父级或下载失败时不推进水位，下次从同一位置重试。
- chunk 回收（v15 已实现）：
  - 仅当所有活跃设备（head/state 180 天内更新）都越过该 chunk 起始 HLC，且对象超过 30 天才删除；
  - 任一非 owner 活跃设备缺少 `state.json` 时，本轮不按水位删除；
  - 删除后按「下一个保留 chunk 的起始 HLC」清理本地 `sync_applied`；墓碑在所有活跃设备水位越过且超过 180 天后清理。
- 设备失联：180 天未更新 `head.json` / `state.json` 视为失联，可从水位线计算中排除。
- 恢复快照后：`baseline_hlc` 之前的 chunk 全部跳过；本机在基线之后、且尚未被本机标记为已应用的 chunk 只重放一次。
  - 本机推送成功后会把 chunk 写入 `sync_chunks`，避免下一轮 pull 把自己刚上传的 chunk 再应用一次；
  - 计数类字段不能承受任何重放，因此这条“只重放一次”是必须保持的不变量。
- 重置设备标识后，旧设备 ID 会写入本机 `cloud_sync_ignored_devices_v1`：不再拉取旧目录，但会用其 `head.json` 水位发布 `state.json`，避免旧目录永久阻塞 GC。

## 8. 安全

- AK/SK 仅存 `flutter_secure_storage`；日志、错误、崩溃信息禁止包含密钥或签名。
- 快照/ chunk 默认不含 API Key；`ai_profiles_v2` 不同步。
- 传输强制 HTTPS；HTTP 端点仅在开发调试中允许，并在 UI 明确警告。
- 建议私有桶 + 最小权限：`s3:GetObject/PutObject/DeleteObject/ListBucket`，资源限制到 `{prefix}/*`。
- 可选端到端加密：**not planned**，不纳入后续开发计划（曾评估：口令 → Argon2id → AES-GCM，chunk 头存 nonce/KDF 参数，口令不落盘）。

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
| 3 | schema v13 + 触发器生成器（`sentence_sets` 于 v14 入库） | ✅ 已完成（DB 内 14 张同步表） |
| 4 | chunk push/pull + 应用引擎（LWW/delta/墓碑） | ✅ 已完成 |
| 5 | 自动同步编排、GC、冲突/状态 UI | ✅ 启动/回前台同步、学习结束事件同步、前台轮询、head/state 水位 GC、冲突页、设备管理、仅 Wi-Fi / 退避均已完成 |
| 6 | 收敛性/幂等/崩溃/迁移测试与文档 | ✅ 242 项测试通过（真实 S3 下 246 项）；含 gzip、完整 SHA、时间预算、captured_at HLC、HLC receive、批量 op、冲突解决、来源水位恢复、真实 S3 双设备 E2E |
| 7 | 性能与快照 | ✅ gzip、完整 SHA、apply 预载/batch、流式快照、快照瘦身、自动检查点、新设备引导 |
| 8 | 批量与设备管理 | ✅ bulk op（含与普通 op 相同的行版本门禁）、chunk 50-op 小事务、接管并合并旧设备（拉取不完整时禁止删除）、冲突版本推进、墙钟钳制、本机 chunk 不回放、设备重置隔离、HLC receive |

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
| `lib/services/cloud_sync_auto_sync_service.dart` | 启动 / 回前台自动同步、按配置间隔冷却、并发保护 |
| `lib/services/cloud_sync_foreground_sync_service.dart` | 前台轮询、生命周期启停、事件同步后重置计时 |
| `lib/services/cloud_sync_activity_sync_service.dart` | 学习结束事件同步：2 秒防抖、push 优先、按需 pull |
| `lib/services/cloud_sync_maintenance_service.dart` | 保守 chunk GC（每设备保留最近 1000 个 + 180 天） |
| `lib/services/ai_sentence_set_service.dart` | 句式集元数据迁入 SQLite（v14），CRUD 走事务并纳入触发器同步 |
| `lib/services/cloud_sync_checkpoint_service.dart` | 7 天 / 5000 op 自动检查点 |
| `lib/services/cloud_sync_bootstrap_service.dart` | 新设备空库检测与最新快照引导 |
| `lib/services/cloud_sync_network_service.dart` | 仅 Wi-Fi / 以太网策略 |
| `lib/services/sync_conflict_store.dart` | 冲突持久化与三种解决动作 |
| `lib/pages/settings/cloud_sync_conflict_page.dart` | 冲突逐条处理页 |
| `lib/pages/settings/cloud_sync_devices_page.dart` | 云端设备列表 / 删除旧设备 |

已通过的验证：

- `flutter analyze`：仅剩仓库原有的 9 条 info，无新增告警；
- 无 S3 环境变量时 242 passed / 4 skipped；设置真实 S3 后 246 passed：含 v13–v19 迁移、捕获开关、触发器、捕获/应用引擎、词书父级重试、墓碑与计数、句式集入库、自动同步配置、前台轮询/事件同步、上传失败与损坏 chunk 重试、gzip/完整 SHA、时间预算、`captured_at_ms` HLC、HLC receive、bulk op 版本门禁、本机 chunk 不回放、设备重置隔离、接管完整性保护、后端配置切换与水位缓存、快照来源水位、级联子表墓碑、冲突解决/清理、检查点退避、流式文件上传下载、网络策略；
- 真实 Rain S3 集成测试通过（连接自检、设备清单、head/state、**双设备增量同步收敛**）。

### 当前已知限制

- 远程 GC 已改为按设备水位：所有活跃设备（180 天内更新）都应用后才会删除，
  并保留至少 30 天；离线超过 180 天的设备可能错过已清理的 chunk，可用完整快照恢复；
- 首次接入云同步时，历史数据不会被追溯为 oplog：
  建议先「立即上传备份」并在其它设备「从云端恢复」，再使用增量同步；
- 未配置云同步时默认不捕获（`sync_meta.capture_enabled = 0`），
  配置成功后自动开启；清除配置会停止捕获并清空 oplog。
- 句式集元数据 v14 起在 SQLite，旧版 `sentence_sets_v1` 会在首次加载时
  惰性迁移；新备份不再导出旧 Prefs key。
- 批量导入已使用 `bulk` op，上传只占一条 seq；应用端仍逐条写入可幂等实体。
- 业务表应用会预载行并在事务末尾 batch 写回；`word_books` 插入因需要自增 id 仍即时执行；
  chunk 已按 50 op 小事务提交，时间预算/取消可在小批之间生效。
- checkpoint 水位未用于裁剪 GC：直接用 checkpoint 删除 chunk 会让仍在线设备失去增量，
  因此继续使用活跃设备 `state.json` 水位。
- **P2-3 端到端加密**、**P2-4 账号 / 多租户** 均为 **not planned**，不纳入后续开发计划；当前安全边界仍为
  TLS + 私有桶 + 设备前缀隔离。
- 切换 endpoint / bucket / prefix 时会保存旧后端水位并在切回时恢复，不会重拉历史；但在其它后端期间产生的本地变更已经上传到那个后端，切回后需要一次快照才能传播到旧后端。
- 旧版本导出的快照没有 `sync_watermarks`，仍使用“快照创建时间”基线；导出方未拉全的其它设备变更可能被跳过。
- 行版本 / 墓碑按 180 天 + 活跃设备水位清理；离线超过 180 天的设备重新加入时可能带回旧事件。
- 没有 head/state 的设备目录会被 GC 跳过，不参与活跃设备判断。
- 父级删除后，HLC 晚于删除时间的子表 op 仍可能成为孤儿或等待父级；墓碑只保证更旧的子表 op 不复活。

