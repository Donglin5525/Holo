import { useState, useRef, useEffect, useCallback } from 'react'
import { X } from 'lucide-react'

/** @type {Array<{id:number, role:'holo'|'user', text:string, time:string, actions?:string[]}>} */
const INITIAL_MSGS = [
  {
    id: 1,
    role: 'holo',
    text: '早上好 ☀️\n本月已支出 ¥3,240，比上月低 12%。今天有 2 个待办任务。',
    time: '09:00',
  },
  {
    id: 2,
    role: 'user',
    text: '早餐花了 28 块，咖啡 35 块',
    time: '09:12',
  },
  {
    id: 3,
    role: 'holo',
    text: '已记录 ✓\n• 早餐 ¥28\n• 咖啡 ¥35\n\n今日餐饮合计 ¥63，本月预算还剩 ¥712。',
    time: '09:12',
    actions: ['查看财务', '设预算提醒'],
  },
  {
    id: 4,
    role: 'user',
    text: '帮我记个想法：做一个日历 × 财务时间线功能',
    time: '09:15',
  },
  {
    id: 5,
    role: 'holo',
    text: '💡 想法已收录\n「日历 × 财务时间线」\n\n与你之前的「数据可视化」主题相关，已关联到你的产品想法库。',
    time: '09:15',
    actions: ['查看想法库', '转为任务'],
  },
]

const QUICK = ['记账', '新任务', '记心情', '记体重', '记想法']

/**
 * @param {string} text
 */
function renderText(text) {
  return text.split('\n').map((line, i) => (
    <span key={i}>
      {line}
      {i < text.split('\n').length - 1 && <br />}
    </span>
  ))
}

/**
 * HOLO 对话视图（轻量化）
 * @param {Object} props
 * @param {Function} [props.onClose] - 关闭回调（返回首页）
 */
export default function ChatView({ onClose }) {
  const [msgs, setMsgs] = useState(INITIAL_MSGS)
  const [input, setInput] = useState('')
  const [typing, setTyping] = useState(false)
  const [swipeX, setSwipeX] = useState(0)
  const bottomRef = useRef(null)
  const touchRef = useRef(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [msgs, typing])

  /** @param {string} text */
  function send(text) {
    const t = text.trim()
    if (!t) return
    const now = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })
    setMsgs(p => [...p, { id: Date.now(), role: 'user', text: t, time: now }])
    setInput('')
    setTyping(true)
    setTimeout(() => {
      setTyping(false)
      setMsgs(p => [...p, {
        id: Date.now() + 1,
        role: 'holo',
        text: '收到，已为你记录并整理好了 ✓',
        time: new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }),
      }])
    }, 1600)
  }

  // --- 右滑返回手势 ---

  const onTouchStart = useCallback((e) => {
    const t = e.touches[0]
    const rect = e.currentTarget.getBoundingClientRect()
    if (t.clientX - rect.left < 20) {
      touchRef.current = { startX: t.clientX }
    }
  }, [])

  const onTouchMove = useCallback((e) => {
    if (!touchRef.current) return
    const dx = e.touches[0].clientX - touchRef.current.startX
    if (dx > 0) {
      // 阻尼：超过 40% 宽度后减速
      const maxDx = rect => rect.width * 0.4
      const rect = e.currentTarget.getBoundingClientRect()
      if (dx <= maxDx(rect)) {
        setSwipeX(dx)
      } else {
        setSwipeX(maxDx(rect) + (dx - maxDx(rect)) * 0.3)
      }
    }
  }, [])

  const onTouchEnd = useCallback(() => {
    if (!touchRef.current) return
    const shouldDismiss = swipeX > 120
    if (shouldDismiss) {
      // 滑出动画后关闭
      setSwipeX(393)
      setTimeout(() => onClose?.(), 250)
    } else {
      setSwipeX(0)
    }
    touchRef.current = null
  }, [swipeX, onClose])

  const isSwiping = touchRef.current !== null

  return (
    <div
      className="relative flex flex-col flex-1 overflow-hidden"
      style={{
        background: '#f7f7f7',
        transform: swipeX > 0 ? `translateX(${swipeX}px)` : undefined,
        transition: !isSwiping ? 'transform 0.3s cubic-bezier(0.25, 1, 0.5, 1)' : 'none',
        boxShadow: swipeX > 0 ? '-4px 0 24px rgba(0,0,0,0.12)' : 'none',
      }}
      onTouchStart={onTouchStart}
      onTouchMove={onTouchMove}
      onTouchEnd={onTouchEnd}
    >
      {/* 关闭按钮 - 最高 z-index，绝对定位左上角，44×44 点击热区 */}
      <button
        onClick={onClose}
        className="absolute flex items-center justify-center"
        aria-label="关闭"
        style={{
          top: 6,
          left: 6,
          width: 44,
          height: 44,
          zIndex: 50,
          borderRadius: '50%',
          background: 'rgba(0,0,0,0.05)',
          border: 'none',
          cursor: 'pointer',
          WebkitTapHighlightColor: 'transparent',
        }}
      >
        <X size={18} color="#555" strokeWidth={2.5} />
      </button>

      {/* Nav bar */}
      <div
        className="flex items-center justify-between px-5 pt-2 pb-3 flex-shrink-0"
        style={{ background: '#f7f7f7', paddingLeft: 56 }}
      >
        <div className="flex items-center gap-2.5">
          <div
            className="w-9 h-9 rounded-full flex items-center justify-center"
            style={{ background: 'linear-gradient(135deg, #FF6B35, #FF9A5C)' }}
          >
            <span style={{ fontSize: 16 }}>✦</span>
          </div>
          <div>
            <p style={{ fontSize: 16, fontWeight: 700, color: '#111', letterSpacing: -0.2 }}>HOLO</p>
            <p style={{ fontSize: 11, color: '#34C759', fontWeight: 500 }}>● 在线</p>
          </div>
        </div>
        <button style={{ fontSize: 13, color: '#FF6B35', fontWeight: 500 }}>上下文</button>
      </div>

      {/* Messages */}
      <div className="flex-1 ios-scroll px-4 pb-2 space-y-3">
        {msgs.map((msg) => (
          <div key={msg.id} className={`flex flex-col msg-enter ${msg.role === 'user' ? 'items-end' : 'items-start'}`}>
            <div
              className="max-w-xs px-4 py-3 rounded-3xl"
              style={{
                background: msg.role === 'user' ? '#FF6B35' : '#fff',
                borderBottomRightRadius: msg.role === 'user' ? 8 : 24,
                borderBottomLeftRadius: msg.role === 'holo' ? 8 : 24,
                boxShadow: '0 1px 3px rgba(0,0,0,0.06)',
              }}
            >
              <p style={{
                fontSize: 15,
                lineHeight: 1.5,
                color: msg.role === 'user' ? '#fff' : '#111',
                whiteSpace: 'pre-line',
              }}>
                {renderText(msg.text)}
              </p>
            </div>

            {/* Quick action chips */}
            {msg.actions && (
              <div className="flex gap-2 mt-1.5 flex-wrap">
                {msg.actions.map((a) => (
                  <button
                    key={a}
                    className="px-3 py-1 rounded-full"
                    style={{
                      fontSize: 12,
                      background: '#FFF1EC',
                      color: '#FF6B35',
                      fontWeight: 500,
                      border: '1px solid #FFD5C2',
                    }}
                  >
                    {a}
                  </button>
                ))}
              </div>
            )}

            <span style={{ fontSize: 11, color: '#bbb', marginTop: 4 }}>{msg.time}</span>
          </div>
        ))}

        {/* Typing */}
        {typing && (
          <div className="flex items-start msg-enter">
            <div
              className="px-4 py-3 rounded-3xl rounded-bl-lg"
              style={{ background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.06)' }}
            >
              <div className="flex items-center gap-1.5">
                {[0, 150, 300].map((d, i) => (
                  <div
                    key={i}
                    className="w-2 h-2 rounded-full"
                    style={{
                      background: '#FF6B35',
                      animation: `bounce-dot 1.2s ${d}ms ease-in-out infinite`,
                    }}
                  />
                ))}
              </div>
            </div>
          </div>
        )}
        <div ref={bottomRef} />
      </div>

      {/* Quick actions */}
      <div className="px-4 pb-2 flex-shrink-0">
        <div className="flex gap-2 overflow-x-auto" style={{ scrollbarWidth: 'none' }}>
          {QUICK.map((q) => (
            <button
              key={q}
              onClick={() => { setInput(q + '：'); }}
              className="flex-shrink-0 px-3 py-1.5 rounded-full"
              style={{
                fontSize: 13,
                background: '#fff',
                color: '#555',
                border: '1px solid #e8e8e8',
                fontWeight: 400,
              }}
            >
              {q}
            </button>
          ))}
        </div>
      </div>

      {/* Input bar */}
      <div
        className="px-4 pb-4 pt-2 flex items-end gap-2 flex-shrink-0"
        style={{ background: '#f7f7f7' }}
      >
        <div
          className="flex-1 flex items-end px-4 py-2.5 rounded-3xl"
          style={{ background: '#fff', border: '1px solid #e8e8e8', minHeight: 44 }}
        >
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(input) } }}
            placeholder="告诉 HOLO 任何事情..."
            rows={1}
            className="flex-1 outline-none resize-none bg-transparent"
            style={{ fontSize: 15, color: '#111', lineHeight: 1.4, caretColor: '#FF6B35' }}
          />
        </div>
        <button
          onClick={() => send(input)}
          className="w-11 h-11 rounded-full flex items-center justify-center flex-shrink-0"
          style={{
            background: input.trim() ? '#FF6B35' : '#e8e8e8',
            transition: 'background 0.15s',
          }}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path d="M22 2L11 13" stroke={input.trim() ? '#fff' : '#bbb'} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            <path d="M22 2L15 22 11 13 2 9l20-7z" stroke={input.trim() ? '#fff' : '#bbb'} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
      </div>
    </div>
  )
}
