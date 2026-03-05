import { useState } from 'react'
import MobileShell from './components/MobileShell'
import TabBar from './components/TabBar'
import HomeView from './components/HomeView'
import ChatView from './components/ChatView'
import FinanceView from './components/FinanceView'
import HealthView from './components/HealthView'
import ProfileView from './components/ProfileView'

const views = {
  home: HomeView,
  chat: ChatView,
  finance: FinanceView,
  health: HealthView,
  profile: ProfileView,
}

/**
 * HOLO APP - 个人 AI 数据助理（移动端 iOS 风格）
 */
export default function App() {
  const [tab, setTab] = useState('home')
  const View = views[tab]

  return (
    <MobileShell>
      <View />
      <TabBar active={tab} onChange={setTab} />
    </MobileShell>
  )
}
