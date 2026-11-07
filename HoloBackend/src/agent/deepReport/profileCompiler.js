// 深度报告 C 方案 · 修复 1（2026-11-07 东林拍板「细致地修，多模拟用户写法」）：
// 档案指令化编译器——把用户亲手写的个人档案（任意写法：一句话/模板字段/清单/表格/
// 英文/口语）用一次轻量模型调用转写成「逐条自包含的执行指令」。这是框架层修复，
// 不检测任何具体类别（称呼/作息/禁忌……都由模型通用转写，写法枚举不完也不枚举）：
// - writer 拿到指令清单，照办（对 qwen，明确的指令清单远比「档案原文」执行力强）；
// - checker 拿到指令清单逐条审计（v4 用原文审计 0 次触发的根因即输入形态）。
// 转写失败/超时/非数组时回退为「原文单条」，行为退化为修复前，不阻塞任务。

export class ProfileCompiler {
  /** @param {(messages, opts) => Promise<string>} callModel 轻量模型调用（JSON 输出） */
  constructor(callModel, { route, log = () => {} } = {}) {
    this.callModel = callModel;
    this.route = route;
    this.log = log;
  }

  static SYSTEM = `你把用户亲手写的个人档案转写成逐条执行指令，供一位 AI 助手照办。规则：
1. 档案可能是一句话、一份模板、一个清单、字段罗列、表格线、英文或口语，一律逐条转写。
2. 每条指令自包含、以动词开头、明确可执行；写成资料的（某行填了什么）也转成执行指令。
3. 忠实转写：不添加档案里没有的要求，不删减任何一条，不改变要求的程度（比如「尽量」不得改成「必须」）。
4. 语气类要求（比如怎么说话、多直接）转成对语气的指令；语言类保持原语言。
5. 只输出 JSON：{"directives":["指令1","指令2",...]}，指令语言跟随档案语言。`;

  async compile(profileBrief) {
    const raw = typeof profileBrief === "string" ? profileBrief.trim() : "";
    if (!raw) return { directives: [], source: "empty" };
    try {
      const text = await this.callModel(
        [
          { role: "system", content: ProfileCompiler.SYSTEM },
          { role: "user", content: `【个人档案原文】\n${raw}` },
        ],
        { purpose: "cloud_deep_report_profile", route: this.route, responseFormat: { type: "json_object" } },
      );
      const parsed = JSON.parse(String(text).replace(/^```json\s*|\s*```$/g, ""));
      const directives = (Array.isArray(parsed?.directives) ? parsed.directives : [])
        .map((d) => String(d ?? "").trim())
        .filter(Boolean)
        .slice(0, 30);
      if (!directives.length) throw new Error("EMPTY_DIRECTIVES");
      return { directives, source: "compiled" };
    } catch (error) {
      this.log(`档案指令化失败，回退原文单条: ${error?.message ?? error}`);
      return { directives: [raw], source: "fallback" };
    }
  }

  /** writer 用的档案块（指令为主，原文附后防转写失真） */
  static writerBlock({ directives, source }, rawBrief) {
    const lines = directives.map((d, i) => `${i + 1}. ${d}`).join("\n");
    const original = source === "compiled" && typeof rawBrief === "string" && rawBrief.trim()
      ? `\n【档案原文（与上面指令一致，以指令为准）】\n${rawBrief.trim()}`
      : "";
    return `【这位用户的个人档案，ta 亲手写的，已整理成逐条指令——全部照办】\n${lines}\n（执行底线：指令中要求使用某个特定称呼或词语的，报告全文至少要自然出现该词一次。）${original}`;
  }

  /** checker 用的档案块（只给指令清单，逐条审计最有效） */
  static checkerBlock({ directives }) {
    if (!directives.length) return "";
    return `【用户档案指令清单（报告应当逐条照办；未照办的列为问题，写明指令原文与报告现状）】\n${directives.map((d, i) => `${i + 1}. ${d}`).join("\n")}\n\n`;
  }
}
