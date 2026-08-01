/**
 * 语音识别中文数字智能归一化。
 *
 * 核心哲学：只有明确是计数场景才转，拿不准就保留中文。
 * 因为转错了（成语变数字）比不转更糟。
 */

// 量词 / 单位词——数字紧贴这些字时，判定为计数场景，触发转换。
// 覆盖：货币、度量衡、时间、频次、集体量词等常见口语单位。
const UNIT_CHARS =
  "元角分块毛钱|个位只条件双对副组批类种类样份册篇章节段落首曲部本则场次数趟程步圈局回合遍层级阶期季年月日号礼拜周天秒刻时岁夜晚阵倍克吨升度瓦赫兆焦卡路里倍份项款轮封封";
// 用集合做 O(1) 查询。
const UNIT_SET = new Set(UNIT_CHARS.replace(/\|/g, "").split(""));

// 多字量词——「公斤/公里/厘米」等，单位判断时按前缀匹配。
const MULTI_CHAR_UNITS = [
  "公斤", "公里", "厘米", "毫米", "分米", "千克", "兆赫", "赫兹",
  "加仑", "英镑", "盎司", "英寸", "英尺", "华氏", "摄氏", "千瓦",
  "兆瓦", "毫升", "公升", "平方", "立方", "周岁", "虚岁",
];

// 连续中文数字（含大写、两、十百千万亿、〇）。长度 ≥ 1。
const NUMERAL_CHARS = "零〇一二三四五六七八九两十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟万亿两";
const NUMERAL_PATTERN = new RegExp(`[${escapeCharClass(NUMERAL_CHARS)}]+`, "g");

// 时间单位后缀——「年/月/日/号/点/分/秒」单独成一类，因为常见于日期时刻。
const TIME_SUFFIX_PATTERN = /[年月日号点分秒]$/;

// 概数表达——「三五」「两三」「七八」这类相邻小数字并列，表约数，保留中文。
const APPROX_PATTERN = /^[两一二三四五六七八九][一二三四五六七八九]$/;

// 单字「两」单独出现（如「两个」「两百」）需要转，但「两」本身也是 numeral 的一部分，
// 由主流程统一处理。

// 含数字的常见成语 / 固定表达。这些即便数字紧贴量词，也要保留中文。
// 用占位符保护：转换前替换掉，转换后还原。
const IDIOMS = [
  "一五一十", "一尘不染", "一目了然", "一如既往", "一诺千金", "一鸣惊人", "一枕黄粱",
  "一掷千金", "一泻千里", "一诺千金", "一了百了", "一言九鼎", "一毛不拔", "一臂之力",
  "一筹莫展", "一帆风顺", "一蹴而就", "一视同仁", "一往无前", "一意孤行", "一针见血",
  "一日千里", "一日三秋", "一叶知秋", "一叶障目", "一曝十寒", "一琴一鹤",
  "两全其美", "两面三刀", "两小无猜", "两袖清风", "三心二意", "三头六臂", "三言两语",
  "三番五次", "三令五申", "三教九流", "三长两短", "三从四德", "四面八方", "四分五裂",
  "四海为家", "五湖四海", "五花八门", "五颜六色", "五光十色", "六神无主", "六根清净",
  "七上八下", "七嘴八舌", "七手八脚", "七零八落", "七拼八凑", "七上八下", "七折八扣",
  "八面玲珑", "八仙过海", "九牛一毛", "九死一生", "九霄云外", "十全十美", "十拿九稳",
  "十室九空", "十指连心", "百发百中", "百折不挠", "百感交集", "百闻不如一见",
  "千方百计", "千军万马", "千篇一律", "千载难逢", "千钧一发", "千言万语", "千变万化",
  "万众一心", "万无一失", "万水千山", "万紫千红", "万众瞩目", "亿万家产",
  "说三道四", "朝三暮四", "颠三倒四", "推三阻四", "丢三落四", "接二连三",
  "不三不四", "低三下四", "三三两两", "三三两两",
  "百里挑一", "杀一儆百", "以一当十", "举一反三", "独一无二", "略知一二", "数一数二",
];

/**
 * 把一段中文数字串解析成数值。支持位值制（十百千万亿）。
 * 解析失败返回 null（交由主流程保留原文）。
 *
 * 示例：
 *   "二十"     -> 20
 *   "三百二十五" -> 325
 *   "两千零一"  -> 2001
 *   "三亿五千万" -> 350000000
 */
// 字符 → 数值映射。
const DIGIT_MAP = {
  零: 0, 〇: 0, 一: 1, 壹: 1, 二: 2, 贰: 2, 三: 3, 叁: 3, 四: 4, 肆: 4,
  五: 5, 伍: 5, 六: 6, 陆: 6, 七: 7, 柒: 7, 八: 8, 捌: 8, 九: 9, 玖: 9,
  两: 2,
};
// 小单位 → 权重。
const SMALL_UNIT_MAP = { 十: 10, 拾: 10, 百: 100, 佰: 100, 千: 1000, 仟: 1000 };
// 大单位 → 权重。
const BIG_UNIT_MAP = { 万: 10000, 亿: 100000000 };
const SMALL_UNIT_RE = /[十拾百佰千仟]/;
const BIG_UNIT_RE = /[万亿]/;

function parseChineseNumber(segment) {
  if (!segment) return null;

  // 分支 A：逐位读法。整段都是纯数字字符（零~九、〇、两），没有十百千万亿单位。
  // 典型于年份（二零二六）、日期（三月五号里的「五」不在此列，这里指多字）、
  // 编号、电话。逐字拼接，不做位值制。
  if (!SMALL_UNIT_RE.test(segment) && !BIG_UNIT_RE.test(segment)) {
    if (segment.length < 2) {
      // 单字数字（如「五」）交给分支 B 统一处理，这里只管多位逐位读。
    } else {
      let digits = "";
      for (const ch of segment) {
        if (ch in DIGIT_MAP) digits += DIGIT_MAP[ch];
        else return null;
      }
      const value = Number.parseInt(digits, 10);
      return value > 0 || digits === "0" ? value : null;
    }
  }

  // 分支 B：位值制（含十百千万亿）。
  let total = 0;        // 全局累计（含万/亿分段）
  let section = 0;      // 当前段内累计（千百十个）
  let current = null;   // 当前遇到的数字（非单位）

  for (const ch of segment) {
    if (ch in DIGIT_MAP) {
      current = DIGIT_MAP[ch];
    } else if (ch in SMALL_UNIT_MAP) {
      // 「十」做开头时省略「一」，如「十五」= 15、「十二」= 12。
      const unit = SMALL_UNIT_MAP[ch];
      if (current === null) {
        section += unit; // 省略的「一」
      } else {
        section += current * unit;
        current = null;
      }
    } else if (ch in BIG_UNIT_MAP) {
      // 万 / 亿：把当前段 + 残留 current 并入 section，再乘以大单位。
      if (current !== null) {
        section += current;
        current = null;
      }
      total += section * BIG_UNIT_MAP[ch];
      section = 0;
    } else {
      return null; // 遇到无法识别的字符，放弃转换。
    }
  }

  // 收尾：残留的 current 和 section 并入。
  if (current !== null) section += current;
  total += section;

  return total > 0 ? total : null;
}

// 金额 / 计数语境词——数字出现在这些词之后、且本身无单位时，
// 判定为金额/数量（口语常见：「停车费二十」「一共五十」「花了二十」「给了五十」）。
// 允许中间隔一个「了」字（花了二十、给了五十）。
const AMOUNT_CONTEXT_PATTERN = /[费花付收赚销账块元角分斤吨岁百千万余共达满约给借欠退补剩找凑凑押](了)?$/;

/**
 * 判断一个中文数字片段是否「应该」转换成阿拉伯数字。
 * 基于「白名单触发」：只有明确是计数场景才转。
 *
 * @param {string} segment  中文数字片段，如 "二十"
 * @param {string} before   片段前的一个字符
 * @param {string} beforeTail 片段前的字符序列（用于判断金额语境）
 * @param {string} afterTail 片段后的剩余字符串（至少看前 3 个字符，够匹配多字量词）
 * @returns {boolean}
 */
function shouldConvert(segment, before, beforeTail, afterTail) {
  // 概数（三五、两三、七八）保留中文。
  if (APPROX_PATTERN.test(segment)) return false;

  // 触发条件 1：后面紧跟量词 / 单位（二十元、三次、五个）。
  if (afterTail && UNIT_SET.has(afterTail[0])) return true;

  // 触发条件 1b：后面紧跟多字量词（七十公斤、三公里、五厘米）。
  if (afterTail && MULTI_CHAR_UNITS.some((u) => afterTail.startsWith(u))) return true;

  // 触发条件 2：前面是「第」（第三天、第N次）。
  if (before === "第") return true;

  // 触发条件 3：后面紧跟时间单位（二零二六年、三月、八点）。
  if (TIME_SUFFIX_PATTERN.test(afterTail?.[0] || "")) return true;

  // 触发条件 4：片段本身含大单位「万/亿」（两百万、三千万）。
  // 这类几乎一定是数值场景（相关成语已被词典保护），即使后无单位也转。
  if (BIG_UNIT_RE.test(segment)) return true;

  // 触发条件 5：数字后面无单位（句末/标点前/空），但前面是金额/计数语境。
  // 覆盖口语常见句式：「停车费二十」「一共五十」「花了二十」。
  if (AMOUNT_CONTEXT_PATTERN.test(beforeTail)) return true;

  return false;
}

/**
 * 主函数：把语音识别文本里的中文数字，按场景智能转成阿拉伯数字。
 * 计数场景转换，成语 / 概数保留中文。
 *
 * @param {string} text  ASR 原文
 * @returns {string}     归一化后的文本
 */
export function normalizeChineseNumbers(text) {
  const input = String(text ?? "");
  if (!input) return input;

  // 第一步：用占位符保护成语，避免里面的数字被误转。
  // 占位符用 Unicode 私用区字符，不会和正文冲突。
  const placeholders = [];
  let masked = input;
  for (const idiom of IDIOMS) {
    if (masked.includes(idiom)) {
      const ph = `\uE000${placeholders.length}\uE001`;
      placeholders.push(idiom);
      masked = masked.split(idiom).join(ph);
    }
  }

  // 第二步：逐段扫描中文数字，按白名单规则决定转不转。
  masked = masked.replace(NUMERAL_PATTERN, (segment, offset) => {
    const before = offset > 0 ? masked[offset - 1] : "";
    const beforeTail = masked.slice(Math.max(0, offset - 8), offset);
    const afterTail = masked.slice(offset + segment.length, offset + segment.length + 3);

    if (!shouldConvert(segment, before, beforeTail, afterTail)) return segment;

    const value = parseChineseNumber(segment);
    if (value === null) return segment;

    return String(value);
  });

  // 第三步：还原成语占位符。
  if (placeholders.length > 0) {
    masked = masked.replace(/\uE000(\d+)\uE001/g, (_, idx) => placeholders[Number(idx)] ?? "");
  }

  return masked;
}

// —— 内部工具 —— //

/** 转义正则字符类里的特殊字符。 */
function escapeCharClass(str) {
  return str.replace(/[-\]\\^]/g, "\\$&");
}
