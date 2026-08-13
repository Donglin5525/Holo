import {
  ArrowRight,
  Brain,
  CheckCircle2,
  ChevronRight,
  HeartHandshake,
  Landmark,
  LockKeyhole,
  MessageCircle,
  Sparkles,
  Stethoscope,
  Target,
  TimerReset,
} from 'lucide-react'

import {
  coreSections,
  legalLinks,
  navItems,
  productModules,
} from './landing/content'

const moduleIcons = {
  记账: Landmark,
  待办: CheckCircle2,
  习惯: TimerReset,
  想法: Brain,
  健康: Stethoscope,
}

const sectionIcons = {
  HoloAI: Sparkles,
  记忆长廊: Target,
  记忆陪伴: HeartHandshake,
}

function Nav() {
  return (
    <header className="site-nav" aria-label="Holo 官网导航">
      <a className="brand" href="#top" aria-label="Holo 首页">
        <span className="brand-mark" aria-hidden="true" />
        <span>Holo</span>
      </a>

      <nav className="nav-links" aria-label="主要导航">
        {navItems.map((item) => (
          <a key={item.href} href={item.href}>
            {item.label}
          </a>
        ))}
      </nav>

      <a className="nav-cta" href="#privacy">
        上架合规入口
        <ChevronRight size={16} />
      </a>
    </header>
  )
}

function HoloSphere() {
  return (
    <div className="sphere-stage" aria-label="HoloAI 首页球体与五大模块">
      <div className="orbit-ring orbit-one" />
      <div className="orbit-ring orbit-two" />
      <div className="ai-sphere">
        <div className="sphere-glow" />
        <div className="sphere-label">
          <span>HoloAI</span>
          <strong>今日状态中枢</strong>
          <em>记录 · 洞察 · 陪伴</em>
        </div>
      </div>

      {productModules.map((module, index) => {
        const Icon = moduleIcons[module.title]
        return (
          <article
            className={`orbit-card orbit-card-${index + 1}`}
            key={module.title}
            style={{ '--module-color': module.color }}
          >
            <div className="orbit-icon">
              <Icon size={18} />
            </div>
            <div>
              <h3>{module.title}</h3>
              <p>{module.metric}</p>
            </div>
          </article>
        )
      })}

      <div className="memory-chip memory-gallery-chip">
        <span>记忆长廊</span>
        <strong>时间线与洞察卡片</strong>
      </div>
      <div className="memory-chip memory-companion-chip">
        <span>记忆陪伴</span>
        <strong>温和提醒与复盘提问</strong>
      </div>
    </div>
  )
}

function Hero() {
  return (
    <section className="hero-section" id="top">
      <div className="hero-copy">
        <p className="eyebrow">HoloAI · 个人数据资产与陪伴式规划</p>
        <h1>让每天的记录，长成一个真正懂你的 AI。</h1>
        <p className="hero-text">
          Holo 将记账、待办、习惯、想法和健康汇入同一个个人上下文。
          首页的 HoloAI 球体会吸收你的日常信号，生成今日建议、长期洞察和可以继续对话的记忆陪伴。
        </p>
        <div className="hero-actions">
          <a className="primary-button" href="#download">
            下载 iOS App
            <ArrowRight size={18} />
          </a>
          <a className="secondary-button" href="#privacy">
            查看隐私政策
          </a>
        </div>
        <div className="hero-proof" aria-label="Holo 能力摘要">
          <span>五大模块输入</span>
          <span>HoloAI 分析</span>
          <span>记忆陪伴输出</span>
        </div>
      </div>

      <HoloSphere />
    </section>
  )
}

function ModulesSection() {
  return (
    <section className="page-section modules-section" id="modules">
      <div className="section-heading">
        <p className="eyebrow">五大功能模块</p>
        <h2>每一次记录，都是 HoloAI 理解你的信号。</h2>
        <p>
          Holo 不把功能做成孤立工具。记账、待办、习惯、想法和健康会共同组成你的生活上下文，让 AI 的建议有依据、有边界。
        </p>
      </div>

      <div className="module-grid">
        {productModules.map((module) => {
          const Icon = moduleIcons[module.title]
          return (
            <article className="module-card" key={module.title} style={{ '--module-color': module.color }}>
              <div className="module-card-head">
                <div className="module-icon">
                  <Icon size={22} />
                </div>
                <span>{module.eyebrow}</span>
              </div>
              <h3>{module.title}</h3>
              <p>{module.description}</p>
              <div className="ai-signal">
                <Sparkles size={16} />
                <span>{module.aiSignal}</span>
              </div>
            </article>
          )
        })}
      </div>
    </section>
  )
}

function CoreSections() {
  return (
    <section className="page-section core-section" id="holoai">
      <div className="section-heading narrow">
        <p className="eyebrow">Holo 的三层核心</p>
        <h2>从记录工具，到可回看的记忆，再到长期陪伴。</h2>
      </div>

      <div className="core-layout">
        {coreSections.map((section, index) => {
          const Icon = sectionIcons[section.title]
          return (
            <article
              className={`core-card core-card-${index + 1}`}
              id={section.id}
              key={section.title}
            >
              <div className="core-index">0{index + 1}</div>
              <div className="core-icon">
                <Icon size={24} />
              </div>
              <p className="core-label">{section.label}</p>
              <h3>{section.title}</h3>
              <p>{section.description}</p>
              <div className="bullet-row">
                {section.bullets.map((bullet) => (
                  <span key={bullet}>{bullet}</span>
                ))}
              </div>
            </article>
          )
        })}
      </div>
    </section>
  )
}

function CompanionStory() {
  return (
    <section className="page-section story-section">
      <div className="story-panel">
        <div className="story-copy">
          <p className="eyebrow">记忆陪伴</p>
          <h2>提醒可以很轻，陪伴也可以有边界。</h2>
          <p>
            HoloAI 不替你做决定，也不做医疗或财务承诺。它更像一个长期整理者：
            在你需要复盘时提出问题，在模式重复出现时温和提醒，在信息太散时把下一步说清楚。
          </p>
        </div>

        <div className="chat-preview" aria-label="记忆陪伴对话预览">
          <div className="chat-top">
            <div className="mini-avatar">H</div>
            <div>
              <strong>HoloAI</strong>
              <span>基于你的记忆上下文</span>
            </div>
          </div>
          <div className="message message-ai">
            你这周睡眠低于 7 小时时，第二天待办完成率明显下降。今晚要不要把明早的第一项任务提前拆小？
          </div>
          <div className="message message-user">
            帮我拆一下，别太复杂。
          </div>
          <div className="message message-ai">
            好。我会保留 1 个核心任务，另外两项改成提醒。这样明早不会一开始就过载。
          </div>
        </div>
      </div>
    </section>
  )
}

function PrivacySection() {
  return (
    <section className="page-section privacy-section" id="privacy">
      <div className="section-heading">
        <p className="eyebrow">App Store 上架所需入口</p>
        <h2>隐私、支持和数据控制，要放在用户看得见的地方。</h2>
        <p>
          这些内容可以在正式站点中拆成独立页面。当前 demo 先把入口和文案边界放清楚，便于后续接入真实政策文本。
        </p>
      </div>

      <div className="legal-grid">
        {legalLinks.map((link) => (
          <a className="legal-card" href={link.href} key={link.title}>
            <LockKeyhole size={20} />
            <h3>{link.title}</h3>
            <p>{link.description}</p>
          </a>
        ))}
      </div>
    </section>
  )
}

function SupportPage() {
  return (
    <main className="landing-page support-page">
      <section className="page-section privacy-section" id="support">
        <div className="section-heading">
          <p className="eyebrow">Holo Support</p>
          <h2>需要帮助，或想管理你的数据？</h2>
          <p>
            Holo 是个人记录、复盘和 AI 陪伴工具。遇到登录、同步、订阅、HealthKit 或 AI 功能问题，
            请通过邮箱联系我们；我们会根据问题提供处理建议。
          </p>
        </div>

        <div className="legal-grid">
          <a className="legal-card" href="mailto:support@holoapp.cn">
            <MessageCircle size={20} />
            <h3>联系支持</h3>
            <p>support@holoapp.cn</p>
          </a>
          <a className="legal-card" href="/privacy">
            <LockKeyhole size={20} />
            <h3>隐私政策</h3>
            <p>查看数据收集、AI 处理、保留和删除说明。</p>
          </a>
          <a className="legal-card" href="/terms">
            <LockKeyhole size={20} />
            <h3>用户协议</h3>
            <p>查看服务范围、订阅和免责声明。</p>
          </a>
        </div>

        <div className="story-panel" id="data-deletion">
          <div className="story-copy">
            <p className="eyebrow">数据删除</p>
            <h2>在 App 内删除账号与 Holo 数据</h2>
            <p>
              打开 Holo → 设置 → 账号与数据 → 删除账号与 Holo 数据，按提示确认即可。
              该操作会清理本地数据、附件、AI 记忆、缓存、登录状态和应用设置；删除操作不可恢复。
            </p>
          </div>
        </div>

        <div className="story-panel" id="health-data">
          <div className="story-copy">
            <p className="eyebrow">HealthKit</p>
            <h2>健康数据只读，并由你决定是否授权 AI 使用</h2>
            <p>
              Holo 只读获取你授权的步数、睡眠、站立和活动数据，不会写入或修改 Apple Health。
              使用需要健康上下文的 AI 功能时，必要的健康摘要会在你同意 AI 数据处理后发送至 Holo 后端和第三方 AI 服务；
              健康数据不用于广告或跨 App 追踪。
            </p>
          </div>
        </div>
      </section>
    </main>
  )
}

function DownloadBand() {
  return (
    <section className="download-band" id="download">
      <div>
        <p className="eyebrow">iOS App</p>
        <h2>一个入口，记录、理解并陪伴你的日常。</h2>
      </div>
      <a className="primary-button" href="#privacy">
        准备上架材料
        <ArrowRight size={18} />
      </a>
    </section>
  )
}

function Footer() {
  return (
    <footer className="site-footer">
      <div className="brand">
        <span className="brand-mark" aria-hidden="true" />
        <span>Holo</span>
      </div>
      <div className="footer-links">
        {legalLinks.map((link) => (
          <a href={link.href} key={link.title}>
            {link.title}
          </a>
        ))}
      </div>
      <p>个人数据资产、HoloAI 规划与记忆陪伴。示例页面文案不构成医疗、财务或法律建议。</p>
    </footer>
  )
}

function LegalFrame({ src, title }) {
  return (
    <iframe
      src={src}
      title={title}
      style={{ position: 'fixed', inset: 0, width: '100%', height: '100%', border: 'none' }}
    />
  )
}

export default function App() {
  // App Store 上架要求：/privacy 和 /terms 必须直接展示法律正文（非营销页）。
  // 官网是单页应用，服务器对所有路径 fallback 到 index.html，所以在这里按路径分流，
  // 用 iframe 加载 public/ 下的静态法律页面（privacy.html / terms.html）。
  const path = window.location.pathname.replace(/\/+$/, '')
  if (path === '/privacy') {
    return <LegalFrame src="/privacy.html" title="Holo 隐私政策" />
  }
  if (path === '/terms') {
    return <LegalFrame src="/terms.html" title="Holo 用户协议" />
  }
  if (path === '/support') {
    return <SupportPage />
  }
  return (
    <main className="landing-page">
      <Nav />
      <Hero />
      <ModulesSection />
      <CoreSections />
      <CompanionStory />
      <PrivacySection />
      <DownloadBand />
      <Footer />
    </main>
  )
}
