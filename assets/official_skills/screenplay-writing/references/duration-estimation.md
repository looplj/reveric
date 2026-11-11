# 时长估算

用于有目标时长的分集、正文写作与审稿。先按正文估计能演多久，再与目标比较；规划时分配的预算不能直接作为正文已经足够的证据。

## 确认材料与口径

读取本次要估算的完整正文，说明本次估算的版本和范围。只有大纲时给内容预算；只有部分正文时给局部结果与缺口。没有时长要求的局部润色无需额外制作估算报告。

把发声内容、独立动作与二者的重叠关系分开。场景标题、人物名、格式标记与表演说明不是台词；实际会发声的画外音、旁白仍要计入。标点通过停顿体现，不按一个标点等于一个发声字计算；数字、缩写和外文按实际读法处理。无法辨认用途的文本先标为未计入，不能默认为零秒后宣称整集已覆盖。

## 先确定对白与动作的估时依据

优先使用同一版本、相近语言和表演方式的试读或录音。已含句内停顿的整句实测直接使用，不再另加同一停顿；用净发声语速换算时才单列必要停顿。现有样本可校准不同人物或场景，单次测量不代表所有表演方式；制作新的试读或音频仍按用户授权执行。

没有实测时，使用用户或项目声明的语速范围。仍无依据时，可暂以中文每秒 4～5 个可发声字做敏感性估算，并明确这是假设而非通用标准；特殊语气、语言或复杂读法不适用时保留未知项。

若可发声字数为 N，语速范围为 r慢～r快，则净发声区间为：

`对白时长 = [N / r快, N / r慢] + 尚未计入的句内停顿`

动作依据距离、阻力、操作步骤和结果估计连续过程，给出区间及理由。不按动作段数或动词数乘固定秒数；同一行动换行、拆句不应改变估计。“记忆涌入”“仔细检查”等概括尚未展开时，说明缺少的过程，不从目标余额倒填秒数。

## 按先后与重叠计算

将一场戏分成少量连续表演段，写清开口前等待、对白、必要动作、接收反应与结尾停留之间的依赖。

- **顺序发生**：区间相加。例如先开锁、再开门、进屋后才说话。
- **同一时刻开始，全部完成后才继续**：取各项时长的最大值。例如边说话边走近，走到且说完后才递物。区间上下界分别取最大值。
- **错开开始或部分重叠**：按实际起点与结束点排出时间关系，用整段最早开始到最晚结束的跨度计时。没有重叠依据时不随意取最大值，也不重复计算共享时间。

转场、空镜与停顿只计正文或方案实际需要的内容。硬切本身不自动增加固定秒数；声音跨场延续或交叉剪辑时按呈现的时间顺序处理，不直接累加故事中同时发生的所有过程。

有既定镜长时，还要检查对白的可用窗口：扣除开口前等待、不能并行的动作、其他人物轮流发声与收尾反应。整体估时接近目标，不代表每句都能在局部窗口里说完；以较慢端检查拥挤风险，但不把区间上界当成必然耗时。

## 计算示例

以下数字仅演示算法，动作时间是给定假设：

| 过程 | 假设与关系 | 估计 |
|---|---|---|
| 开口前等待 | 独占，不与后续重叠 | 0.8～1.2 秒 |
| 说话并走近 | 36 个可发声字，4～5 字/秒，无额外句内停顿；走近需 3～4 秒，二者同时开始，都完成后才继续 | max(7.2～9, 3～4) = 7.2～9 秒 |
| 对方接收后的反应 | 必须等话说完，独占 | 1～2 秒 |

合计 **9～12.2 秒**。若改为说完才走近，则改算为 **12～16.2 秒**。差别来自行动顺序，不能通过拆段或换行改变总时长。

## Codemode 参考 JS

下面的代码可直接作为 Codemode 的 `code` 内容执行，最后用 `return` 返回对象；不需要模块或外部依赖。示例数字均为假设，替换为已读取正文的实际范围与依据后再报告估算结果。

区间统一用 `[最短秒数, 最长秒数]`。`sequence` 表示顺序完成，`parallel` 表示同时开始且全部完成后才继续；`timeline` 的起点是相对本段开始的确定秒数，至少有一项从 0 开始，初始等待应另列顺序段。起点依赖前一个不确定动作完成时，用 `sequence` 组合，不能拿其中点冒充确定起点。

```js
function range(value) {
  if (!Array.isArray(value) || value.length !== 2 ||
      !value.every(Number.isFinite) || value[0] < 0 || value[1] < value[0]) {
    throw new Error("需要有效区间 [min, max]，满足 0 <= min <= max；未知项不能填 0");
  }
  return value;
}

function sequence(...durations) {
  if (!durations.length) throw new Error("顺序段不能为空");
  return range(durations.map(range).reduce(
    (total, d) => [total[0] + d[0], total[1] + d[1]], [0, 0]
  ));
}

function timeline(...events) {
  if (!events.length) throw new Error("时间段不能为空");
  const ends = events.map(event => {
    const { startSeconds, duration } = event;
    if (!Number.isFinite(startSeconds) || startSeconds < 0) {
      throw new Error("起点须为非负的确定秒数");
    }
    return sequence([startSeconds, startSeconds], range(duration));
  });
  if (!events.some(event => event.startSeconds === 0)) {
    throw new Error("本段至少有一项从 0 开始；初始等待请单独计入");
  }
  return range([
    Math.max(...ends.map(d => d[0])),
    Math.max(...ends.map(d => d[1]))
  ]);
}

function parallel(...durations) {
  return timeline(...durations.map(duration => ({ startSeconds: 0, duration })));
}

function speech(spokenUnits, rate, pauses = [0, 0]) {
  // 先按实际读法统计发声单位；不把标点、人物名、括注计成台词。
  // rate = [慢速, 快速]，单位须与 spokenUnits 一致。
  if (!Number.isInteger(spokenUnits) || spokenUnits < 0) {
    throw new Error("发声单位数须为非负整数");
  }
  const [slow, fast] = range(rate);
  if (slow === 0) throw new Error("语速必须大于 0");
  return sequence([spokenUnits / fast, spokenUnits / slow], pauses);
}

const dialogue = speech(36, [4, 5]); // 示例：36 个发声字，无额外句内停顿
const walking = [3, 4];
const waiting = [0.8, 1.2];
const reaction = [1, 2];
// 四舍五入仅用于最后展示，中间计算保留精度。
const display = d => d.map(n => Math.round(n * 100) / 100);

return {
  basis: "文本估算示例；语速与动作时间均为假设，非实测",
  unit: "seconds",
  parallelScene: display(sequence(waiting, parallel(dialogue, walking), reaction)),
  sequentialScene: display(sequence(waiting, dialogue, walking, reaction)),
  // 假设走近从本段开始，2 秒后开口；本段只算两项全部完成的跨度。
  delayedSpeech: display(timeline(
    { startSeconds: 0, duration: walking },
    { startSeconds: 2, duration: dialogue }
  ))
};
```

示例输出：`parallelScene = [9, 12.2]`，`sequentialScene = [12, 16.2]`，`delayedSpeech = [9.2, 11]`。已有整句实测时直接使用对应秒数区间替代 `speech(...)`，避免重复计入停顿。

这段 JS 只汇总已提供的估时与关系，不解析剧本、判断动作能否并行或补全未知时间。有缺口时停止相关整场／整集汇总，单独列出未估部分；不要用 `[0, 0]` 代替未知项，或将局部结果称为完整时长。

## 汇总与调整

按场次或连续表演段列出“正文范围｜对白与动作｜先后／重叠｜估时依据｜区间”，再按实际呈现顺序汇总。区间表示这些假设下的范围，不是统计置信区间，也不设置统一的通过容差。

单独列出未知或未覆盖部分，分别报告目标、文本估算与媒体实测。委派部分场次时传递原始要求及负责范围，不把整集时长套给每场。需要提高可靠性时，优先校准耗时最长、最不确定的段落。

偏短时展开被概括掉的行动、交锋、选择或后果；偏长时先压缩重复功能，保留决定发生的过程。修改后重新估算，不通过调慢语速、拉长停顿或抬高动作估时凑目标。无法满足时说明差距及需要调整的范围；用户要求增减内容时落实要求，估算只作辅助。
