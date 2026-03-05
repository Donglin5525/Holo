/**
 * 健康视图（iOS 轻量风格）
 */
export default function HealthView() {
  const habits = [
    { name: '运动', icon: '🏃', streak: 18, done: true, goal: '每天 30 分钟' },
    { name: '冥想', icon: '🧘', streak: 22, done: true, goal: '每天 10 分钟' },
    { name: '阅读', icon: '📖', streak: 14, done: false, goal: '每天 30 分钟' },
    { name: '早睡', icon: '🌙', streak: 20, done: false, goal: '23:00 前' },
  ]

  const metrics = [
    { label: '步数', value: '8,432', unit: '步', icon: '👟', target: '10,000', pct: 84 },
    { label: '心率', value: '62', unit: 'bpm', icon: '❤️', target: '正常', pct: 100 },
    { label: '睡眠', value: '7.2', unit: 'h', icon: '🌙', target: '8h', pct: 90 },
    { label: '体重', value: '71.2', unit: 'kg', icon: '⚖️', target: '70kg', pct: 97 },
  ]

  const sleepDays = [
    { day: '一', h: 7.5 }, { day: '二', h: 6.8 }, { day: '三', h: 8.1 },
    { day: '四', h: 7.2 }, { day: '五', h: 6.5 }, { day: '六', h: 8.8 }, { day: '日', h: 7.2 },
  ]
  const maxH = Math.max(...sleepDays.map(d => d.h))

  return (
    <div className="flex-1 ios-scroll" style={{ background: '#f7f7f7' }}>
      <div className="px-5 pt-4 pb-3">
        <h1 style={{ fontSize: 28, fontWeight: 700, color: '#111', letterSpacing: -0.5 }}>健康</h1>
        <p style={{ fontSize: 13, color: '#999', marginTop: 1 }}>同步自 Apple 健康 · 刚刚</p>
      </div>

      <div className="px-4 pb-6 space-y-3">
        {/* 健康指标 */}
        <div className="grid grid-cols-2 gap-3">
          {metrics.map((m) => (
            <div key={m.label} className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
              <div className="flex items-center justify-between mb-2">
                <span style={{ fontSize: 13, color: '#999' }}>{m.label}</span>
                <span style={{ fontSize: 18 }}>{m.icon}</span>
              </div>
              <div className="flex items-baseline gap-1">
                <span style={{ fontSize: 24, fontWeight: 700, color: '#111', letterSpacing: -0.5 }}>{m.value}</span>
                <span style={{ fontSize: 12, color: '#999' }}>{m.unit}</span>
              </div>
              <div className="h-1 rounded-full mt-2.5 overflow-hidden" style={{ background: '#f0f0f0' }}>
                <div
                  className="h-full rounded-full"
                  style={{ width: `${m.pct}%`, background: '#FF6B35' }}
                />
              </div>
              <p style={{ fontSize: 11, color: '#bbb', marginTop: 4 }}>目标 {m.target}</p>
            </div>
          ))}
        </div>

        {/* 睡眠本周 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <div className="flex items-center justify-between mb-4">
            <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111' }}>本周睡眠</h2>
            <span style={{ fontSize: 13, color: '#FF6B35', fontWeight: 500 }}>均 7.4h</span>
          </div>
          <div className="flex items-end justify-between gap-1" style={{ height: 80 }}>
            {sleepDays.map((d) => {
              const barH = (d.h / maxH) * 64
              const good = d.h >= 7.5
              return (
                <div key={d.day} className="flex flex-col items-center gap-1.5 flex-1">
                  <div
                    className="w-full rounded-full"
                    style={{
                      height: barH,
                      background: good ? '#FF6B35' : '#FFD5C2',
                      minHeight: 8,
                      borderRadius: 6,
                    }}
                  />
                  <span style={{ fontSize: 11, color: '#999' }}>{d.day}</span>
                </div>
              )
            })}
          </div>
        </div>

        {/* 习惯打卡 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <div className="flex items-center justify-between mb-3">
            <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111' }}>习惯打卡</h2>
            <span style={{ fontSize: 13, color: '#999' }}>今日 2/4</span>
          </div>
          <div className="space-y-2">
            {habits.map((h) => (
              <div
                key={h.name}
                className="flex items-center gap-3 p-3 rounded-2xl"
                style={{ background: h.done ? '#FFF5F0' : '#f7f7f7' }}
              >
                <span style={{ fontSize: 22 }}>{h.icon}</span>
                <div className="flex-1">
                  <p style={{ fontSize: 14, fontWeight: 600, color: '#111' }}>{h.name}</p>
                  <p style={{ fontSize: 12, color: '#999' }}>{h.goal} · 连续 {h.streak} 天</p>
                </div>
                <div
                  className="w-7 h-7 rounded-full flex items-center justify-center flex-shrink-0"
                  style={{
                    background: h.done ? '#FF6B35' : '#e8e8e8',
                    border: h.done ? 'none' : '2px solid #ddd',
                  }}
                >
                  {h.done && (
                    <svg width="12" height="10" viewBox="0 0 12 10" fill="none">
                      <path d="M1 5l4 4 6-8" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* HOLO 建议 */}
        <div
          className="rounded-3xl p-4"
          style={{ background: '#FFF5F0', border: '1px solid #FFD5C2' }}
        >
          <div className="flex items-start gap-3">
            <div
              className="w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0"
              style={{ background: '#FF6B35' }}
            >
              <span style={{ fontSize: 14, color: '#fff' }}>✦</span>
            </div>
            <div>
              <p style={{ fontSize: 13, fontWeight: 600, color: '#FF6B35', marginBottom: 4 }}>HOLO 建议</p>
              <p style={{ fontSize: 13, color: '#555', lineHeight: 1.5 }}>
                你睡眠超过 7.5h 时，第二天任务完成率提升 28%。本周有 3 天未达标，今晚试着 22:30 前上床？
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
