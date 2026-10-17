# 结构化运行报告 · Schema 设计（0.2.0 输入之一）

> **状态：设计稿，不写实现。** 目标是让 CLI / CI / Agent 能**直接消费**运行报告，
> 不用解析人类可读日志；同时**不**把敏感内容与绝对路径写进报告。
>
> 与人类可读输出是**附加关系**：不传 `-Json`（或等价开关）时行为完全不变。

---

## 0. 为什么需要

现有输出是人类可读文本（`状态：Written` / `改动预览` / `审计可读回`）。对人和终端友好，
但机器消费要解析中文、处理排版变化（已经踩过：cp437 下中文变 `?`，断言依赖字形）。

JSON 报告要回答的问题：

- 这次操作**做了什么**（opId / 类型 / 目标）
- 走到**哪个阶段**（快照 / 备份 / 写 / 复验 / 审计 / 回滚）
- 结果**是什么**（状态 / 退出码 / 恢复状态）
- **出了什么错**（错误分类 + 脱敏消息）
- **证据在哪**（备份 hash / 写后 hash / diff 行数）

---

## 1. Schema（草案 v1）

```jsonc
{
  "schema": 1,
  "generatedAt": "2026-10-18T02:31:00+08:00",
  "tool": { "name": "WriteGuard", "version": "0.2.0" },

  "operation": {
    "opId": "wg-20261018-023100-a1b2c3",      // 唯一；审计日志同源
    "type": "write",                            // write | json | replace | batch | prune
    "command": "replace",                       // CLI 子命令（库调用时可为 null）
    "targets": [
      { "path": "README.md", "kind": "text" }   // ⚠️ 相对路径或脱敏，见 §3
    ]
  },

  "phases": [                                   // 按时间顺序，失败点及之后不再出现
    { "name": "snapshot",  "status": "ok",  "detail": { "sha256": "…", "length": 1234 } },
    { "name": "backup",    "status": "ok",  "detail": { "backup": "README.md@ab12cd34.bak-…", "sha256": "…" } },
    { "name": "write",     "status": "ok",  "detail": { "changedLines": 3, "sha256After": "…" } },
    { "name": "verify",    "status": "ok",  "detail": { "ok": true } },
    { "name": "audit",     "status": "ok",  "detail": { "written": true } },
    { "name": "rollback",  "status": "skipped", "detail": { "reason": "no failure" } }
  ],

  "result": {
    "status": "Written",                        // 与 Get-WgStatusTable 的键**完全一致**
    "exitCode": 0,                              // 与 Get-WgExitCode 一致
    "recovery": "none",                         // none | restored | refused | failed
    "wrote": true
  },

  "error": {
    "category": null,                           // 见 §2；null = 无错误
    "message": null                             // 脱敏后的人类可读消息
  },

  "evidence": {
    "backupSha256": "…",
    "sha256Before": "…",
    "sha256After": "…",
    "changedLines": 3,
    "diffLines": 3,
    "auditRecord": "opId 对应的审计行（可选，默认不内联）"
  },

  "environment": {
    "pwsh": "7.6.6",
    "os": "Windows 10.0.26200",
    "consoleCodePage": 65001
  }
}
```

### 约束

1. `result.status` 与 `Get-WgStatusTable` 的键**一一对应**（加状态没进表 ⇒ ㊲ 会炸，这是好事）。
2. `result.exitCode` 与 `Get-WgExitCode` 一致。
3. `phases` 的顺序固定；失败点之后不再出现（不写"没发生的阶段"）。
4. `opId` 与审计日志里的 `opId` 同源，可互查。
5. 字段名用 camelCase，避免中文键（机器消费友好）。

---

## 2. 错误分类（`error.category`）

| 值 | 含义 | 对应现有状态 |
|---|---|---|
| `none` | 无错误 | Written / NoChange / DryRun |
| `not-found` | 目标不存在（不新建） | Refused（文件不存在） |
| `not-unique` | 0/多匹配 | Refused / Error（唯一性） |
| `changed-externally` | 快照后被第三方改 | Refused（TOCTOU） |
| `encoding` | 无效字节 / 往返不自洽 | Error |
| `too-many-changes` | 改动面超上限 | Refused |
| `audit-blocked` | 严格审计失败、写入作废 | AuditBlocked |
| `rollback-refused` | 回滚前发现第三方改动 | RollbackRefused |
| `rollback-failed` | 回滚本身失败 | 现有 RollbackIssues |
| `lock-busy` | 锁被占 | Refused（锁） |
| `framework` | 库内部异常（不该发生） | Error |

> 分类是**给机器消费的**；人类可读消息另放 `message`。两者不混用。

---

## 3. 敏感信息边界（硬规则）

| 规则 | 做法 |
|---|---|
| **不写绝对路径** | `targets[].path` 用**相对工作区**的路径；无法相对时用 `<abs>` 占位 + 路径 hash |
| **不写文件内容** | 只写 hash / 长度 / 改动行数；正文永远不内联 |
| **不写 secrets** | 不写环境变量、token、凭据；审计记录里的 `Note` 字段也要脱敏（用户可能把密码传进 `-Value`） |
| **不写用户名** | 路径里若出现用户名，替换为 `<user>` |
| **diff 不内联** | 只写 `diffLines` 计数；要看内容让调用方自己读文件 |
| **可选**：`-Redact` | 默认脱敏；需要完整路径时显式 `-RawPaths`（文档写明风险） |

**反例**（不要写进报告）：

```jsonc
"targets": [{ "path": "C:\\Users\\17586\\AppData\\Local\\Temp\\…\\cfg.json" }]   // ❌ 绝对路径 + 用户名
"error": { "message": "无法写入 C:\\…\\secret.txt（内容：password=…）" }          // ❌ 内容/凭据
```

**正例**：

```jsonc
"targets": [{ "path": "cfg.json", "pathHash": "ab12cd34" }]                       // ✅ 相对 + 短 hash
"error": { "message": "文件不存在（不新建）", "category": "not-found" }             // ✅ 分类 + 无路径
```

---

## 4. 与人类可读输出的关系

- 默认**不改变**任何输出（现有调用方零影响）；
- `-Json <path>`：人类可读照旧输出，同时写 JSON；
- `-JsonOnly`（可选）：只写 JSON，不打印（给 Agent/CI 用）；
- 报告写入失败 ⇒ **不让主操作作废**（报告是旁路，同审计轮转的规则），但要在退出码/告警里报出来。

---

## 5. 验收判据（将来实现时）

1. 同一操作的人类可读输出与 JSON `result.status` / `exitCode` **一致**；
2. 报告里**不含绝对路径、不含文件内容、不含凭据**（可用正则扫描验证）；
3. `phases` 顺序正确，失败点之后不出现阶段；
4. `opId` 与审计日志的 `opId` 可互查；
5. 不传 `-Json` 时，现有测试（57/30/5/10）**全绿**，行为零变化。

---

## 6. 不做的

- 不把 JSON 当**唯一**输出（人类可读不能删）；
- 不内联文件内容/diff（体积 + 敏感信息双重风险）；
- 不在报告里做"判断"（报告只记录事实；判断留给调用方）。

---

*生成：2026-10-18。设计稿，不写实现；实现前先过 §5 验收判据。*
