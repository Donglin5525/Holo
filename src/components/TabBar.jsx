const tabs = [
  {
    id: 'home',
    label: '今天',
    icon: (active) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <path
          d="M3 9.5L12 3l9 6.5V20a1 1 0 01-1 1H4a1 1 0 01-1-1V9.5z"
          fill={active ? '#FF6B35' : 'none'}
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
        <path d="M9 21V12h6v9" stroke={active ? '#fff' : '#999'} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    ),
  },
  {
    id: 'chat',
    label: 'HOLO',
    icon: (active) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <path
          d="M20 2H4a2 2 0 00-2 2v18l4-4h14a2 2 0 002-2V4a2 2 0 00-2-2z"
          fill={active ? '#FF6B35' : 'none'}
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
        {active && (
          <>
            <circle cx="8" cy="10" r="1.2" fill="#fff"/>
            <circle cx="12" cy="10" r="1.2" fill="#fff"/>
            <circle cx="16" cy="10" r="1.2" fill="#fff"/>
          </>
        )}
        {!active && (
          <>
            <circle cx="8" cy="10" r="1.2" fill="#999"/>
            <circle cx="12" cy="10" r="1.2" fill="#999"/>
            <circle cx="16" cy="10" r="1.2" fill="#999"/>
          </>
        )}
      </svg>
    ),
  },
  {
    id: 'finance',
    label: '财务',
    icon: (active) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <rect
          x="2" y="5" width="20" height="15" rx="3"
          fill={active ? '#FF6B35' : 'none'}
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
        />
        <path d="M2 10h20" stroke={active ? '#fff' : '#999'} strokeWidth="1.8"/>
        <path d="M6 15h4" stroke={active ? '#fff' : '#999'} strokeWidth="1.8" strokeLinecap="round"/>
      </svg>
    ),
  },
  {
    id: 'health',
    label: '健康',
    icon: (active) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <path
          d="M20.84 4.61a5.5 5.5 0 00-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 00-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 000-7.78z"
          fill={active ? '#FF6B35' : 'none'}
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
      </svg>
    ),
  },
  {
    id: 'profile',
    label: '我的',
    icon: (active) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <circle
          cx="12" cy="8" r="4"
          fill={active ? '#FF6B35' : 'none'}
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
        />
        <path
          d="M4 20c0-4 3.6-7 8-7s8 3 8 7"
          stroke={active ? '#FF6B35' : '#999'}
          strokeWidth="1.8"
          strokeLinecap="round"
          fill="none"
        />
      </svg>
    ),
  },
]

/**
 * iOS 风格底部导航栏
 * @param {Object} props
 * @param {string} props.active
 * @param {Function} props.onChange
 */
export default function TabBar({ active, onChange }) {
  return (
    <div
      className="flex-shrink-0 flex items-center justify-around"
      style={{
        height: 83,
        paddingBottom: 20,
        background: 'rgba(255,255,255,0.92)',
        backdropFilter: 'blur(20px)',
        borderTop: '0.5px solid rgba(0,0,0,0.1)',
      }}
    >
      {tabs.map((tab) => {
        const isActive = active === tab.id
        return (
          <button
            key={tab.id}
            onClick={() => onChange(tab.id)}
            className="flex flex-col items-center gap-0.5 flex-1"
            style={{ paddingTop: 10 }}
          >
            {tab.icon(isActive)}
            <span
              style={{
                fontSize: 10,
                fontWeight: isActive ? 600 : 400,
                color: isActive ? '#FF6B35' : '#999',
                letterSpacing: 0.1,
              }}
            >
              {tab.label}
            </span>
          </button>
        )
      })}
    </div>
  )
}
