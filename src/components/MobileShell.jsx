/**
 * 模拟 iPhone 外壳容器
 * @param {Object} props
 * @param {React.ReactNode} props.children
 */
export default function MobileShell({ children }) {
  return (
    <div className="min-h-screen flex items-center justify-center" style={{ background: '#e8e8e8' }}>
      {/* Phone frame */}
      <div
        className="relative overflow-hidden"
        style={{
          width: 393,
          height: 852,
          borderRadius: 54,
          background: '#fff',
          boxShadow: '0 30px 80px rgba(0,0,0,0.25), 0 0 0 2px #c8c8c8',
        }}
      >
        {/* Status bar */}
        <div
          className="flex items-end justify-between px-8 pb-1 flex-shrink-0"
          style={{ height: 54, paddingTop: 16, background: 'transparent', position: 'relative', zIndex: 20 }}
        >
          <span style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.3, color: '#111' }}>9:41</span>
          <div style={{
            position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)',
            width: 126, height: 37, borderRadius: 20, background: '#111',
          }} />
          <div className="flex items-center gap-1.5">
            {/* Signal bars */}
            <svg width="17" height="12" viewBox="0 0 17 12" fill="none">
              <rect x="0" y="5" width="3" height="7" rx="1" fill="#111"/>
              <rect x="4.5" y="3" width="3" height="9" rx="1" fill="#111"/>
              <rect x="9" y="1" width="3" height="11" rx="1" fill="#111"/>
              <rect x="13.5" y="0" width="3" height="12" rx="1" fill="#111" opacity="0.3"/>
            </svg>
            {/* WiFi */}
            <svg width="16" height="12" viewBox="0 0 16 12" fill="none">
              <path d="M8 9.5a1.5 1.5 0 100 3 1.5 1.5 0 000-3z" fill="#111"/>
              <path d="M3.5 6.5C4.8 5.2 6.3 4.5 8 4.5s3.2.7 4.5 2" stroke="#111" strokeWidth="1.5" strokeLinecap="round" fill="none"/>
              <path d="M1 4C3 2 5.4 1 8 1s5 1 7 3" stroke="#111" strokeWidth="1.5" strokeLinecap="round" fill="none" opacity="0.4"/>
            </svg>
            {/* Battery */}
            <div className="flex items-center gap-0.5">
              <div style={{ width: 25, height: 12, borderRadius: 3, border: '1.5px solid #111', padding: 2 }}>
                <div style={{ width: '80%', height: '100%', borderRadius: 1.5, background: '#111' }} />
              </div>
              <div style={{ width: 2, height: 5, borderRadius: 1, background: '#111' }} />
            </div>
          </div>
        </div>

        {/* App content */}
        <div className="flex flex-col" style={{ height: 'calc(852px - 54px)' }}>
          {children}
        </div>
      </div>
    </div>
  )
}
