"""scripts/screen_text.py's merge (no model): the draft (BlurtCore ScreenText) keeps its lines and layout, the OCR
model's characters fix what Vision misread inside a line — and nothing the model invents gets through."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "blurt" / "scripts"))
import screen_text as st  # noqa: E402

FIX = ROOT / "tests" / "fixtures" / "screen_text"


def test_fixes_inside_a_line():
    d = "我把结论整理成一份 Markdown 发给你了，路径是 Lprivate/tmp/claude-501/-Users-john"
    m = "我把结论整理成一份 Markdown 发给你了，路径是 /private/tmp/claude-501/-Users-john"
    assert st.merge(d, m) == (m, 1)


def test_code_symbols_and_indentation():
    d = "def f(x: int = @) -> Listldict]:\n   return Ir for r in x]  #_init_"
    m = "def f(x: int = 0) -> list[dict]:\n    return [r for r in x]  # __init__"
    assert st.merge(d, m)[0] == m


def test_a_line_the_draft_left_out_stays_out():
    # the half line the edge cut: Vision's draft dropped it, the model writes it out
    d = "/telemetry，不要落 Nginx 日志。\n4. 建议路线：先读表。"
    m = "3. 网关抽取来实现：网路日志的记录\n/telemetry，不要落 Nginx 日志。\n4. 建议路线：先读表。"
    assert st.merge(d, m)[0] == d


def test_ideographs_and_cjk_punctuation_stay_the_drafts():
    d = "2. 建议路线：先读表，确实需要变更历史时再批量解析 binlog。"
    m = "2. 建议路线: 先读取，确实需要变更历史时再批量解析 binlog."
    assert st.merge(d, m)[0] == d


def test_nothing_dropped_markdown_or_latex():
    assert st.merge("- 需要用户自己的 API key", "◦ 需要用户的 API key")[0] == "- 需要用户自己的 API key"
    assert st.merge("1. 生产库现状：主库", "1. **生产库现状**：主库")[0] == "1. 生产库现状：主库"
    assert st.merge("DTS AnalyticDB\t¥860/月", "DTS $\\to$ AnalyticDB\t¥860/月")[0] == "DTS AnalyticDB\t¥860/月"
    assert st.merge("DTS AnalyticDB\t¥860/月", "DTS → AnalyticDB\t¥860/月")[0] == "DTS → AnalyticDB\t¥860/月"


def test_the_drafts_spacing_is_its_layout():
    assert st.merge("方案\t成本\t延迟", "方案 成本 延迟")[0] == "方案\t成本\t延迟"


def test_edge_characters_and_dash_style():
    assert st.merge("产库现", "E产库现状")[0] == "产库现"          # half 生 / 状 at the edges
    assert st.merge("10-14 已经有人建了", "10–14 已经有人建了")[0] == "10-14 已经有人建了"


def test_a_joined_paragraph_against_the_screens_wrapping():
    d = "The replica is billed by the hour. If we keep it, the nightly job (etl_nightly_v2) can move off the primary."
    m = "The replica is billed by the hour. If we\nkeep it, the nightly job (etl_nightly_v2) can move off\nthe primary."
    assert st.merge(d, m)[0] == d                     # every word kept, on the draft's one line


def test_fixture_drafts_merge_no_worse():
    """The committed model readings (fixtures/screen_text/paddle/*.txt, PaddleOCR-VL 1.6) merged into the committed
    drafts: never further from the expectation than the draft, and better overall."""
    cases = [json.loads(l) for l in (FIX / "cases.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    tot_d = tot_m = 0.0
    for c in cases:
        draft = (FIX / "drafts" / f"{c['name']}.txt").read_text(encoding="utf-8")
        model = (FIX / "paddle" / f"{c['name']}.txt").read_text(encoding="utf-8")
        e = st._content(c["expected"])
        ed = st._distance(st._content(draft), e) / len(e)
        em = st._distance(st._content(st.merge(draft, model)[0]), e) / len(e)
        assert em <= ed + 1e-9, (c["name"], ed, em)
        tot_d += ed
        tot_m += em
    assert tot_m < tot_d * 0.5


def test_key_symbols_replace_what_vision_read_them_as():
    # Vision reads ⌥⇧ as letters and ideographs; a model that reads the symbols wins there, but never with ideographs
    assert st.merge("4.T个T 截图翻译：拖选后", "4. ⌥⇧T 截图翻译：拖选后")[0] == "4. ⌥⇧T 截图翻译：拖选后"
    assert st.merge("按214 截图，", "按 ⌘⇧4 截图，")[0] == "按 ⌘⇧4 截图，"
    assert st.merge("4.T个T 截图翻译：拖选后", "4. 了解一下 截图翻译：拖选后")[0] == "4.T个T 截图翻译：拖选后"
