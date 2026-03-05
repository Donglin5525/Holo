/**
 * 今天 - 首页概览视图（轻量卡片布局）
 */
export default function HomeView() {
  const tasks = [
    { id: 1, text: '产品评审会议准备', done: false, time: '15:00' },
    { id: 2, text: '回复设计反馈邮件', done: false, time: null },
    { id: 3, text: '晨跑 5km', done: true, time: null },
    { id: 4, text: '阅读 30 分钟', done: true, time: null },
  ]

  return (
    <div className="flex-1 ios-scroll" style={{ background: '#f7f7f7' }}>
      {/* Header */}
      <div className="px-5 pt-4 pb-2" style={{ background: '#f7f7f7' }}>
        <p style={{ fontSize: 13, color: '#999', fontWeight: 400 }}>3 月 1 日，星期日</p>
        <h1 style={{ fontSize: 28, fontWeight: 700, color: '#111', letterSpacing: -0.5, marginTop: 2 }}>
          早上好，Yuxuan 👋
        </h1>
      </div>

      <div className="px-4 pb-6 space-y-3 mt-1">
        {/* HOLO 今日简报 */}
        <div
          className="rounded-3xl p-4 card-shadow"
          style={{ background: 'linear-gradient(135deg, #FF6B35 0%, #FF8C5A 100%)' }}
        >
          <div className="flex items-center gap-2 mb-3">
            <div className="w-7 h-7 rounded-full bg-white/20 flex items-center justify-center">
              <span style={{ fontSize: 14 }}>✦</span>
            </div>
            <span style={{ fontSize: 13, fontWeight: 600, color: 'rgba(255,255,255,0.9)' }}>HOLO 简报</span>
          </div>
          <p style={{ fontSize: 15, color: '#fff', lineHeight: 1.55, fontWeight: 400 }}>
            本月支出 <strong>¥3,240</strong>，比上月低 12%。今天有 <strong>2 个任务</strong> 待完成，下午 3 点前需要完成评审准备。
          </p>
          <div className="flex gap-2 mt-3">
            {['财务 ↓12%', '任务 2 个', '睡眠 7.2h'].map((tag) => (
              <span
                key={tag}
                className="px-3 py-1 rounded-full"
                style={{ fontSize: 12, background: 'rgba(255,255,255,0.2)', color: '#fff', fontWeight: 500 }}
              >
                {tag}
              </span>
            ))}
          </div>
        </div>

        {/* 今日任务 */}
        <div className="rounded-3xl card-shadow overflow-hidden" style={{ background: '#fff' }}>
          <div className="flex items-center justify-between px-4 pt-4 pb-3">
            <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111' }}>今日任务</h2>
            <span style={{ fontSize: 13, color: '#FF6B35', fontWeight: 500 }}>+ 添加</span>
          </div>
          <div className="divide-y" style={{ borderColor: '#f0f0f0' }}>
            {tasks.map((task) => (
              <div key={task.id} className="flex items-center gap-3 px-4 py-3">
                <div
                  className="w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center"
                  style={{
                    border: `2px solid ${task.done ? '#FF6B35' : '#ddd'}`,
                    background: task.done ? '#FF6B35' : 'transparent',
                  }}
                >
                  {task.done && (
                    <svg width="10" height="8" viewBox="0 0 10 8" fill="none">
                      <path d="M1 4l3 3 5-6" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  )}
                </div>
                <span className="flex-1" style={{
                  fontSize: 15,
                  color: task.done ? '#bbb' : '#111',
                  textDecoration: task.done ? 'line-through' : 'none',
                }}>
                  {task.text}
                </span>
                {task.time && (
                  <span
                    className="px-2 py-0.5 rounded-full"
                    style={{ fontSize: 11, background: '#FFF1EC', color: '#FF6B35', fontWeight: 500 }}
                  >
                    {task.time}
                  </span>
                )}
              </div>
            ))}
          </div>
        </div>

        {/* 快捷记录 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111', marginBottom: 12 }}>快速记录</h2>
          <div className="grid grid-cols-3 gap-2">
            {[
              { icon: '¥', label: '记账', bg: '#FFF5F0' },
              { icon: '✓', label: '任务', bg: '#FFF5F0' },
              { icon: '♡', label: '心情', bg: '#FFF5F0' },
              { icon: '⚖', label: '体重', bg: '#FFF5F0' },
              { icon: '💡', label: '想法', bg: '#FFF5F0' },
              { icon: '📋', label: '复盘', bg: '#FFF5F0' },
            ].map((item) => (
              <button
                key={item.label}
                className="flex flex-col items-center gap-1.5 py-3 rounded-2xl"
                style={{ background: item.bg }}
              >
                <span style={{ fontSize: 20 }}>{item.icon}</span>
                <span style={{ fontSize: 12, color: '#FF6B35', fontWeight: 500 }}>{item.label}</span>
              </button>
            ))}
          </div>
        </div>

        {/* 小习惯打卡 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <div className="flex items-center justify-between mb-3">
            <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111' }}>习惯打卡</h2>
            <span style={{ fontSize: 13, color: '#999' }}>今日 2/4</span>
          </div>
          <div className="grid grid-cols-2 gap-2">
            {[
              { label: '运动', done: true, streak: '18 天' },
              { label: '冥想', done: true, streak: '22 天' },
              { label: '阅读', done: false, streak: '14 天' },
              { label: '早睡前', done: false, streak: '20 天' },
            ].map((h) => (
              <div
                key={h.label}
                className="flex items-center gap-3 p-3 rounded-2xl"
                style={{ background: h.done ? '#FFF5F0' : '#f7f7f7' }}
              >
                <div
                  className="w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0"
                  style={{ background: h.done ? '#FF6B35' : '#e8e8e8' }}
                >
                  {h.done && (
                    <svg width="12" height="10" viewBox="0 0 12 10" fill="none">
                      <path d="M1 5l4 4 6-8" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  )}
                </div>
                <div>
                  <p style={{ fontSize: 13, fontWeight: 600, color: '#111' }}>{h.label}</p>
                  <p style={{ fontSize: 11, color: '#999' }}>连续 {h.streak}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}
