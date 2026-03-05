/**
 * 我的 - 用户中心视图
 */
export default function ProfileView() {
  const goals = [
    { label: '储蓄率达 20%', pct: 65, color: '#FF6B35' },
    { label: '每周运动 4 次', pct: 80, color: '#FF6B35' },
    { label: '完成 HOLO MVP', pct: 40, color: '#FF9A5C' },
    { label: '阅读 2 本书', pct: 50, color: '#FFB680' },
  ]

  return (
    <div className="flex-1 ios-scroll" style={{ background: '#f7f7f7' }}>
      <div className="px-5 pt-4 pb-3">
        <h1 style={{ fontSize: 28, fontWeight: 700, color: '#111', letterSpacing: -0.5 }}>我的</h1>
      </div>

      <div className="px-4 pb-6 space-y-3">
        {/* 用户卡片 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <div className="flex items-center gap-3">
            <div
              className="w-14 h-14 rounded-full flex items-center justify-center text-2xl font-bold text-white"
              style={{ background: 'linear-gradient(135deg, #FF6B35, #FF9A5C)' }}
            >
              Y
            </div>
            <div className="flex-1">
              <p style={{ fontSize: 18, fontWeight: 700, color: '#111' }}>Yuxuan</p>
              <p style={{ fontSize: 13, color: '#999' }}>使用 HOLO 第 62 天</p>
            </div>
            <button style={{ fontSize: 13, color: '#FF6B35', fontWeight: 500 }}>编辑</button>
          </div>
          <div className="flex gap-4 mt-4 pt-4" style={{ borderTop: '0.5px solid #f0f0f0' }}>
            {[
              { label: '记录天数', value: '62' },
              { label: '想法条目', value: '38' },
              { label: '习惯坚持', value: '74%' },
            ].map((s) => (
              <div key={s.label} className="flex-1 text-center">
                <p style={{ fontSize: 20, fontWeight: 700, color: '#111' }}>{s.value}</p>
                <p style={{ fontSize: 11, color: '#999', marginTop: 1 }}>{s.label}</p>
              </div>
            ))}
          </div>
        </div>

        {/* 本月目标 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111', marginBottom: 12 }}>本月目标</h2>
          <div className="space-y-4">
            {goals.map((g) => (
              <div key={g.label}>
                <div className="flex items-center justify-between mb-1.5">
                  <span style={{ fontSize: 14, color: '#333' }}>{g.label}</span>
                  <span style={{ fontSize: 14, fontWeight: 600, color: g.color }}>{g.pct}%</span>
                </div>
                <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#f0f0f0' }}>
                  <div
                    className="h-full rounded-full"
                    style={{ width: `${g.pct}%`, background: g.color }}
                  />
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* AI 洞察 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111', marginBottom: 12 }}>HOLO 月报</h2>
          <div className="space-y-3">
            {[
              { icon: '📈', title: '财务向好', desc: '储蓄率从 8% 升至 15%，按趋势 6 个月可达 20%。' },
              { icon: '⚡', title: '效率模式', desc: '上午 9-11 点是你的黄金工作时段，本周保护了 3 天。' },
              { icon: '💡', title: '模式识别', desc: '情绪低落时消费增加 38%，建议设置情绪触发预警。' },
            ].map((item) => (
              <div key={item.title} className="flex items-start gap-3">
                <div
                  className="w-9 h-9 rounded-2xl flex items-center justify-center flex-shrink-0 text-lg"
                  style={{ background: '#FFF5F0' }}
                >
                  {item.icon}
                </div>
                <div>
                  <p style={{ fontSize: 14, fontWeight: 600, color: '#111' }}>{item.title}</p>
                  <p style={{ fontSize: 13, color: '#666', lineHeight: 1.4, marginTop: 2 }}>{item.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* 设置入口 */}
        <div className="rounded-3xl overflow-hidden card-shadow" style={{ background: '#fff' }}>
          {[
            { label: '数据同步', icon: '🔄' },
            { label: '通知设置', icon: '🔔' },
            { label: '隐私与安全', icon: '🔒' },
            { label: '关于 HOLO', icon: 'ℹ️' },
          ].map((item, i) => (
            <div
              key={item.label}
              className="flex items-center gap-3 px-4 py-3.5"
              style={{ borderTop: i > 0 ? '0.5px solid #f0f0f0' : 'none' }}
            >
              <span style={{ fontSize: 18 }}>{item.icon}</span>
              <span className="flex-1" style={{ fontSize: 15, color: '#111' }}>{item.label}</span>
              <svg width="8" height="13" viewBox="0 0 8 13" fill="none">
                <path d="M1.5 1.5L7 6.5L1.5 11.5" stroke="#ccc" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
