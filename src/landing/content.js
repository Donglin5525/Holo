export const navItems = [
  { label: 'HoloAI', href: '#holoai' },
  { label: '五大模块', href: '#modules' },
  { label: '记忆长廊', href: '#memory-gallery' },
  { label: '记忆陪伴', href: '#memory-companion' },
  { label: '隐私与支持', href: '/privacy' },
]

export const productModules = [
  {
    title: '记账',
    eyebrow: 'Finance',
    description: '记录消费、收入、预算和分类趋势，让日常收支不再只是流水。',
    aiSignal: 'HoloAI 会把金额、时间、类别和预算变化转化为可解释的财务信号。',
    metric: '本月支出 -12%',
    color: '#F46D38',
  },
  {
    title: '待办',
    eyebrow: 'Tasks',
    description: '管理任务、提醒、子任务和行动计划，把模糊目标拆成今天能做的事。',
    aiSignal: 'HoloAI 会识别任务优先级、截止时间和跨模块关联，生成下一步建议。',
    metric: '今日 2 项待完成',
    color: '#60A5FA',
  },
  {
    title: '习惯',
    eyebrow: 'Habits',
    description: '追踪打卡、连续天数、好习惯和坏习惯，把改变沉淀成长期模式。',
    aiSignal: 'HoloAI 会读取完成率、连续记录和波动，发现影响状态的行为节奏。',
    metric: '连续 22 天',
    color: '#22C55E',
  },
  {
    title: '想法',
    eyebrow: 'Thoughts',
    description: '收集灵感、反思、心情和引用关系，让碎片想法逐渐形成主题。',
    aiSignal: 'HoloAI 会把想法标签、引用和情绪线索连接成可回看的个人知识脉络。',
    metric: '38 条想法',
    color: '#C084FC',
  },
  {
    title: '健康',
    eyebrow: 'Health',
    description: '整合睡眠、步数、体重和运动状态，帮助你看懂身体给出的信号。',
    aiSignal: 'HoloAI 会在授权后结合 HealthKit 数据，生成健康状态摘要和温和提醒。',
    metric: '睡眠 7.2h',
    color: '#14B8A6',
  },
]

export const coreSections = [
  {
    id: 'holoai',
    title: 'HoloAI',
    label: '个人上下文中枢',
    description: 'HoloAI 读取五大模块形成的个人上下文，把自然语言记录、结构化数据和长期模式合并成今日简报、跨模块洞察和下一步建议。',
    bullets: ['自然语言记录', '结构化解析', '跨模块分析', '今日简报'],
  },
  {
    id: 'memory-gallery',
    title: '记忆长廊',
    label: '把生活沉淀为时间线',
    description: '记忆长廊把记账、习惯、待办、想法和健康状态沉淀为时间线、AI 回放、明细和洞察卡片，让长期变化有迹可循。',
    bullets: ['AI 回放', '时间线', '洞察卡片', '长期模式'],
  },
  {
    id: 'memory-companion',
    title: '记忆陪伴',
    label: '温和而克制的长期陪伴',
    description: '记忆陪伴不是替你做决定，而是在你需要复盘、提醒和看清模式时，基于历史记录给出陪伴式提问和可执行建议。',
    bullets: ['复盘提问', '状态提醒', '模式理解', '行动建议'],
  },
]

export const legalLinks = [
  {
    title: '隐私政策',
    description: '说明 Holo 收集的数据类型、用途、AI 处理方式、保留期限和删除方式。',
    href: '/privacy',
  },
  {
    title: '用户支持',
    description: '提供问题反馈、联系邮箱、常见问题和 App Store Support URL 承接入口。',
    href: '/support',
  },
  {
    title: '账号与数据删除',
    description: '说明账号删除、个人数据删除、数据导出和撤回授权的路径。',
    href: '/account-deletion',
  },
  {
    title: '数据导出',
    description: '说明 CSV、JSON 导出的入口、范围与敏感文件保管方式。',
    href: '/data-export',
  },
  { title: '用户协议', description: '说明服务边界、用户责任、AI 输出限制与终止方式。', href: '/terms' },
]
