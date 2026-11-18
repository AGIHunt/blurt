#!/usr/bin/env python3
"""Prepare, but never activate, a broader enrollment draft without reusing holdout phrases."""
import argparse
from collections import Counter
from pathlib import Path
from dataset import load_clips, validate_plan, write_json

# 24 Mandarin, 12 mixed and 4 English unique phrases; 28 technical, 12 general.
ROWS = [
 ('font_rendering','zh','tech','这个字体在小字号下，笔画看起来有些模糊。',[]),
 ('window_position','zh','tech','下次打开程序时，恢复窗口原来的大小和位置。',[]),
 ('weight_checksum','zh','tech','下载完成以后，请校验模型权重文件的完整性。',[]),
 ('experiment_seed','zh','tech','每组实验都使用固定的随机种子，并记录配置。',[]),
 ('model_license','zh','tech','先确认模型的授权范围，再考虑是否可以商用。',[]),
 ('style_priority','zh','tech','这两条样式规则互相覆盖，需要明确优先级。',[]),
 ('paragraph_indent','zh','tech','把第二段的缩进取消，其他段落保持原样。',[]),
 ('timestamp_zone','zh','tech','日志里的时间戳需要显示为用户所在的时区。',[]),
 ('vector_dimensions','zh','tech','两个向量的维度不一致，所以无法计算相似度。',[]),
 ('breakpoint_condition','zh','tech','给断点加一个条件，只在计数器变成零时停住。',[]),
 ('screen_reader','zh','tech','图片缺少替代文字，屏幕阅读器无法说明内容。',[]),
 ('file_encoding','zh','tech','这个文本文件的编码不一致，导致标点显示异常。',[]),
 ('scarf_location','zh','general','紫色围巾挂在卧室右边的衣柜里。',[]),
 ('leaking_tap','zh','general','厨房的水龙头关紧以后，还是有点漏水。',[]),
 ('comfortable_shoes','zh','general','这双运动鞋穿起来很舒服，走远路也不累。',[]),
 ('hiking_photos','zh','general','周末去山里散步的时候，我拍了几张照片。',[]),
 ('plant_sunlight','zh','general','阳台上的绿植需要挪到有阳光的位置。',[]),
 ('ironing_shirt','zh','general','请把洗好的衬衫熨平，再挂起来。',[]),
 ('renovation_noise','zh','general','隔壁装修的声音太大，今天不适合在家看书。',[]),
 ('after_swimming','zh','general','游泳结束后记得冲澡，并且擦干头发。',[]),
 ('cooking_preference','zh','general','我更喜欢清蒸的鱼，不太喜欢油炸的食物。',[]),
 ('missing_keys','zh','general','钥匙可能落在书包最里面的口袋了。',[]),
 ('loose_chair','zh','general','这把椅子的螺丝松了，坐下去会晃动。',[]),
 ('concert_crowd','zh','general','演唱会结束以后，广场上的人慢慢散开。',[]),
 ('docker_layers','zh','tech','这个 Docker 镜像的基础层可以重复使用。',['Docker']),
 ('sql_aggregation','zh','tech','这条 SQL 应该先分组，再计算每组的平均值。',['SQL']),
 ('websocket_close','zh','tech','页面关闭的时候，需要断开 WebSocket 连接。',['WebSocket']),
 ('oauth_refresh','zh','tech','OAuth 凭证过期以后，需要刷新登录状态。',['OAuth']),
 ('typescript_union','zh','tech','这里用 TypeScript 联合类型描述不同的状态。',['TypeScript']),
 ('markdown_code','zh','tech','Markdown 代码块需要标明使用的编程语言。',['Markdown']),
 ('sqlite_location','zh','tech','SQLite 数据库文件保存在应用的本地目录里。',['SQLite']),
 ('http_cache','zh','tech','这个 HTTP 响应应该设置明确的缓存策略。',['HTTP']),
 ('embedding_norm','zh','tech','生成 embedding 以后，先检查向量是否归一化。',['embedding']),
 ('unicode_composition','zh','tech','Unicode 字符可能由多个码点组合而成。',['Unicode']),
 ('webgpu_support','zh','tech','先确认浏览器支持 WebGPU，再启用图形加速。',['WebGPU']),
 ('onnx_export','zh','tech','导出 ONNX 文件以后，需要核对输入输出的形状。',['ONNX']),
 ('experiment_seed_en','en','tech','Use a fixed seed when comparing these experiments.',[]),
 ('image_aspect_en','en','tech','The image preview should preserve the original aspect ratio.',[]),
 ('cursor_start_en','en','tech','Move the cursor to the beginning of this paragraph.',[]),
 ('microphone_indicator_en','en','tech','Show the microphone state next to the shortcut.',[]),
]


def build(existing):
    pairs={0,1,2,12,13,14,24,25,26,36}
    takes=[]
    for i,(family,lang,domain,prompt,terms) in enumerate(ROWS):
        for mode in (['silent','voiced'] if i in pairs else ['silent']):
            takes.append(dict(id=f'v3-train-{family}-{mode}',speaker_id=existing['speaker_id'],
                session_id='train-03',split='train',phrase_family=family,language=lang,
                language_profile='zh_en_mixed' if terms else lang,domain=domain,
                target_terms=terms,mode=mode,prompt=prompt))
    old_families={t['phrase_family'] for t in existing['takes']}
    old_prompts={''.join(c for c in t['prompt'].casefold() if c.isalnum()) for t in existing['takes']}
    for t in takes:
        if t['phrase_family'] in old_families:raise ValueError('Existing family reused')
        if ''.join(c for c in t['prompt'].casefold() if c.isalnum()) in old_prompts:raise ValueError('Existing prompt reused')
    validate_plan(dict(takes=existing['takes']+takes))
    assert Counter(t['language_profile'] for t in takes)=={'zh':30,'zh_en_mixed':15,'en':5}
    assert Counter(t['domain'] for t in takes)=={'tech':35,'general':15}
    return dict(status='DRAFT ONLY, NOT ACTIVATED',purpose='Broader natural-silent enrollment; no promise that more data alone fixes accuracy',
        speaker_id=existing['speaker_id'],unique_phrases=40,natural_silent_takes=40,matched_voiced_takes=10,
        language_unit='takes: 90% Chinese dominant, 10% English',tech_share=.7,
        safeguards='Append only after choosing this experiment; preserve all existing footage, validation and test. '
                   'No automated ASR labels or verification flags are created. Existing holdout technical terms are not added as target terms.',takes=takes)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.output.exists():raise ValueError('Choose new output path')
    existing,_=load_clips(a.root);draft=build(existing);write_json(a.output,draft)
    print('Draft saved:',len(draft['takes']),'takes,',draft['unique_phrases'],'unique phrases; active plan unchanged')


if __name__=='__main__':main()
