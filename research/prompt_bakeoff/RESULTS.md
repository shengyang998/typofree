# MLX correction-model bake-off (2026-07-18, dev box M2 Pro 32GB)

**任务**:上文+拼音+engineBest 候选 → 修同音错别字。temp=0,产品触发门 ≥4 字。
**用例**:8 条(家/加、的/得×2、在/再×2、透传、以经/已经、做天/昨天)。
**评分口径**:必须结合 D12 确定性门(re-pinyinize + 长度±1)后的"用户实际所见"。

## 结论矩阵

| 模型 | prompt | 门后净修正 | 格式稳定性 | 稳态延迟(M2 Pro) | 判定 |
|---|---|---|---|---|---|
| **Qwen2.5-1.5B-Instruct-4bit** | **v3 chat-turn few-shot** | **4/7** | 16 代零崩坏 | **600-730ms** | ✅ **质量默认** |
| Qwen2.5-1.5B-Instruct-4bit | v15 inline few-shot | 3/7 | 稳 | 600-850ms | v3 更优 |
| Qwen3-0.6B-4bit (VoxInk 本地拷) | v1 极简 | ~2/7 | 基本稳(会加句号) | 370-540ms | ✅ 低内存备选 |
| Qwen3-0.6B-4bit | v1.5/v2 加强 | 跷跷板 | 复读/删字出现 | ~500ms | ❌ prompt 越重越崩 |
| Qwen3-0.6B-4bit-DWQ | v1 | 更差 | 删字/上文混入 | ~450ms | ❌ |
| Qwen3-1.7B-4bit | v1.5/v3/两段式 | ~1/7 | 稳但**不敢改** | 860-1190ms | ❌ no-think 过保守 |
| Qwen3-1.7B-4bit | thinking=True | (未完成思考) | — | **11.2-11.8s** | ❌ 延迟出局 |

## 关键发现(设计输入)

1. **Prompt 形态定论**:few-shot 用真实 user/assistant 多轮对话(v3),system 规则保持极简;分类清单式规则(v2)诱发小模型复读输入行。
2. **Qwen3 系 no-think 有"规模反转"**:0.6B 乱改、1.7B 不改;thinking 模式 11s+ 不可用于 IME。Qwen2.5 指令系没有该问题。
3. **门是特性成立的前提**:所有模型都会产生越界改写(改语义词、删字、加标点),re-pinyinize+长度门把它们全变成静默 no-op。门拒绝率是正常运行指标,不是错误。
4. **回填前先 strip 尾部新增标点**(0.6B/2.5 都会补句号,属可救回的修正)。
5. 残余失误模式:同音修正夹带同义改写(非常→很),门会整句拒掉——future: prompt 加"其余字逐字照抄"few-shot 或对 diff 做逐字段落回收。

## 本地模型资产(避免重复下载)

- Qwen3-0.6B-4bit **完整** 335MB ×2:`labs/VoxInk/build/VoxInk-1.0.0-26.xcarchive/Products/OnDemandResources/*qwen*/Qwen3-0.6B-4bit{,-DWQ}`
- `~/.cache/huggingface/hub`:Qwen3-1.7B-4bit(938MB)、Qwen2.5-1.5B-Instruct-4bit(~940MB)已下全
- `~/Documents/huggingface`(mlx-swift HubApi 默认缓存):全是空壳 stub,无权重
- 复现:`uv run --python 3.12 --with mlx-lm python typofree_prompt_test_v3.py <model-id-or-path>`
