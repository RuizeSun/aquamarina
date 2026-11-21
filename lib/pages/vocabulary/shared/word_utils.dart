/// 将数据库中的字面 \n 替换为真正的换行符
String normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

/// 根据「回忆结果 + 选择题结果」统一计算本次学习结果。
///
/// 两个页面此前逻辑不一致：学习页完全忽略选择题，复习页却用它交叉
/// 校验，同一个词在两条流程里会得到不同的 stage。统一到这里，并允许
/// 调用方在没有选择题时传 null。
///
/// 返回 `easy` / `hard` / `forgot`：
/// - 一开始就没想起来：选择题选对 → hard（可能是蒙的），选错 → forgot；
/// - 自认为记得但答错 → hard；
/// - 确实答对：再参考选择题，选对 → easy，选错 → hard。
String gradeRecallResult({required bool recalled, bool? quizCorrect}) {
  // 没有选择题（或尚未生成）时，退化为纯回忆判定
  if (quizCorrect == null) {
    return recalled ? 'easy' : 'forgot';
  }
  if (!recalled) {
    return quizCorrect ? 'hard' : 'forgot';
  }
  return quizCorrect ? 'easy' : 'hard';
}

/// 提取翻译字符串中的第一条含义
String extractFirstMeaning(String? translation) {
  if (translation == null || translation.isEmpty) return '';
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
  return '';
}
