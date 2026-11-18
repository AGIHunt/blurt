"""Versioned collection profiles; language means dominant utterance language.

tech_zh90_v1: 60% Mandarin, 30% Mandarin with English terms, 10% English.
70% AI/technical work, 30% general daily language, within each split and mode.
These are utterance quotas, not token/duration weights or demonstrated model support.
"""

# family, language, domain, prompt, English/code-switched terms
TECH_ZH90 = {
    "train": [
        ("document_summary", "zh", "tech", "请把这份文档总结成三个重点。", []),
        ("latency_diagnosis", "zh", "tech", "先检查延迟，再判断是不是网络问题。", []),
        ("dataset_filter", "zh", "tech", "这些训练样本里有重复内容，需要先清理。", []),
        ("gpu_allocation", "zh", "tech", "这次训练先用一张 GPU 跑起来。", ["GPU"]),
        ("api_timeout", "zh", "tech", "把这个 API 的超时时间改成十秒。", ["API"]),
        ("prompt_length", "zh", "tech", "这个 prompt 太长了，先删掉重复的要求。", ["prompt"]),
        ("validation_freeze", "en", "tech", "Keep the validation data separate from training.", []),
        ("coffee_order", "zh", "general", "我想要一杯不加糖的热咖啡。", []),
        ("umbrella", "zh", "general", "今天晚上可能下雨，出门记得带伞。", []),
        ("delivery_address", "zh", "general", "请把快递放在门口的架子上。", []),
    ],
    "validation": [
        ("search_quality", "zh", "tech", "搜索结果不太相关，我们需要检查排序。", []),
        ("permission_boundary", "zh", "tech", "这个操作只允许管理员执行。", []),
        ("rollout_recovery", "zh", "tech", "如果上线以后出错，就回滚到上一个版本。", []),
        ("token_budget", "zh", "tech", "先统计 token 数量，再估算调用成本。", ["token"]),
        ("git_conflict", "zh", "tech", "这个 Git 分支还有冲突，需要先解决。", ["Git"]),
        ("json_format", "zh", "tech", "返回的 JSON 少了一个字段。", ["JSON"]),
        ("reproduction", "en", "tech", "Please include the steps needed to reproduce this error.", []),
        ("lunch_booking", "zh", "general", "明天中午帮我订一张靠窗的桌子。", []),
        ("room_temperature", "zh", "general", "房间有点冷，把空调温度调高一些。", []),
        ("travel_schedule", "zh", "general", "我打算星期六早上坐火车出发。", []),
    ],
    "test": [
        ("speech_negation", "zh", "tech", "不要自动发送，先保存成草稿给我检查。", []),
        ("feature_feedback", "zh", "tech", "用户反馈这个按钮不太容易找到。", []),
        ("memory_limit", "zh", "tech", "内存占用超过八成时，先暂停新的任务。", []),
        ("rag_sources", "zh", "tech", "这个 RAG 回答需要附上来源链接。", ["RAG"]),
        ("agent_tool_call", "zh", "tech", "让 agent 先查资料，再调用工具执行。", ["agent"]),
        ("python_exception", "zh", "tech", "这个 Python 脚本在处理空列表时会报错。", ["Python"]),
        ("regression_test", "en", "tech", "Add a regression test before merging the fix.", []),
        ("appointment_change", "zh", "general", "我今天来不及了，可以改到后天下午吗？", []),
        ("contact_name", "zh", "general", "请告诉小陈，我大约五点半到。", []),
        ("grocery_quantity", "zh", "general", "买两盒牛奶和六个鸡蛋就够了。", []),
    ],
}


def tech_takes(speaker, modes):
    takes = []
    for split, rows in TECH_ZH90.items():
        for n, (family, lang, domain, prompt, terms) in enumerate(rows):
            for mode in modes[n % len(modes):] + modes[:n % len(modes)]:
                takes.append(dict(id=f"v2-{split}-{family}-{mode}", speaker_id=speaker,
                                  session_id=f"{split}-02", split=split, phrase_family=family,
                                  language=lang, language_profile="zh_en_mixed" if terms else lang,
                                  domain=domain, target_terms=terms, mode=mode, prompt=prompt))
    return takes
