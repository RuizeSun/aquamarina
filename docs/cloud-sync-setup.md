# 云同步配置与使用

> 当前版本同时提供两种能力：
> 1. **增量同步（推荐日常使用）**：按设备 oplog 只传输变更，词书/单词记录/笔记/错题/学习统计/句式集跨设备自动合并；
> 2. **设备隔离快照**：完整备份、历史版本、灾备与新设备引导；恢复仍为覆盖式。
> 句式集元数据 v14 起在 SQLite，随增量同步；旧版 Prefs 数据会在首次加载时惰性迁移。

## 1. 支持的后端

任何兼容 S3 API 的对象存储：

- Rain / 雨云 S3（本次验证：`cn-nb1` 区域 + path-style）
- MinIO（自建）
- Cloudflare R2（区域填 `auto`）
- AWS S3（区域填真实区域，可关闭 path-style）
- 其它兼容实现（只要求 PUT / GET / HEAD / LIST / DELETE）

## 2. 配置步骤

App 内路径：`设置 → 云同步 → 对象存储配置`。

| 字段 | 说明 | 示例 |
|---|---|---|
| 访问端点 | 只填域名和端口，不带桶名/路径 | `https://cn-nb1.rains3.com` |
| 存储桶 | 桶名（小写字母/数字/点/短横线） | `aquamarina-test` |
| 区域 | 服务商要求的 region | `cn-nb1` / `us-east-1` / `auto` |
| 路径前缀 | 所有对象都放在此前缀下 | `aquamarina` |
| path-style | 自建/非 AWS 端点通常开启 | 开启 |
| 云端保留份数 | 每台设备保留的历史快照数量 | 5 |
| Access Key / Secret Key | 只保存在本机 Secure Storage | 不要写进任何文档或仓库 |

保存前会执行一次真实自检：Bucket 可访问、可写、可读、可删、可列举。
若当前网络无法连接，可选择「仍然保存」，稍后再点「测试连接」。

## 3. 云端对象布局

```
{prefix}/devices/{deviceId}/
  manifest.json                     # 本设备快照索引（时间/大小/SHA-256/是否含 API Key）
  snapshots/{utcTimestamp}.zip      # 不可变快照，默认不含 API Key
```

- 每台设备只写自己的 `devices/{deviceId}/`，**不会覆盖其它设备的备份**。
- 清单最后写入；即使上传中断也只会留下孤儿快照，不会产生坏清单。
- 超过「保留份数」的旧快照会在上传成功后自动清理。

## 4. 最小权限策略

建议使用私有桶，并只授予该前缀的读写权限。以 AWS/MinIO 策略为例（把
`BUCKET`、`PREFIX`、`USER_ARN` 替换成实际值）：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AquamarinaCloudSync",
      "Effect": "Allow",
      "Principal": { "AWS": "USER_ARN" },
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::BUCKET",
        "arn:aws:s3:::BUCKET/PREFIX/*"
      ]
    }
  ]
}
```

Rain / R2 控制台的「密钥权限」按同样思路限制到桶 + 前缀即可。

## 5. 安全说明

- Access Key / Secret Key 仅存 `flutter_secure_storage`，不写入备份、不上传云端。
- 快照默认**不包含 AI API Key**；上传时可以显式勾选包含（不建议）。
- 云同步配置（端点/桶/设备标识/同步状态）是设备本地设置：
  导出备份时会被排除，恢复备份时也不会被覆盖，避免设备身份错乱。
- 日志不会输出密钥或签名；错误信息只包含可读原因。
- 强制 HTTPS；Mobile 端默认拦截 HTTP 明文（配置页会对 HTTP 端点给出警告）。

## 6. 增量同步（推荐）

`设置 → 云同步 → 增量同步`：

- 拉取其它设备的 changelog，并按表语义合并到本机；
- 上传本机待同步变更（每 500 条 / 900 KB 一个不可变 chunk）；
- 删除通过墓碑同步；重复应用幂等；迟到/乱序操作由 HLC + 行版本保护；
- 计数类（复习次数、错题次数、每日学习数）按增量累加，不会因合并丢失。

自动同步：配置页可开启「启动 / 回到前台时自动同步」，两次自动同步至少间隔 15 分钟；
失败只写日志，不弹窗、不影响手动同步。未配置云同步时默认不记录 oplog，
配置成功后自动开启，清除配置会停止捕获并清空 oplog。

云端维护：每次同步后按 7 天冷却执行保守清理——每台设备保留最近 1000 个变更包，
且仅删除 180 天前的对象（服务端必须返回 `lastModified`）。
长期离线设备可用完整快照恢复后继续增量同步。

首次接入建议流程：

1. 在数据最全的设备上「立即上传备份」；
2. 在其它设备「从云端恢复」该快照（覆盖本地，恢复前会自动保留本机快照）；
3. 之后各设备日常点「增量同步」即可。

> 原因：v13 之前的历史写入没有被记录为 oplog。快照恢复后会自动写入同步基线，
> 基线之前的历史 chunk 会被跳过，避免计数重复累加。

## 7. 恢复行为

`从云端恢复` 会：

1. 列出所有设备的 `manifest.json`，显示设备名、备份时间、大小、是否含 API Key；
2. 下载所选快照并校验大小 + SHA-256；
3. 通过 SQLite `VACUUM INTO` 保留一份**恢复前本机快照**
   （`应用支持目录/sync_snapshots/pre_restore_*.db`，保留最近 3 份）；
4. 覆盖导入（复用 `BackupService.importBackup`，失败自动回滚）；
5. 提示建议重启应用，避免页面内存状态与数据库不一致。

恢复是**覆盖式**的：另一台设备的新数据不会自动并入本机。这正是后续
oplog 增量同步要解决的问题。

## 8. 验证与排查

自动化测试：

```powershell
flutter test test/cloud_sync_config_test.dart test/cloud_sync_manifest_test.dart test/cloud_sync_service_test.dart
```

真实存储集成测试（默认跳过，未设置环境变量时不会联网）：

```powershell
$env:S3_ENDPOINT='cn-nb1.rains3.com'
$env:S3_BUCKET='<bucket>'
$env:S3_REGION='cn-nb1'
$env:S3_ACCESS_KEY='<access-key>'
$env:S3_SECRET_KEY='<secret-key>'
$env:S3_PREFIX='aquamarina-ci'
flutter test test/cloud_sync_s3_integration_test.dart
```

常见错误：

| 现象 | 原因 / 处理 |
|---|---|
| `存储桶不存在，或当前密钥无权访问该桶` | 桶名错误；或密钥没有 ListBucket 权限 |
| `SignatureDoesNotMatch` | Secret Key 错误；或 region / 端点与服务器不一致 |
| `RequestTimeTooSkewed` | 本机时间偏差过大，校准系统时间 |
| `TLS 握手失败` | 端点应使用 HTTPS，或证书链不完整（自签证书需系统信任） |
| 移动端 HTTP 请求被拦截 | 改用 HTTPS；Android 9+ / iOS ATS 默认禁止明文 |
| `请求过于频繁` | 服务端限流，稍后重试 |

## 9. 后续阶段

见 `cloud-sync-spec.md`：远程 GC 保留策略进一步收紧（按设备水位线而非仅时间）、
大批量数据的性能验证与系统性崩溃注入。
