/// Storage and presentation have independent limits. Compact in batches to
/// avoid rewriting a multi-megabyte journal for every new diagnostic entry.
const logStorageBytes = 8 * 1024 * 1024;
const logCompactBytes = 7 * 1024 * 1024;
const logStorageEntries = 30000;
const logVisibleEntries = 500;
const logRetentionDescription =
    '完整记录按约 8 MiB 容量轮换（最多 30000 条保护上限），页面最多显示最近 500 条；导出包含全部保留记录';
