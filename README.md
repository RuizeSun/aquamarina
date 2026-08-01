# Aquamarina

Aquamarina 是一款基于 Flutter 的英语学习应用，内置离线英汉双词典，集查词、背单词与 AI 句型练习于一体。

## ✨ 功能特性

- **🔍 离线词典**：内置 ecdict 与 CC-CEDICT 双词典，支持英汉互查、模糊搜索，无需联网
- **📖 背单词**：词书管理、浏览 → 选择 → 回忆分阶段学习、间隔重复复习、拼写练习，支持连续打卡与今日学习统计
- **🤖 AI 句型练习**：句式集管理，支持从在线语料库导入；入门版（选词块）与高阶版（自由输入）两种模式；AI 智能批改，自动收录错题本
- **🎙️ 语音朗读**：内置 TTS 语音合成，支持单词与句子的朗读
- **🎨 主题定制**：亮色 / 深色 / 跟随系统三种模式，支持自定义主题色
- **🔌 灵活接入**：支持 DeepSeek 及自定义 API 接入句型批改，也可本地部署开源模型

## 🚀 开始使用

### 环境要求

- Flutter SDK `^3.11.5`

### 运行步骤

```bash
flutter pub get
flutter run
```

## 🛠️ 技术栈

- **Flutter / Dart**：跨平台 UI 框架
- **SQLite（sqflite）**：本地业务数据与内置词典数据库
- **flutter_tts / flutter_edge_tts**：语音合成
- **dio**：AI 批改服务的网络请求
- **shared_preferences**：本地偏好设置

## 📄 许可证

本项目基于 [MIT](LICENSE) 许可证开源。

内置词典数据来源于 [ecdict（星火词典）](https://github.com/skywind3000/ECDICT) 与 [CC-CEDICT](https://cc-cedict.org/)，均遵循 MIT 许可证。
