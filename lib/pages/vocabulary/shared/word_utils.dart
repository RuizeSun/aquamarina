/// 将数据库中的字面 \n 替换为真正的换行符
String normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

/// 提取翻译字符串中的第一条含义
String extractFirstMeaning(String? translation) {
  if (translation == null || translation.isEmpty) return '（无释义）';
  // 取第一条释义：按换行、中文分号/逗号/句号分割取第一段
  // 注意：不按英文句点分割，避免把 "a. 一个" 切出孤立的 "a"
  final parts = translation.replaceAll('\\n', '\n').split(RegExp(r'[\n；;，,]'));
  for (final p in parts) {
    final trimmed = p.trim();
    if (trimmed.isEmpty) continue;
    // 去掉开头的词性标记，如 "a." "n." "v." "adj." "adv." "pron." "prep." 等
    final cleaned = trimmed
        .replaceFirst(RegExp(r'^[a-z]+\.\s*', caseSensitive: false), '')
        .trim();
    if (cleaned.isNotEmpty) return cleaned;
  }
  return translation;
}
