import { AreaChart, Area, XAxis, Tooltip, ResponsiveContainer } from 'recharts'

const spendData = [
  { d: '2/20', v: 180 }, { d: '2/22', v: 95 }, { d: '2/24', v: 340 },
  { d: '2/26', v: 160 }, { d: '2/28', v: 420 }, { d: '3/1', v: 63 },
]

const records = [
  { id: 1, name: '瑞幸咖啡', cat: '餐饮', amount: -35, icon: '☕', time: '09:08', today: true },
  { id: 2, name: '早餐·煎饼', cat: '餐饮', amount: -28, icon: '🥞', time: '08:30', today: true },
  { id: 3, name: '滴滴出行', cat: '交通', amount: -24, icon: '🚗', time: '昨天', today: false },
  { id: 4, name: '京东超市', cat: '购物', amount: -156, icon: '🛒', time: '昨天', today: false },
  { id: 5, name: '工资', cat: '收入', amount: 18000, icon: '💰', time: '2/28', today: false },
]

const tooltipStyle = {
  background: '#fff',
  border: '1px solid #f0f0f0',
  borderRadius: 12,
  fontSize: 12,
  color: '#111',
  boxShadow: '0 4px 12px rgba(0,0,0,0.08)',
}

/**
 * 财务视图（iOS 轻量风格）
 */
export default function FinanceView() {
  return (
    <div className="flex-1 ios-scroll" style={{ background: '#f7f7f7' }}>
      {/* Header */}
      <div className="px-5 pt-4 pb-3">
        <h1 style={{ fontSize: 28, fontWeight: 700, color: '#111', letterSpacing: -0.5 }}>财务</h1>
      </div>

      <div className="px-4 pb-6 space-y-3">
        {/* 月度总览卡片 */}
        <div
          className="rounded-3xl p-5 card-shadow"
          style={{ background: 'linear-gradient(135deg, #FF6B35 0%, #FF9A5C 100%)' }}
        >
          <p style={{ fontSize: 13, color: 'rgba(255,255,255,0.75)', fontWeight: 400 }}>本月支出</p>
          <p style={{ fontSize: 36, fontWeight: 700, color: '#fff', letterSpacing: -1, marginTop: 2 }}>¥3,240</p>
          <div className="flex items-center gap-1.5 mt-1">
            <span style={{ fontSize: 13, color: 'rgba(255,255,255,0.85)' }}>比上月少 ¥430</span>
            <span
              className="px-2 py-0.5 rounded-full"
              style={{ fontSize: 11, background: 'rgba(255,255,255,0.25)', color: '#fff', fontWeight: 600 }}
            >
              ↓12%
            </span>
          </div>

          {/* 迷你图表 */}
          <div className="mt-4 -mx-1">
            <ResponsiveContainer width="100%" height={60}>
              <AreaChart data={spendData}>
                <defs>
                  <linearGradient id="wg" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#fff" stopOpacity={0.4}/>
                    <stop offset="95%" stopColor="#fff" stopOpacity={0}/>
                  </linearGradient>
                </defs>
                <Area type="monotone" dataKey="v" stroke="rgba(255,255,255,0.8)" strokeWidth={2} fill="url(#wg)" dot={false}/>
                <Tooltip contentStyle={tooltipStyle} formatter={(v) => [`¥${v}`, '']} />
              </AreaChart>
            </ResponsiveContainer>
          </div>

          {/* 收支对比 */}
          <div className="flex gap-4 mt-3 pt-3" style={{ borderTop: '1px solid rgba(255,255,255,0.2)' }}>
            <div>
              <p style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)' }}>收入</p>
              <p style={{ fontSize: 18, fontWeight: 700, color: '#fff' }}>¥18,000</p>
            </div>
            <div>
              <p style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)' }}>结余</p>
              <p style={{ fontSize: 18, fontWeight: 700, color: '#fff' }}>¥14,760</p>
            </div>
            <div>
              <p style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)' }}>储蓄率</p>
              <p style={{ fontSize: 18, fontWeight: 700, color: '#fff' }}>82%</p>
            </div>
          </div>
        </div>

        {/* 分类消费 */}
        <div className="rounded-3xl p-4 card-shadow" style={{ background: '#fff' }}>
          <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111', marginBottom: 12 }}>消费分类</h2>
          <div className="space-y-3">
            {[
              { name: '餐饮', amount: 1240, pct: 38, color: '#FF6B35' },
              { name: '购物', amount: 800, pct: 25, color: '#FF9A5C' },
              { name: '娱乐', amount: 620, pct: 19, color: '#FFB680' },
              { name: '交通', amount: 380, pct: 12, color: '#FFD5C2' },
            ].map((c) => (
              <div key={c.name}>
                <div className="flex items-center justify-between mb-1.5">
                  <span style={{ fontSize: 14, color: '#333' }}>{c.name}</span>
                  <span style={{ fontSize: 14, fontWeight: 600, color: '#111' }}>¥{c.amount.toLocaleString()}</span>
                </div>
                <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#f0f0f0' }}>
                  <div
                    className="h-full rounded-full"
                    style={{ width: `${c.pct}%`, background: c.color, transition: 'width 0.5s' }}
                  />
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* 最近账单 */}
        <div className="rounded-3xl overflow-hidden card-shadow" style={{ background: '#fff' }}>
          <div className="flex items-center justify-between px-4 pt-4 pb-3">
            <h2 style={{ fontSize: 16, fontWeight: 600, color: '#111' }}>最近账单</h2>
            <span style={{ fontSize: 13, color: '#FF6B35', fontWeight: 500 }}>全部</span>
          </div>
          {records.map((r, i) => (
            <div
              key={r.id}
              className="flex items-center gap-3 px-4 py-3"
              style={{ borderTop: i === 0 ? '0.5px solid #f0f0f0' : '0.5px solid #f0f0f0' }}
            >
              <div
                className="w-10 h-10 rounded-2xl flex items-center justify-center flex-shrink-0 text-xl"
                style={{ background: '#FFF5F0' }}
              >
                {r.icon}
              </div>
              <div className="flex-1">
                <p style={{ fontSize: 15, fontWeight: 500, color: '#111' }}>{r.name}</p>
                <p style={{ fontSize: 12, color: '#999', marginTop: 1 }}>{r.cat} · {r.time}</p>
              </div>
              <p style={{
                fontSize: 16,
                fontWeight: 600,
                color: r.amount > 0 ? '#34C759' : '#111',
              }}>
                {r.amount > 0 ? '+' : ''}¥{Math.abs(r.amount).toLocaleString()}
              </p>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
