# 意图识别评测报告：seed-v1 (baseline)

- 时间：2026-08-15T12:40:43.724Z
- 环境：http://localhost:8787
- 语料：/Users/tangyuxuan/Desktop/Claude/HOLO/docs/holoai-audit/intent-eval/corpus/seed-v1.json（123 条）
- **总体准确率：30.1%（37/123）**

## 按期望意图分布

| 期望意图 | 通过/总数 | 准确率 |
|---|---|---|
| check_in | 0/6 | 0% |
| complete_task | 4/5 | 80% |
| create_note | 0/5 | 0% |
| create_task | 9/10 | 90% |
| delete_task | 4/4 | 100% |
| flexible_data_query | 0/8 | 0% |
| generate_memory_insight | 0/4 | 0% |
| link_task_to_goal | 0/4 | 0% |
| modify_task_items | 0/5 | 0% |
| query | 0/8 | 0% |
| query_analysis | 0/10 | 0% |
| query_habits | 0/4 | 0% |
| query_tasks | 0/6 | 0% |
| record_expense | 10/10 | 100% |
| record_income | 5/5 | 100% |
| record_mood | 0/5 | 0% |
| record_weight | 0/4 | 0% |
| toggle_goal_visibility | 0/4 | 0% |
| unknown | 0/5 | 0% |
| update_goal_field | 0/5 | 0% |
| update_task | 5/6 | 83% |

## 失败样本（86）

| id | 输入 | 期望 | 实际 | mode | 澄清 | 备注 |
|---|---|---|---|---|---|---|
| ct04 | 完成了今天的读书任务 | complete_task | check_in | single_action | 否 |  |
| mt01 | （最近任务：去山姆购物）还要买可乐 | modify_task_items | error | error | 否 |  |
| mt02 | （最近任务：去山姆购物）牛奶不买了，换成酸奶 | modify_task_items | error | error | 否 |  |
| mt03 | （最近任务：去山姆购物）再加一提纸巾 | modify_task_items | error | error | 否 |  |
| mt04 | （最近任务：旅行准备）防晒霜不带了 | modify_task_items | error | error | 否 |  |
| mt05 | （最近任务：去山姆购物）再加巧克力和薯片 | modify_task_items | error | error | 否 |  |
| h01 | 打卡读书 | check_in | error | error | 否 |  |
| h02 | 今天的跑步打卡了 | check_in | error | error | 否 |  |
| h03 | 喝水打卡 | check_in | error | error | 否 |  |
| h04 | 背单词打卡一次 | check_in | error | error | 否 |  |
| h05 | 今天没抽烟，打卡 | check_in | error | error | 否 |  |
| h06 | 冥想打卡 | check_in | error | error | 否 |  |
| g01 | 把减肥目标的截止日期改到年底 | update_goal_field | error | error | 否 |  |
| g02 | 读书目标的说明改一下：每天读20页 | update_goal_field | error | error | 否 |  |
| g03 | 把存钱目标改成存三万 | update_goal_field | error | error | 否 |  |
| g04 | 跑步目标的动机改成夏天能穿短袖 | update_goal_field | error | error | 否 |  |
| g05 | 把学英语这个目标的标题改成备考雅思 | update_goal_field | error | error | 否 |  |
| lg01 | 把每天背单词这个任务关联到学英语目标 | link_task_to_goal | error | error | 否 |  |
| lg02 | 这个跑步任务算到减肥目标里 | link_task_to_goal | error | error | 否 |  |
| lg03 | 把晨跑提醒挂到健身目标下 | link_task_to_goal | error | error | 否 |  |
| lg04 | 读书任务关联阅读计划目标 | link_task_to_goal | error | error | 否 |  |
| gv01 | 把减肥目标对AI隐藏 | toggle_goal_visibility | error | error | 否 |  |
| gv02 | 学英语目标恢复AI可见 | toggle_goal_visibility | error | error | 否 |  |
| gv03 | 隐藏存钱目标 | toggle_goal_visibility | error | error | 否 |  |
| gv04 | 让跑步目标AI不可见 | toggle_goal_visibility | error | error | 否 |  |
| n01 | 记个想法：以后周末试试早起爬山 | create_note | error | error | 否 |  |
| n02 | 记笔记：这本书第三章讲复利 | create_note | error | error | 否 |  |
| n03 | 灵感：把阳台改成小花园 | create_note | error | error | 否 |  |
| n04 | 记一下：同事推荐了家日料店叫鱼心 | create_note | error | error | 否 |  |
| n05 | 随便记记：今天天空特别好看 | create_note | error | error | 否 |  |
| m01 | 今天心情不错 | record_mood | error | error | 否 |  |
| m02 | 有点烦 | record_mood | error | error | 否 |  |
| m03 | 心情很好，项目过审了 | record_mood | error | error | 否 |  |
| m04 | 今天emo了 | record_mood | error | error | 否 |  |
| m05 | 开心！抢到演唱会门票 | record_mood | error | error | 否 |  |
| w01 | 体重72.5 | record_weight | error | error | 否 |  |
| w02 | 今天称了体重73公斤 | record_weight | error | error | 否 |  |
| w03 | 记体重70.8kg | record_weight | error | error | 否 |  |
| w04 | 早上体重71.2 | record_weight | error | error | 否 |  |
| qt01 | 我今天有哪些任务 | query_tasks | error | error | 否 |  |
| qt02 | 看看本周的待办 | query_tasks | error | error | 否 |  |
| qt03 | 还有什么没完成的任务 | query_tasks | error | error | 否 |  |
| qt04 | 查一下我明天要做什么 | query_tasks | error | error | 否 |  |
| qt05 | 任务列表里有多少逾期的 | query_tasks | error | error | 否 |  |
| qh01 | 我这周打卡情况怎么样 | query_habits | error | error | 否 |  |
| qh02 | 看看最近的打卡记录 | query_habits | error | error | 否 |  |
| qh03 | 跑步习惯坚持得怎么样 | query_habits | error | error | 否 |  |
| qh04 | 查一下喝水打卡的次数 | query_habits | error | error | 否 |  |
| fq01 | 本月花了多少钱 | flexible_data_query | error | error | 否 |  |
| fq02 | 今年收入是多少 | flexible_data_query | error | error | 否 |  |
| fq03 | 今年买烟花花了多少钱 | flexible_data_query | error | error | 否 |  |
| fq04 | 咖啡一共花了多少 | flexible_data_query | error | error | 否 |  |
| fq05 | 最近一笔外卖多少钱 | flexible_data_query | error | error | 否 |  |
| fq06 | 超过100元的消费有几笔 | flexible_data_query | error | error | 否 |  |
| fq07 | 最大的一笔支出是多少 | flexible_data_query | error | error | 否 |  |
| qa01 | 帮我分析最近花销 | query_analysis | error | error | 否 |  |
| qa02 | 分析今年收入结构 | query_analysis | error | error | 否 |  |
| qa03 | 复盘本月消费 | query_analysis | error | error | 否 |  |
| qa04 | 最近一个月餐饮占比怎么样 | query_analysis | error | error | 否 |  |
| qa05 | 平均一天抽烟花多少钱 | query_analysis | error | error | 否 |  |
| qa06 | 最近睡眠怎么样 | query_analysis | error | error | 否 |  |
| qa07 | 这周步数趋势 | query_analysis | error | error | 否 |  |
| q01 | 你叫什么名字 | query | error | error | 否 |  |
| q02 | 你能帮我做什么 | query | error | error | 否 |  |
| q03 | 谢谢啦 | query/unknown | error | error | 否 |  |
| q04 | 记一笔是什么意思 | query | error | error | 否 |  |
| q05 |  Apple Pay 绑定银行卡在哪里设置 | query | error | error | 否 |  |
| mi01 | 给我生成一个记忆洞察 | generate_memory_insight | error | error | 否 |  |
| mi02 | 帮我回放一下最近的记忆 | generate_memory_insight | error | error | 否 |  |
| mi03 | 总结下我最近的生活轨迹 | generate_memory_insight/query_analysis | error | error | 否 |  |
| mi04 | 最近有什么值得记住的事 | generate_memory_insight/query | error | error | 否 |  |
| u01 | 哈哈哈 | unknown | error | error | 否 |  |
| u02 | 嗯嗯 | unknown | error | error | 否 |  |
| u03 | asdfgh | unknown | error | error | 否 |  |
| u04 | 🎉🎉 | unknown | error | error | 否 |  |
| u05 | 。。。 | unknown | error | error | 否 |  |
| a01 | 妈妈生日是哪天 | query/flexible_data_query | error | error | 否 | 上下文依赖：真实链路带纪念日清单时必为 query；最小上下文下可能判 flexible_data_query |
| a02 | 距离妈妈生日还有多久 | query/flexible_data_query | error | error | 否 | 同上 |
| a03 | 我最近状态怎么样 | query_analysis | error | error | 否 | intentResponseStabilizer 规则旁路命中（provider=holo-rules）也返回 query_analysis |
| a04 | 最近怎么样 | query_analysis/query | error | error | 否 |  |
| a05 | 今天天气怎么样 | query/unknown | error | error | 否 | 外部信息，产品预期是不执行本地动作 |
| a06 | 查一下任务和习惯 | query_tasks/query_habits | error | error | 否 | 多查询，items 顺序不固定 |
| a07 | 提醒我明天买牛奶，对了今天午饭花了30 | create_task/record_expense | error | error | 否 | 查询+执行混合应 clarification，intent 任一可接受 |
| a08 | 把会议改到周三下午3点 | update_task | error | error | 否 |  |
| a09 | 最近状态不好，看看睡眠咋样 | query_analysis | error | error | 否 |  |
| a10 | 这个月喝了多少次咖啡 | flexible_data_query/query_analysis | error | error | 否 | 次数单值与频率统计的边界，prompt 定义倾向 flexible_data_query |
